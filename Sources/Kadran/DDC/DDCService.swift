import CIOAVService
import CoreGraphics
import Foundation
import IOKit
import os

/// Identity of a display, as reported by both IOKit and CoreGraphics, used to
/// pair an `IOAVService` with a `CGDirectDisplayID`.
private struct DisplayIdentity: Equatable {
    var vendor: UInt32
    var product: UInt32
    var serial: UInt32
}

/// An external display reachable over DDC/CI.
///
/// `@unchecked Sendable` because of the raw service handle: IOAVService itself
/// is thread-safe, and every use of the handle in this app is funnelled through
/// `DDCService`'s serial queue, which also owns its lifetime.
struct DDCDisplay: Identifiable, @unchecked Sendable {
    let id: CGDirectDisplayID
    let name: String
    fileprivate let service: UnsafeMutableRawPointer

    /// Stable across reboots and cable swaps, unlike `CGDirectDisplayID`,
    /// so profiles and remembered values key off this.
    let persistentKey: String
}

/// Discovers external displays and writes VCP features to them.
///
/// Writes are serialized on a private queue: the DDC/CI bus is half duplex and
/// tolerates roughly one transaction per 20 ms. Firing slider updates straight
/// at it from the main thread makes the monitor drop packets or ignore the bus
/// entirely until replugged.
final class DDCService: @unchecked Sendable {
    static let shared = DDCService()

    private let queue = DispatchQueue(label: "dev.kadran.ddc", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.kadran", category: "ddc")

    /// Minimum spacing between two bus transactions.
    private let writeInterval: TimeInterval = 0.02
    private var lastWrite: Date = .distantPast

    /// Handles handed out by the last `discoverDisplays()`. Held so they can be
    /// released on the next scan: a replugged cable invalidates them, and
    /// leaking one per scan would accumulate over a long uptime.
    private var retained: [UnsafeMutableRawPointer] = []

    private init() {}

    var isSupported: Bool { kdn_avservice_available() }

    // MARK: - Discovery

    /// Every external display that exposes an `IOAVService`.
    ///
    /// Built-in panels are excluded: they are driven by the backlight APIs, not
    /// DDC, and have no I2C bus to talk to.
    func discoverDisplays() -> [DDCDisplay] {
        guard kdn_avservice_available() else { return [] }

        releaseRetained()

        let cgDisplays = onlineExternalDisplays()
        guard !cgDisplays.isEmpty else { return [] }

        var results: [DDCDisplay] = []
        var pendingIdentity: DisplayIdentity?

        for entry in registryEntries() {
            defer { IOObjectRelease(entry) }

            let className = entryClassName(entry)

            // The registry is walked depth-first, so a framebuffer node is
            // always seen before the DCPAVServiceProxy that belongs to it.
            if className == "AppleCLCD2" || className == "IOMobileFramebufferShim" {
                pendingIdentity = displayIdentity(of: entry)
                continue
            }

            guard className == "DCPAVServiceProxy" else { continue }
            guard location(of: entry) == "External" else {
                pendingIdentity = nil
                continue
            }
            guard let identity = pendingIdentity else { continue }
            pendingIdentity = nil

            guard let match = cgDisplays.first(where: { $0.identity == identity }) else {
                logger.debug("DCPAVServiceProxy with no matching CGDisplay, skipping")
                continue
            }
            guard !results.contains(where: { $0.id == match.id }) else { continue }
            guard let service = kdn_avservice_create(entry) else {
                logger.warning("IOAVServiceCreateWithService returned NULL for \(match.name)")
                continue
            }
            retained.append(service)

            results.append(
                DDCDisplay(
                    id: match.id,
                    name: match.name,
                    service: service,
                    persistentKey: "\(identity.vendor)-\(identity.product)-\(identity.serial)"
                )
            )
        }

        return results
    }

    private func releaseRetained() {
        for service in retained {
            kdn_avservice_release(service)
        }
        retained.removeAll()
    }

    private struct CGDisplayInfo {
        var id: CGDirectDisplayID
        var name: String
        var identity: DisplayIdentity
    }

    private func onlineExternalDisplays() -> [CGDisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            return CGDisplayInfo(
                id: id,
                name: displayName(for: id),
                identity: DisplayIdentity(
                    vendor: CGDisplayVendorNumber(id),
                    product: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                )
            )
        }
    }

    private func displayName(for id: CGDirectDisplayID) -> String {
        // NSScreen carries the localized product name; falling back to the id
        // keeps multi-monitor menus unambiguous even when it is missing.
        let screens = NSScreenBridge.localizedNames()
        return screens[id] ?? "Display \(id)"
    }

    /// Depth-first walk of the IOService plane. Caller releases each entry.
    private func registryEntries() -> [io_registry_entry_t] {
        var iterator = io_iterator_t()
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, options, &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var entries: [io_registry_entry_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            entries.append(entry)
        }
        return entries
    }

    private func entryClassName(_ entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { return "" }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    private func location(of entry: io_registry_entry_t) -> String? {
        property(entry, "Location") as? String
    }

    private func displayIdentity(of entry: io_registry_entry_t) -> DisplayIdentity? {
        guard let attributes = property(entry, "DisplayAttributes") as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any]
        else { return nil }

        // LegacyManufacturerID is the numeric EDID vendor code that
        // CGDisplayVendorNumber reports; ManufacturerID is its 3-letter form.
        guard let vendor = product["LegacyManufacturerID"] as? UInt32,
              let productID = product["ProductID"] as? UInt32
        else { return nil }

        let serial = (product["SerialNumber"] as? UInt32) ?? 0
        return DisplayIdentity(vendor: vendor, product: productID, serial: serial)
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let ref = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return ref.takeRetainedValue()
    }

    // MARK: - Writing

    /// Sets a VCP feature, throttled to the bus rate.
    ///
    /// Fire-and-forget by design: this monitor never answers a read, so there
    /// is no acknowledgement to wait for and no value to verify afterwards.
    func set(_ feature: VCP, to value: UInt16, on display: DDCDisplay) {
        setRaw(code: feature.rawValue, to: value, on: display, label: feature.label)
    }

    /// Sets any VCP code, named or not.
    ///
    /// Monitors implement features MCCS never defined, and this display answers
    /// no capability string, so the only way to find out what it supports is to
    /// write a code and look at the panel.
    func setRaw(code: UInt8, to value: UInt16, on display: DDCDisplay, label: String? = nil) {
        let name = label ?? String(format: "0x%02X", code)
        queue.async { [self] in
            let sinceLast = Date().timeIntervalSince(lastWrite)
            if sinceLast < writeInterval {
                Thread.sleep(forTimeInterval: writeInterval - sinceLast)
            }
            lastWrite = Date()

            let result = performSet(code: code, value: value, on: display.service)
            if result != kIOReturnSuccess {
                logger.error("set \(name)=\(value) on \(display.name) failed: \(result)")
            }
        }
    }

    // MARK: - Reading

    /// Current and maximum value of a VCP feature.
    struct FeatureValue {
        var current: UInt16
        var maximum: UInt16
    }

    /// Reads a VCP feature. Returns nil when the display does not answer, which
    /// is common: plenty of monitors accept writes and ignore reads.
    func read(code: UInt8, from display: DDCDisplay) -> FeatureValue? {
        queue.sync {
            var request: [UInt8] = [
                0x82,  // 0x80 | 2 payload bytes
                0x01,  // Get VCP Feature
                code,
            ]
            request.append(request.reduce(0x6E ^ 0x51, ^))

            let writeResult = request.withUnsafeMutableBufferPointer { buffer in
                kdn_avservice_write_i2c(
                    display.service, 0x37, 0x51, buffer.baseAddress, UInt32(buffer.count)
                )
            }
            guard writeResult == kIOReturnSuccess else { return nil }

            // DDC/CI requires at least 40ms before the reply is fetched.
            Thread.sleep(forTimeInterval: 0.05)

            var reply = [UInt8](repeating: 0, count: 16)
            let readResult = reply.withUnsafeMutableBufferPointer { buffer in
                kdn_avservice_read_i2c(
                    display.service, 0x37, 0x51, buffer.baseAddress, UInt32(buffer.count)
                )
            }
            guard readResult == kIOReturnSuccess else { return nil }

            // Reply layout, with the source address included by the driver:
            //   0x6E | 0x88 | 0x02 | result | code | type | max hi | max lo |
            //   current hi | current lo | checksum
            guard reply.count >= 11, reply[2] == 0x02 else { return nil }

            // A non-zero result code means the display does not implement the
            // feature, which is a different answer from silence.
            guard reply[3] == 0x00, reply[4] == code else { return nil }

            return FeatureValue(
                current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])
            )
        }
    }

    func read(_ feature: VCP, from display: DDCDisplay) -> FeatureValue? {
        read(code: feature.rawValue, from: display)
    }

    // MARK: - Capabilities

    /// Outcome of a capability probe.
    ///
    /// The failure cases are kept apart rather than collapsed into nil because
    /// they mean different things: a refused write is a dead bus, a missing
    /// reply is a monitor that only listens, and a malformed reply is a monitor
    /// that answers something this code does not understand. Anyone reporting
    /// an unsupported display needs to be able to say which one happened.
    enum CapabilitiesResult: Error {
        case string(String)
        case writeFailed(IOReturn)
        case noReply(IOReturn)
        case malformed([UInt8])
    }

    /// Asks the display for its capability string, which lists every VCP code
    /// it implements.
    ///
    /// This is a different transaction from a VCP read, so it is worth trying
    /// even on a display that answers no VCP reads.
    func readCapabilities(of display: DDCDisplay) -> CapabilitiesResult {
        queue.sync {
            var text = ""
            var offset: UInt16 = 0

            // Each reply carries at most 32 bytes, so a long string needs many
            // round trips. The bound stops a display that keeps answering at the
            // same offset from looping forever.
            for _ in 0..<64 {
                switch capabilitiesChunk(at: offset, from: display.service) {
                case .success(let chunk):
                    if chunk.isEmpty {
                        return .string(text)
                    }
                    text += chunk
                    offset += UInt16(chunk.count)
                case .failure(let failure):
                    return text.isEmpty ? failure : .string(text)
                }
            }
            return .string(text)
        }
    }

    private func capabilitiesChunk(
        at offset: UInt16,
        from service: UnsafeMutableRawPointer
    ) -> Result<String, CapabilitiesResult> {
        var request: [UInt8] = [
            0x83,  // 0x80 | 3 payload bytes
            0xF3,  // Capabilities Request
            UInt8(truncatingIfNeeded: offset >> 8),
            UInt8(truncatingIfNeeded: offset),
        ]
        request.append(request.reduce(0x6E ^ 0x51, ^))

        let writeResult = request.withUnsafeMutableBufferPointer { buffer in
            kdn_avservice_write_i2c(service, 0x37, 0x51, buffer.baseAddress, UInt32(buffer.count))
        }
        guard writeResult == kIOReturnSuccess else {
            return .failure(.writeFailed(writeResult))
        }

        // DDC/CI requires at least 40ms between a request and its reply.
        Thread.sleep(forTimeInterval: 0.05)

        var reply = [UInt8](repeating: 0, count: 64)
        let readResult = reply.withUnsafeMutableBufferPointer { buffer in
            kdn_avservice_read_i2c(service, 0x37, 0x51, buffer.baseAddress, UInt32(buffer.count))
        }
        guard readResult == kIOReturnSuccess else {
            return .failure(.noReply(readResult))
        }

        // Reply layout, with the source address included by the driver:
        //   0x6E | 0x80|len | 0xE3 | offset hi | offset lo | text… | checksum
        // `len` counts the opcode and the two offset bytes as well as the text.
        let length = Int(reply[1] & 0x7F)
        guard length >= 3, reply[2] == 0xE3, reply.count > length + 2 else {
            return .failure(.malformed(Array(reply.prefix(16))))
        }
        let textLength = length - 3
        guard textLength > 0 else { return .success("") }
        return .success(String(decoding: reply[5..<(5 + textLength)], as: UTF8.self))
    }

    /// Builds and sends a DDC/CI "Set VCP Feature" packet.
    ///
    /// Frame layout on the wire, per the DDC/CI spec:
    ///   destination 0x6E | source 0x51 | 0x80|len | 0x03 | code | hi | lo | xor
    /// `IOAVServiceWriteI2C` takes the destination as `chipAddress` (7-bit, so
    /// 0x6E >> 1 = 0x37) and the source byte as `offset`, so the buffer starts
    /// at the length byte. The checksum still covers the two omitted bytes.
    private func performSet(code: UInt8, value: UInt16, on service: UnsafeMutableRawPointer) -> IOReturn {
        let destination: UInt8 = 0x6E
        let source: UInt8 = 0x51
        let length: UInt8 = 0x84  // 0x80 | 4 payload bytes
        let setVCPOpcode: UInt8 = 0x03

        var packet: [UInt8] = [
            length,
            setVCPOpcode,
            code,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        let checksum = packet.reduce(destination ^ source, ^)
        packet.append(checksum)

        return packet.withUnsafeMutableBufferPointer { buffer in
            kdn_avservice_write_i2c(
                service,
                0x37,
                UInt32(source),
                buffer.baseAddress,
                UInt32(buffer.count)
            )
        }
    }
}

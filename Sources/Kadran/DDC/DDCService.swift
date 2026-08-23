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
        queue.async { [self] in
            let sinceLast = Date().timeIntervalSince(lastWrite)
            if sinceLast < writeInterval {
                Thread.sleep(forTimeInterval: writeInterval - sinceLast)
            }
            lastWrite = Date()

            let result = performSet(feature, value: value, on: display.service)
            if result != kIOReturnSuccess {
                logger.error(
                    "set \(feature.label)=\(value) on \(display.name) failed: \(result)"
                )
            }
        }
    }

    /// Builds and sends a DDC/CI "Set VCP Feature" packet.
    ///
    /// Frame layout on the wire, per the DDC/CI spec:
    ///   destination 0x6E | source 0x51 | 0x80|len | 0x03 | code | hi | lo | xor
    /// `IOAVServiceWriteI2C` takes the destination as `chipAddress` (7-bit, so
    /// 0x6E >> 1 = 0x37) and the source byte as `offset`, so the buffer starts
    /// at the length byte. The checksum still covers the two omitted bytes.
    private func performSet(_ feature: VCP, value: UInt16, on service: UnsafeMutableRawPointer) -> IOReturn {
        let destination: UInt8 = 0x6E
        let source: UInt8 = 0x51
        let length: UInt8 = 0x84  // 0x80 | 4 payload bytes
        let setVCPOpcode: UInt8 = 0x03

        var packet: [UInt8] = [
            length,
            setVCPOpcode,
            feature.rawValue,
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

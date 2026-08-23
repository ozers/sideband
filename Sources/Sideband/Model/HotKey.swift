import AppKit
import Carbon.HIToolbox
import os

/// What a global shortcut does when pressed.
enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    case brightnessUp
    case brightnessDown
    case contrastUp
    case contrastDown
    case cycleProfile

    var label: String {
        switch self {
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .contrastUp: return "Contrast up"
        case .contrastDown: return "Contrast down"
        case .cycleProfile: return "Next profile"
        }
    }

    /// Carbon hot key ids are integers, so each action needs a stable one.
    /// Derived from the case order rather than hashValue, which is not stable
    /// across launches.
    var identifier: UInt32 {
        UInt32(HotKeyAction.allCases.firstIndex(of: self) ?? 0) + 1
    }

    static func from(identifier: UInt32) -> HotKeyAction? {
        let index = Int(identifier) - 1
        return allCases.indices.contains(index) ? allCases[index] : nil
    }
}

/// A key plus its modifiers, stored in Carbon's encoding.
struct HotKeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), not `NSEvent.ModifierFlags`.
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        var carbon: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        // A bare key would swallow that key system-wide. Require a modifier so
        // a shortcut cannot make the keyboard unusable.
        guard carbon != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    /// Human-readable form, e.g. ⌥⌘↑.
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        // Keys whose glyph cannot be derived from the current layout.
        let special: [Int: String] = [
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋",
            kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(keyCode)] { return name }
        return layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
    }

    /// Resolves a key code through the active keyboard layout, so a Turkish or
    /// Dvorak layout shows the glyph actually printed on the key.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,  // modifiers stripped: we want the unshifted glyph
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}

/// Registers global shortcuts and reports presses.
///
/// Carbon's `RegisterEventHotKey` is used rather than
/// `NSEvent.addGlobalMonitorForEvents` because the latter needs Accessibility
/// permission — a system prompt and a trip to System Settings — for something
/// that should work the moment the app launches.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Called on the main actor when a registered shortcut fires.
    var onTrigger: ((HotKeyAction) -> Void)?

    private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let logger = Logger(subsystem: "com.github.ozers.Sideband", category: "hotkey")

    private init() {}

    /// Replaces all registrations with `bindings`.
    func apply(_ bindings: [HotKeyAction: HotKeyBinding]) {
        installHandlerIfNeeded()
        unregisterAll()

        for (action, binding) in bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.identifier)
            let status = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, id, GetEventDispatcherTarget(), 0, &ref
            )
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                // Most often because another app already owns the combination.
                logger.warning(
                    "could not register \(binding.displayString) for \(action.rawValue): \(status)"
                )
            }
        }
    }

    /// True when the combination could not be claimed, so the UI can say so.
    func isRegistered(_ action: HotKeyAction) -> Bool {
        registered[action] != nil
    }

    private func unregisterAll() {
        for ref in registered.values {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
    }

    private static let signature: OSType = 0x4B44_524E  // 'SBND'

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard status == noErr, id.signature == HotKeyCenter.signature,
                  let action = HotKeyAction.from(identifier: id.id)
            else { return OSStatus(eventNotHandledErr) }

            // The Carbon handler runs on the main thread already, but it is not
            // statically known to, so the hop makes the isolation explicit.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotKeyCenter.shared.onTrigger?(action)
                }
            }
            return noErr
        }

        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec, nil, &eventHandler)
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A field that captures the next key combination pressed.
///
/// Built on NSView rather than SwiftUI's `onKeyPress`: recording has to see the
/// raw key code and swallow the event before the responder chain turns ⌘Q into
/// a quit, which SwiftUI's key handling does not allow.
struct HotKeyRecorder: NSViewRepresentable {
    var binding: HotKeyBinding?
    var isConflicted: Bool
    var onChange: (HotKeyBinding?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = onChange
        view.binding = binding
        view.isConflicted = isConflicted
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var binding: HotKeyBinding?
        var isConflicted = false
        var onChange: ((HotKeyBinding?) -> Void)?

        private var isRecording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }

            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                window?.makeFirstResponder(nil)
                return
            }
            if event.keyCode == UInt16(kVK_Delete) {
                binding = nil
                onChange?(nil)
                isRecording = false
                window?.makeFirstResponder(nil)
                return
            }
            guard let recorded = HotKeyBinding(event: event) else {
                // No modifier held: refused, since a bare key would be captured
                // system-wide. Stay in recording mode so the user can retry.
                NSSound.beep()
                return
            }

            binding = recorded
            onChange?(recorded)
            isRecording = false
            window?.makeFirstResponder(nil)
        }

        /// Modifier-only presses must not end recording, but they also must not
        /// fall through to the responder chain.
        override func flagsChanged(with event: NSEvent) {
            if !isRecording { super.flagsChanged(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Claims ⌘-combinations before the menu bar can act on them.
            guard isRecording else { return false }
            keyDown(with: event)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)

            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                         : NSColor.controlBackgroundColor).setFill()
            path.fill()

            let border: NSColor = if isRecording {
                .controlAccentColor
            } else if isConflicted {
                .systemOrange
            } else {
                .separatorColor
            }
            border.setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            let text: String = if isRecording {
                "Press keys…"
            } else if let binding {
                binding.displayString
            } else {
                "Click to set"
            }

            let colour: NSColor = if isRecording || binding != nil {
                .labelColor
            } else {
                .tertiaryLabelColor
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: colour,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}

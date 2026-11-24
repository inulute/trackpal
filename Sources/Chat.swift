// Chat.swift — a small text box that pops up under Pip so you can talk to it. Enter sends, Esc closes.

import AppKit

final class ChatPanel: NSPanel, NSTextFieldDelegate {
    private let field = NSTextField()
    var onSend: ((String) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 250, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        bg.material = .popover; bg.state = .active; bg.wantsLayer = true
        bg.layer?.cornerRadius = 12; bg.layer?.masksToBounds = true
        contentView = bg

        field.frame = bg.bounds.insetBy(dx: 10, dy: 7)
        field.autoresizingMask = [.width, .height]
        field.placeholderString = "Say something to Pip…"
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        bg.addSubview(field)
    }

    override var canBecomeKey: Bool { true }

    func show(below pet: NSWindow) {
        setFrameOrigin(NSPoint(x: pet.frame.midX - frame.width / 2, y: max(4, pet.frame.minY - frame.height - 4)))
        field.stringValue = ""
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSend?(text) }
            field.stringValue = ""
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { orderOut(nil); return true }
        return false
    }

    override func resignKey() { super.resignKey(); orderOut(nil) }
}

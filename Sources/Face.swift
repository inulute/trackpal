// Face.swift — the pet's body: a small floating window with two glowing eyes, a mouth that moves when it
// talks, and a speech bubble above its head. Drag it anywhere; click it to poke it.

import AppKit

enum Mood: String, CaseIterable {
    case idle, happy, sleepy, annoyed, surprised, sad, love, focused
}

final class FaceView: NSView {
    var mood: Mood = .idle { didSet { moodChanged = CACurrentMediaTime() } }
    var mouthLevel: CGFloat = 0
    var bubbleText: String? { didSet { needsDisplay = true } }
    var onPoke: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// Shows a "thinking" dots animation while the brain works.
    var thinking = false
    /// Heard "Hey Pip": a pulsing ring shows it's all ears.
    var listening = false

    private var moodChanged = CACurrentMediaTime()
    private var nextBlink = CACurrentMediaTime() + 3
    private var blinkStart: CFTimeInterval = 0
    private var gaze = CGPoint.zero
    private var smoothedMouth: CGFloat = 0
    private var timer: Timer?
    private var mouseDownAt: NSPoint?

    static let faceSize = NSSize(width: 150, height: 112)
    static let bubbleHeight: CGFloat = 92

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var eyeColor: NSColor {
        switch mood {
        case .annoyed: return NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.32, alpha: 1)
        case .love: return NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.68, alpha: 1)
        case .sleepy: return NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.95, alpha: 1)
        default: return NSColor(calibratedRed: 0.32, green: 0.92, blue: 1.0, alpha: 1)
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now > nextBlink && mood != .sleepy && mood != .happy {
            blinkStart = now
            nextBlink = now + Double.random(in: 2.5...6) * (Double.random(in: 0...1) < 0.15 ? 0.1 : 1)  // sometimes a double blink
        }
        // Eyes drift toward the mouse pointer (no permission needed for this).
        if let win = window {
            let m = NSEvent.mouseLocation
            let c = NSPoint(x: win.frame.midX, y: win.frame.minY + Self.faceSize.height / 2)
            let dx = max(-1, min(1, (m.x - c.x) / 500)), dy = max(-1, min(1, (m.y - c.y) / 400))
            let target = mood == .sleepy ? CGPoint(x: 0, y: -0.4) : CGPoint(x: dx, y: dy)
            gaze.x += (target.x - gaze.x) * 0.12
            gaze.y += (target.y - gaze.y) * 0.12
        }
        smoothedMouth += (mouthLevel - smoothedMouth) * 0.5
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill()
        let now = CACurrentMediaTime()
        let face = NSRect(x: (bounds.width - Self.faceSize.width) / 2, y: 0, width: Self.faceSize.width, height: Self.faceSize.height)

        // Body: a dark, glossy screen-face like a little robot.
        let body = NSBezierPath(roundedRect: face.insetBy(dx: 3, dy: 3), xRadius: 30, yRadius: 30)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.set()
        NSColor(calibratedWhite: 0.07, alpha: 0.96).setFill(); body.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0.28, alpha: 1).setStroke(); body.lineWidth = 2; body.stroke()

        // Idle breathing bob.
        let bob = CGFloat(sin(now * 2.1)) * 1.5
        let cx = face.midX + gaze.x * 10, cy = face.midY + 10 + gaze.y * 6 + bob
        let spacing: CGFloat = 30

        var blink: CGFloat = 1
        let bt = now - blinkStart
        if bt < 0.16 { blink = CGFloat(abs(bt - 0.08) / 0.08) }
        // A little "pop" when the mood changes.
        let pop = CGFloat(1 + 0.18 * max(0, 1 - (now - moodChanged) / 0.25))

        let glow = NSShadow(); glow.shadowBlurRadius = 10; glow.shadowOffset = .zero; glow.shadowColor = eyeColor.withAlphaComponent(0.9)
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        eyeColor.setFill(); eyeColor.setStroke()
        for side in [-1.0, 1.0] {
            drawEye(at: NSPoint(x: cx + CGFloat(side) * spacing, y: cy), side: CGFloat(side), blink: blink, pop: pop, now: now)
        }
        drawMouth(center: NSPoint(x: face.midX + gaze.x * 6, y: face.minY + 24 + bob))
        NSGraphicsContext.restoreGraphicsState()

        if listening {
            let pulse = CGFloat(0.5 + 0.5 * sin(now * 6))
            let ring = NSBezierPath(roundedRect: face.insetBy(dx: 5, dy: 5), xRadius: 27, yRadius: 27)
            ring.lineWidth = 2 + 2 * pulse
            NSGraphicsContext.saveGraphicsState()
            let g = NSShadow(); g.shadowBlurRadius = 8; g.shadowOffset = .zero; g.shadowColor = eyeColor; g.set()
            eyeColor.withAlphaComponent(0.45 + 0.4 * pulse).setStroke(); ring.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        if mood == .sleepy {
            let z = NSAttributedString(string: "z", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: eyeColor.withAlphaComponent(0.8)])
            let phase = CGFloat((now * 0.7).truncatingRemainder(dividingBy: 1))
            z.draw(at: NSPoint(x: face.maxX - 30 + phase * 8, y: face.maxY - 38 + phase * 16))
        }

        if let text = bubbleText {
            drawBubble(text, above: face)
        } else if thinking {
            let n = Int(now * 3) % 4
            drawBubble(String(repeating: "•", count: max(1, n)) + String(repeating: " ", count: 3 - max(1, n)), above: face)
        }
    }

    private func drawEye(at c: NSPoint, side: CGFloat, blink: CGFloat, pop: CGFloat, now: CFTimeInterval) {
        let w: CGFloat = 24 * pop, h: CGFloat = 34 * pop
        switch mood {
        case .happy:
            arc(c, w: w, up: true)
        case .love:
            heart(c, size: 26 * pop * CGFloat(1 + 0.08 * sin(now * 8)))
        case .sleepy:
            let r = NSRect(x: c.x - w / 2, y: c.y - 8, width: w, height: 5)
            NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
        case .surprised:
            let d = 34 * pop * max(0.12, blink)
            NSBezierPath(ovalIn: NSRect(x: c.x - 17 * pop, y: c.y - d / 2, width: 34 * pop, height: d)).fill()
        case .annoyed, .sad, .focused:
            // A rounded eye with a lid cut diagonally across the top.
            let eh = h * max(0.12, blink)
            let r = NSRect(x: c.x - w / 2, y: c.y - eh / 2, width: w, height: eh)
            NSGraphicsContext.saveGraphicsState()
            let lid = NSBezierPath()
            let inner: CGFloat, outer: CGFloat
            switch mood {
            case .annoyed: inner = 0.45; outer = 0.92   // angry: lids slant down toward the middle
            case .sad: inner = 0.92; outer = 0.5        // sad: lids slant down toward the outside
            default: inner = 0.7; outer = 0.7           // focused: a flat, narrowed look
            }
            let innerX = side < 0 ? r.maxX : r.minX, outerX = side < 0 ? r.minX : r.maxX
            // Extend the clip a little past both sides of the eye so only the top is cut.
            let pad: CGFloat = 4
            let o = outerX + side * pad, n = innerX - side * pad
            lid.move(to: NSPoint(x: o, y: r.minY - 2))
            lid.line(to: NSPoint(x: n, y: r.minY - 2))
            lid.line(to: NSPoint(x: n, y: r.minY + eh * inner))
            lid.line(to: NSPoint(x: o, y: r.minY + eh * outer))
            lid.close()
            // Clip inside a transparency layer so the glow is drawn around the finished shape, not the clip box.
            let cg = NSGraphicsContext.current!.cgContext
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            lid.addClip()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            cg.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
        case .idle:
            let eh = h * max(0.1, blink)
            NSBezierPath(roundedRect: NSRect(x: c.x - w / 2, y: c.y - eh / 2, width: w, height: eh), xRadius: 9, yRadius: min(9, eh / 2)).fill()
        }
    }

    private func arc(_ c: NSPoint, w: CGFloat, up: Bool) {
        let p = NSBezierPath()
        p.lineWidth = 6; p.lineCapStyle = .round
        p.appendArc(withCenter: NSPoint(x: c.x, y: c.y - 6), radius: w / 2 + 2, startAngle: 20, endAngle: 160)
        p.stroke()
    }

    private func heart(_ c: NSPoint, size s: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y - s * 0.5))
        p.curve(to: NSPoint(x: c.x - s * 0.5, y: c.y + s * 0.15), controlPoint1: NSPoint(x: c.x - s * 0.15, y: c.y - s * 0.3), controlPoint2: NSPoint(x: c.x - s * 0.5, y: c.y - s * 0.15))
        p.curve(to: NSPoint(x: c.x, y: c.y + s * 0.15), controlPoint1: NSPoint(x: c.x - s * 0.5, y: c.y + s * 0.5), controlPoint2: NSPoint(x: c.x, y: c.y + s * 0.45))
        p.curve(to: NSPoint(x: c.x + s * 0.5, y: c.y + s * 0.15), controlPoint1: NSPoint(x: c.x, y: c.y + s * 0.45), controlPoint2: NSPoint(x: c.x + s * 0.5, y: c.y + s * 0.5))
        p.curve(to: NSPoint(x: c.x, y: c.y - s * 0.5), controlPoint1: NSPoint(x: c.x + s * 0.5, y: c.y - s * 0.15), controlPoint2: NSPoint(x: c.x + s * 0.15, y: c.y - s * 0.3))
        p.fill()
    }

    private func drawMouth(center c: NSPoint) {
        let open = smoothedMouth
        if open > 0.04 {
            let w = 14 + 10 * open, h = 3 + 14 * open
            NSBezierPath(roundedRect: NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
            return
        }
        let p = NSBezierPath(); p.lineWidth = 3; p.lineCapStyle = .round
        switch mood {
        case .happy, .love:
            p.appendArc(withCenter: NSPoint(x: c.x, y: c.y + 6), radius: 9, startAngle: 200, endAngle: 340)
        case .sad:
            p.appendArc(withCenter: NSPoint(x: c.x, y: c.y - 8), radius: 9, startAngle: 30, endAngle: 150)
        case .surprised:
            p.appendOval(in: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        case .annoyed:
            p.move(to: NSPoint(x: c.x - 9, y: c.y - 1)); p.line(to: NSPoint(x: c.x - 3, y: c.y + 2))
            p.line(to: NSPoint(x: c.x + 3, y: c.y - 1)); p.line(to: NSPoint(x: c.x + 9, y: c.y + 2))
        case .sleepy, .idle, .focused:
            p.move(to: NSPoint(x: c.x - 6, y: c.y)); p.line(to: NSPoint(x: c.x + 6, y: c.y))
        }
        p.stroke()
    }

    private func drawBubble(_ text: String, above face: NSRect) {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1), .paragraphStyle: para]
        let maxW = bounds.width - 20
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.boundingRect(with: NSSize(width: maxW - 20, height: 200), options: [.usesLineFragmentOrigin]).size
        let w = min(maxW, ceil(size.width) + 22), h = min(Self.bubbleHeight - 14, ceil(size.height) + 14)
        let r = NSRect(x: (bounds.width - w) / 2, y: face.maxY + 10, width: w, height: h)
        let p = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        // Tail pointing down at the face.
        p.move(to: NSPoint(x: r.midX - 7, y: r.minY + 1)); p.line(to: NSPoint(x: r.midX, y: r.minY - 8)); p.line(to: NSPoint(x: r.midX + 7, y: r.minY + 1))
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow(); s.shadowBlurRadius = 4; s.shadowOffset = NSSize(width: 0, height: -1); s.shadowColor = NSColor.black.withAlphaComponent(0.3); s.set()
        NSColor(calibratedWhite: 0.98, alpha: 0.97).setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        str.draw(with: r.insetBy(dx: 10, dy: 7), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Poke vs drag

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override func mouseDown(with event: NSEvent) { mouseDownAt = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        win.setFrameOrigin(NSPoint(x: win.frame.origin.x + event.deltaX, y: win.frame.origin.y - event.deltaY))
    }
    override func mouseUp(with event: NSEvent) {
        if let d = mouseDownAt, hypot(NSEvent.mouseLocation.x - d.x, NSEvent.mouseLocation.y - d.y) < 4 {
            if event.clickCount == 2 { onDoubleClick?() } else if event.clickCount == 1 { onPoke?() }
        }
        mouseDownAt = nil
        if let win = window { UserDefaults.standard.set(NSStringFromPoint(win.frame.origin), forKey: "petOrigin") }
    }
}

final class PetWindow: NSPanel {
    let face: FaceView

    init() {
        let size = NSSize(width: 250, height: FaceView.faceSize.height + FaceView.bubbleHeight)
        face = FaceView(frame: NSRect(origin: .zero, size: size))
        var origin = NSPoint(x: 40, y: 40)
        if let saved = UserDefaults.standard.string(forKey: "petOrigin") {
            origin = NSPointFromString(saved)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.minY + 24)
        }
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = face
    }

    override var canBecomeKey: Bool { false }
}

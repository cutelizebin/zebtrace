import AppKit

/// A template image keeps the Z trace legible in both light and dark menu bars.
enum StatusIcon {
    enum State { case idle, recording, busy, failed }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let trace = NSBezierPath()
            trace.lineWidth = 2
            trace.lineCapStyle = .round
            trace.lineJoinStyle = .round
            trace.move(to: NSPoint(x: 2.5, y: 14))
            trace.line(to: NSPoint(x: 13.5, y: 14))
            trace.line(to: NSPoint(x: 2.5, y: 4))
            trace.line(to: NSPoint(x: 13.5, y: 4))
            trace.stroke()

            switch state {
            case .idle, .recording:
                let endpoint = NSBezierPath(ovalIn: NSRect(x: 16.4, y: 1.9, width: 4.2, height: 4.2))
                endpoint.lineWidth = 1.3
                if state == .recording { endpoint.fill() } else { endpoint.stroke() }
            case .busy:
                for x in [16.4, 18.6, 20.8] {
                    NSBezierPath(ovalIn: NSRect(x: x - 0.7, y: 3.3, width: 1.4, height: 1.4)).fill()
                }
            case .failed:
                let stem = NSBezierPath()
                stem.lineWidth = 1.6
                stem.lineCapStyle = .round
                stem.move(to: NSPoint(x: 18.5, y: 8))
                stem.line(to: NSPoint(x: 18.5, y: 5))
                stem.stroke()
                NSBezierPath(ovalIn: NSRect(x: 17.65, y: 1.65, width: 1.7, height: 1.7)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

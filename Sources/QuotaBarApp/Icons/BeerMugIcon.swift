import AppKit
import QuotaBarCore

enum BeerMugIcon {
    /// Center & diameter of the colored weekly watermark dot inside the `18x18` icon coordinate space.
    static let dotCenter = NSPoint(x: 14.5, y: 13.7)
    static let dotDiameter: CGFloat = 5.0
    private static let cutoutHaloRadius: CGFloat = 3.8

    /// Creates a crisp, vector-drawn macOS monochrome template image (`isTemplate = true`)
    /// sized to match Apple's native menu bar SF Symbols (18x18 pt).
    /// When `hasStatusDot` is `true`, carves a clean circular cutout halo at top-right so the
    /// colored Green / Yellow / Red weekly watermark dot sits with razor-sharp contrast.
    static func makeMenuBarImage(hasStatusDot: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let strokeWidth: CGFloat = 1.5

            // 1. Mug handle on the right (D-curve from y=10.1 down to y=4.7)
            let handle = NSBezierPath()
            handle.lineWidth = strokeWidth
            handle.lineCapStyle = .round
            handle.lineJoinStyle = .round
            handle.move(to: NSPoint(x: 11.8, y: 10.1))
            handle.line(to: NSPoint(x: 13.4, y: 10.1))
            handle.curve(
                to: NSPoint(x: 15.1, y: 8.4),
                controlPoint1: NSPoint(x: 14.4, y: 10.1),
                controlPoint2: NSPoint(x: 15.1, y: 9.4)
            )
            handle.line(to: NSPoint(x: 15.1, y: 6.4))
            handle.curve(
                to: NSPoint(x: 13.4, y: 4.7),
                controlPoint1: NSPoint(x: 15.1, y: 5.4),
                controlPoint2: NSPoint(x: 14.4, y: 4.7)
            )
            handle.line(to: NSPoint(x: 11.8, y: 4.7))
            handle.stroke()

            // 2. Mug body (open top meeting the foam, rounded bottom corners)
            let body = NSBezierPath()
            body.lineWidth = strokeWidth
            body.lineCapStyle = .round
            body.lineJoinStyle = .round
            body.move(to: NSPoint(x: 3.1, y: 11.5))
            body.line(to: NSPoint(x: 3.1, y: 4.1))
            body.curve(
                to: NSPoint(x: 5.1, y: 2.1),
                controlPoint1: NSPoint(x: 3.1, y: 2.9),
                controlPoint2: NSPoint(x: 4.0, y: 2.1)
            )
            body.line(to: NSPoint(x: 9.8, y: 2.1))
            body.curve(
                to: NSPoint(x: 11.8, y: 4.1),
                controlPoint1: NSPoint(x: 10.9, y: 2.1),
                controlPoint2: NSPoint(x: 11.8, y: 2.9)
            )
            body.line(to: NSPoint(x: 11.8, y: 11.5))
            body.stroke()

            // 3. Fluffy beer foam head crowning the rim (3 clean cloud arcs)
            let foam = NSBezierPath()
            foam.lineWidth = strokeWidth
            foam.lineCapStyle = .round
            foam.lineJoinStyle = .round
            foam.move(to: NSPoint(x: 2.9, y: 11.6))
            foam.curve(
                to: NSPoint(x: 5.4, y: 14.3),
                controlPoint1: NSPoint(x: 2.3, y: 13.3),
                controlPoint2: NSPoint(x: 3.8, y: 14.6)
            )
            foam.curve(
                to: NSPoint(x: 9.5, y: 14.3),
                controlPoint1: NSPoint(x: 6.1, y: 16.2),
                controlPoint2: NSPoint(x: 8.8, y: 16.2)
            )
            foam.curve(
                to: NSPoint(x: 12.0, y: 11.6),
                controlPoint1: NSPoint(x: 11.1, y: 14.6),
                controlPoint2: NSPoint(x: 12.6, y: 13.3)
            )
            foam.curve(
                to: NSPoint(x: 7.45, y: 11.4),
                controlPoint1: NSPoint(x: 10.7, y: 11.0),
                controlPoint2: NSPoint(x: 8.8, y: 11.9)
            )
            foam.curve(
                to: NSPoint(x: 2.9, y: 11.6),
                controlPoint1: NSPoint(x: 6.1, y: 10.9),
                controlPoint2: NSPoint(x: 4.1, y: 11.1)
            )
            foam.stroke()

            // 4. Two crisp vertical glass flutes inside the mug
            let fluteWidth: CGFloat = 1.2
            for xPos in [6.0, 8.9] as [CGFloat] {
                let flute = NSBezierPath()
                flute.lineWidth = fluteWidth
                flute.lineCapStyle = .round
                flute.move(to: NSPoint(x: xPos, y: 4.5))
                flute.line(to: NSPoint(x: xPos, y: 9.2))
                flute.stroke()
            }

            // 5. Transparent cutout halo when the colored weekly watermark dot is active
            if hasStatusDot, let cg = NSGraphicsContext.current?.cgContext {
                cg.saveGState()
                cg.setBlendMode(.clear)
                let haloRect = CGRect(
                    x: dotCenter.x - cutoutHaloRadius,
                    y: dotCenter.y - cutoutHaloRadius,
                    width: cutoutHaloRadius * 2,
                    height: cutoutHaloRadius * 2
                )
                cg.fillEllipse(in: haloRect)
                cg.restoreGState()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}

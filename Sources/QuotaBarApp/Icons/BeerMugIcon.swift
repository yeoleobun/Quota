import AppKit
import QuotaBarCore

enum BeerMugIcon {
    /// Center & diameter of the colored weekly watermark dot inside the `18x18` icon coordinate space.
    static let dotCenter = NSPoint(x: 14.2, y: 14.0)
    static let dotDiameter: CGFloat = 5.0
    private static let cutoutHaloRadius: CGFloat = 3.6

    /// Creates a crisp, vector-drawn macOS monochrome template image (`isTemplate = true`)
    /// sized to match Apple's native menu bar SF Symbols (18x18 pt).
    /// Draws a curved Weizen wheat-beer glass (小麦杯) with a 4-point sparkle (`✦`) emblem.
    /// When `hasStatusDot` is `true`, carves a clean circular cutout halo at top-right so the
    /// colored Green / Yellow / Red weekly watermark dot sits with razor-sharp contrast.
    static func makeMenuBarImage(hasStatusDot: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // 1. Curved Weizen wheat-beer glass contour (dome rim, flared upper bowl, narrow waist, heavy foot)
            let glass = NSBezierPath()
            glass.lineWidth = 1.45
            glass.lineCapStyle = .round
            glass.lineJoinStyle = .round

            glass.move(to: NSPoint(x: 4.6, y: 14.4))
            glass.curve(
                to: NSPoint(x: 12.2, y: 14.4),
                controlPoint1: NSPoint(x: 6.2, y: 15.8),
                controlPoint2: NSPoint(x: 10.6, y: 15.8)
            )
            glass.curve(
                to: NSPoint(x: 10.6, y: 5.2),
                controlPoint1: NSPoint(x: 12.9, y: 11.4),
                controlPoint2: NSPoint(x: 10.5, y: 7.6)
            )
            glass.curve(
                to: NSPoint(x: 11.2, y: 2.0),
                controlPoint1: NSPoint(x: 10.65, y: 3.8),
                controlPoint2: NSPoint(x: 11.2, y: 2.7)
            )
            glass.line(to: NSPoint(x: 5.6, y: 2.0))
            glass.curve(
                to: NSPoint(x: 6.2, y: 5.2),
                controlPoint1: NSPoint(x: 5.6, y: 2.7),
                controlPoint2: NSPoint(x: 6.15, y: 3.8)
            )
            glass.curve(
                to: NSPoint(x: 4.6, y: 14.4),
                controlPoint1: NSPoint(x: 6.3, y: 7.6),
                controlPoint2: NSPoint(x: 3.9, y: 11.4)
            )
            glass.close()
            glass.stroke()

            // 2. Foam collar line across the upper bowl
            let foamLine = NSBezierPath()
            foamLine.lineWidth = 1.25
            foamLine.move(to: NSPoint(x: 4.5, y: 12.7))
            foamLine.line(to: NSPoint(x: 12.3, y: 12.7))
            foamLine.stroke()

            // 3. Heavy glass foot accent line
            let footLine = NSBezierPath()
            footLine.lineWidth = 1.15
            footLine.move(to: NSPoint(x: 5.9, y: 3.2))
            footLine.line(to: NSPoint(x: 10.9, y: 3.2))
            footLine.stroke()

            // 4. Centered 4-point curved sparkle (`✦`) emblem
            let cx: CGFloat = 8.4
            let cy: CGFloat = 9.3
            let r: CGFloat = 2.35
            let k: CGFloat = 0.42
            let star = NSBezierPath()
            star.move(to: NSPoint(x: cx, y: cy + r))
            star.curve(
                to: NSPoint(x: cx + r, y: cy),
                controlPoint1: NSPoint(x: cx + r * 0.12, y: cy + r * k),
                controlPoint2: NSPoint(x: cx + r * k, y: cy + r * 0.12)
            )
            star.curve(
                to: NSPoint(x: cx, y: cy - r),
                controlPoint1: NSPoint(x: cx + r * k, y: cy - r * 0.12),
                controlPoint2: NSPoint(x: cx + r * 0.12, y: cy - r * k)
            )
            star.curve(
                to: NSPoint(x: cx - r, y: cy),
                controlPoint1: NSPoint(x: cx - r * 0.12, y: cy - r * k),
                controlPoint2: NSPoint(x: cx - r * k, y: cy - r * 0.12)
            )
            star.curve(
                to: NSPoint(x: cx, y: cy + r),
                controlPoint1: NSPoint(x: cx - r * k, y: cy + r * 0.12),
                controlPoint2: NSPoint(x: cx - r * 0.12, y: cy + r * k)
            )
            star.close()
            star.fill()

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

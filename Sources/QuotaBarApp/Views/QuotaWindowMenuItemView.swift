import AppKit
import QuotaBarCore

/// Pure AppKit view used exclusively inside `NSMenuItem.view` for non-interactive quota meter rows.
/// Draws zero background so `NSMenu`'s genuine system glass backdrop shines directly through,
/// using exact `NSMenu` horizontal margins (`leading = 28 pt`, `trailing = 15 pt`).
final class QuotaWindowMenuItemView: NSView {
    private static let menuWidth: CGFloat = 300
    private static let leadingMargin: CGFloat = 28
    private static let trailingMargin: CGFloat = 15
    private static let ringSize: CGFloat = 13

    private let windowData: QuotaWindow
    private let referenceDate: Date

    init(window: QuotaWindow, now: Date) {
        self.windowData = window
        self.referenceDate = now

        let resetSummary = window.formattedResetSummary(now: now)
        let rowHeight: CGFloat = (resetSummary == nil) ? 24 : 38
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: rowHeight))
        self.autoresizingMask = [.width]
        setupSubviews(resetSummary: resetSummary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    private func setupSubviews(resetSummary: String?) {
        // Left stack: Window label + optional reset countdown
        let titleField = NSTextField(labelWithString: windowData.label)
        titleField.font = NSFont.menuFont(ofSize: 13)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 1
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(titleField)

        if let resetSummary {
            let subField = NSTextField(labelWithString: resetSummary)
            subField.font = NSFont.systemFont(ofSize: 11)
            subField.textColor = .secondaryLabelColor
            subField.lineBreakMode = .byTruncatingTail
            leftStack.addArrangedSubview(subField)
        }

        // Right stack: Remaining % + Ring Gauge
        let percentField = NSTextField(labelWithString: "\(windowData.remainingPercent)%")
        percentField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        percentField.textColor = percentageTextColor
        percentField.alignment = .right
        percentField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let ringView = NativeQuotaRingView(
            fraction: Double(max(0, min(100, windowData.remainingPercent))) / 100.0,
            ringColor: ringStatusColor
        )
        ringView.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [percentField, ringView])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 7
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            ringView.widthAnchor.constraint(equalToConstant: Self.ringSize),
            ringView.heightAnchor.constraint(equalToConstant: Self.ringSize),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingMargin),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -10),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingMargin),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private var percentageTextColor: NSColor {
        if windowData.usedPercent >= 90 {
            return .systemRed
        } else if windowData.usedPercent >= 75 {
            return .systemOrange
        } else {
            return .labelColor
        }
    }

    private var ringStatusColor: NSColor {
        if windowData.usedPercent >= 90 {
            return .systemRed
        } else if windowData.usedPercent >= 75 {
            return .systemYellow
        } else {
            return .systemGreen
        }
    }
}

private final class NativeQuotaRingView: NSView {
    private let fraction: Double
    private let ringColor: NSColor

    init(fraction: Double, ringColor: NSColor) {
        self.fraction = max(0.0, min(1.0, fraction))
        self.ringColor = ringColor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 1.9
        let inset = lineWidth / 2.0 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(rect.width, rect.height) / 2.0

        // Subtle background track
        let trackPath = NSBezierPath(ovalIn: rect)
        trackPath.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        trackPath.stroke()

        // Remaining quota arc starting from 12 o'clock (90° in unflipped AppKit coords) clockwise
        guard fraction > 0.005 else { return }
        let arcPath = NSBezierPath()
        arcPath.lineWidth = lineWidth
        arcPath.lineCapStyle = .round
        let startAngle: CGFloat = 90.0
        let endAngle: CGFloat = 90.0 - CGFloat(fraction * 360.0)
        arcPath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        ringColor.setStroke()
        arcPath.stroke()
    }
}

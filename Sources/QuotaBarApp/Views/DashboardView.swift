import AppKit
import Combine
import QuotaBarCore
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var selectedProvider: ProviderID
    @Published var timeRange: DashboardTimeRange = .days7
    @Published var selectedModel: String? = nil

    /// Drives the staggered bottom-up bar wave animation (0 -> 1).
    @Published var barsRevealed: Bool = false
    /// Incremented on each data load so bars cleanly replay the bottom-up wave.
    @Published var animationEpoch: Int = 0
    /// Currently hovered bar index for floating tooltip & spotlight.
    @Published var hoveredIndex: Int? = nil
    /// Refresh icon rotation angle.
    @Published var refreshRotation: Double = 0.0

    init(initialProvider: ProviderID = .codex) {
        self.selectedProvider = initialProvider
    }

    var providerFilter: ProviderFilter {
        switch selectedProvider {
        case .codex: return .codex
        case .antigravity: return .antigravity
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var viewModel: DashboardViewModel

    private var analytics: DashboardAnalytics {
        store.analytics
    }

    private var accentColor: Color {
        viewModel.selectedProvider == .codex
            ? Color(red: 0.14, green: 0.68, blue: 0.46)
            : Color(red: 0.25, green: 0.47, blue: 0.96)
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.68)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBarHeader
            Divider().opacity(0.45)
            reportCanvas
        }
        .frame(minWidth: 700, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await reload(animated: true)
        }
        .onChange(of: viewModel.selectedProvider) { _, _ in
            viewModel.selectedModel = nil
            viewModel.hoveredIndex = nil
            Task { await reload(animated: true) }
        }
        .onChange(of: viewModel.timeRange) { _, _ in
            viewModel.hoveredIndex = nil
            Task { await reload(animated: true) }
        }
        .onChange(of: viewModel.selectedModel) { _, _ in
            viewModel.hoveredIndex = nil
            Task { await reload(animated: true) }
        }
    }

    // MARK: - Top Tab Bar Header

    private var tabBarHeader: some View {
        ZStack {
            VisualEffectBackdrop(material: .headerView, blendingMode: .withinWindow)

            HStack(spacing: 12) {
                // Breathing room for macOS traffic lights in fullSizeContentView
                Spacer().frame(width: 68)

                // Clean Pill Tabs: Codex | Antigravity
                HStack(spacing: 4) {
                    ProviderTabButton(
                        provider: .codex,
                        snapshot: store.snapshot(for: .codex),
                        isSelected: viewModel.selectedProvider == .codex,
                        accent: Color(red: 0.14, green: 0.68, blue: 0.46)
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            viewModel.selectedProvider = .codex
                        }
                    }

                    ProviderTabButton(
                        provider: .antigravity,
                        snapshot: store.snapshot(for: .antigravity),
                        isSelected: viewModel.selectedProvider == .antigravity,
                        accent: Color(red: 0.25, green: 0.47, blue: 0.96)
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            viewModel.selectedProvider = .antigravity
                        }
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Spacer()

                // Model Filter Dropdown
                Menu {
                    Button {
                        viewModel.selectedModel = nil
                    } label: {
                        HStack {
                            Text("All Models")
                            if viewModel.selectedModel == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    if !analytics.availableModels.isEmpty {
                        Divider()
                        ForEach(analytics.availableModels, id: \.self) { model in
                            Button {
                                viewModel.selectedModel = model
                            } label: {
                                HStack {
                                    Text(model)
                                    if viewModel.selectedModel == model {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(viewModel.selectedModel == nil ? .secondary : accentColor)
                        Text(viewModel.selectedModel ?? "All Models")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 135, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Day / Week / Month
                Picker("Range", selection: $viewModel.timeRange) {
                    ForEach(DashboardTimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 165)

                Button {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        viewModel.refreshRotation += 360
                    }
                    Task {
                        await reload(animated: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .rotationEffect(.degrees(viewModel.refreshRotation))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rescan local token logs")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(height: 50)
    }

    // MARK: - macOS Report Canvas (Screen Time Style)

    private var reportCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                chartReportCard
                modelsReportCard
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Main Report Card (Hero Stat + Bottom-Up Bar Chart + Composition Bar)

    private var chartReportCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Apple Screen Time–style Hero Metric Header
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedModel == nil ? "TOTAL TOKENS" : "MODEL TOKENS · \(viewModel.selectedModel!.uppercased())")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TokenFormatter.compact(analytics.totalTokens))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.35), value: analytics.totalTokens)

                        if averagePerBucket > 0 {
                            Text("avg \(TokenFormatter.compact(averagePerBucket))/\(viewModel.timeRange == .day24h ? "hr" : "day")")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer()

                HStack(spacing: 16) {
                    CompactStatPill(title: "Cache Hit", value: String(format: "%.0f%%", analytics.cacheHitRate * 100))
                    CompactStatPill(title: "Turns", value: "\(analytics.totalTurns)")
                }
            }

            // Custom True Bottom-Up Staggered Bar Chart
            if analytics.totalTokens == 0 && !store.isLoadingAnalytics {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No \(viewModel.selectedProvider.displayName) token usage recorded in the last \(viewModel.timeRange.rawValue.lowercased()).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 40)
            } else {
                ScreenTimeBarChart(
                    buckets: analytics.tokenBuckets,
                    timeRange: viewModel.timeRange,
                    accentColor: accentColor,
                    accentGradient: accentGradient,
                    revealed: viewModel.barsRevealed,
                    epoch: viewModel.animationEpoch,
                    hoveredIndex: $viewModel.hoveredIndex
                )
                .frame(height: 210)
            }

            // Clean Token Composition Proportion Bar (Input / Cached / Output)
            if analytics.totalTokens > 0 {
                Divider().opacity(0.45)
                TokenCompositionStrip(
                    uncachedInput: analytics.totalUncachedInputTokens,
                    cachedInput: analytics.totalCachedInputTokens,
                    output: analytics.totalOutputTokens,
                    accentColor: accentColor
                )
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Apple Settings–Style "Models" Grouped Report List

    private var modelsReportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MODELS USED")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                if viewModel.selectedModel != nil {
                    Button("Show All") {
                        viewModel.selectedModel = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 4)

            if analytics.modelSummaries.isEmpty {
                HStack {
                    Text("No model activity in this period.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            } else {
                let maxModelTokens = max(1, analytics.modelSummaries.first?.totalTokens ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(analytics.modelSummaries.enumerated()), id: \.element.id) { idx, item in
                        let isSelected = viewModel.selectedModel == item.model
                        Button {
                            viewModel.selectedModel = isSelected ? nil : item.model
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "cpu")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSelected ? accentColor : .secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.model)
                                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(item.turnCount) turns · \(String(format: "%.0f%%", item.cacheHitRate * 100)) cache")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }

                                    GeometryReader { geo in
                                        let ratio = CGFloat(item.totalTokens) / CGFloat(maxModelTokens)
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.primary.opacity(0.06))
                                            Capsule()
                                                .fill(isSelected ? accentColor : accentColor.opacity(0.65))
                                                .frame(width: max(4, geo.size.width * ratio))
                                        }
                                    }
                                    .frame(height: 5)
                                }

                                Text(TokenFormatter.compact(item.totalTokens))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                    .frame(width: 68, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(isSelected ? accentColor.opacity(0.09) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if idx < analytics.modelSummaries.count - 1 {
                            Divider()
                                .opacity(0.45)
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Helpers

    private var headerSubtitle: String {
        let rangeDesc: String
        switch viewModel.timeRange {
        case .day24h: rangeDesc = "Last 24 hours · Hourly breakdown"
        case .days7: rangeDesc = "Last 7 days · Daily breakdown"
        case .days30: rangeDesc = "Last 30 days · Daily breakdown"
        }
        return rangeDesc
    }

    private var averagePerBucket: Double {
        let active = analytics.tokenBuckets.filter { $0.totalTokens > 0 }
        guard !active.isEmpty else { return 0 }
        let sum = active.reduce(Int64(0)) { $0 + $1.totalTokens }
        return Double(sum) / Double(active.count)
    }

    private func reload(animated: Bool) async {
        if animated {
            viewModel.barsRevealed = false
        }
        await store.loadAnalytics(
            timeRange: viewModel.timeRange,
            providerFilter: viewModel.providerFilter,
            modelFilter: viewModel.selectedModel
        )
        viewModel.animationEpoch += 1
        if animated {
            try? await Task.sleep(nanoseconds: 25_000_000)
            viewModel.barsRevealed = true
        } else {
            viewModel.barsRevealed = true
        }
    }
}

// MARK: - Custom Apple Screen Time–Style Bottom-Up Staggered Bar Chart

private struct ScreenTimeBarChart: View {
    let buckets: [TokenBucket]
    let timeRange: DashboardTimeRange
    let accentColor: Color
    let accentGradient: LinearGradient
    let revealed: Bool
    let epoch: Int
    @Binding var hoveredIndex: Int?

    private var maxVal: Double {
        let peak = Double(buckets.map(\.totalTokens).max() ?? 0)
        return max(1.0, peak * 1.15)
    }

    private var activeAverage: Double {
        let nonZero = buckets.filter { $0.totalTokens > 0 }
        guard !nonZero.isEmpty else { return 0 }
        return Double(nonZero.reduce(Int64(0)) { $0 + $1.totalTokens }) / Double(nonZero.count)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let yAxisWidth: CGFloat = 46
                let plotWidth = max(1, geo.size.width - yAxisWidth)
                let plotHeight = max(1, geo.size.height)

                HStack(spacing: 0) {
                    // Main Plot Area
                    ZStack(alignment: .bottom) {
                        // Subtle horizontal dashed gridlines (0%, 50%, 100%)
                        VStack(spacing: 0) {
                            gridLine
                            Spacer()
                            gridLine
                            Spacer()
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(height: 0.75)
                        }

                        // Apple Screen Time–style Average dashed line
                        if activeAverage > 0 && revealed {
                            let avgRatio = min(0.98, activeAverage / maxVal)
                            let avgY = plotHeight * (1.0 - CGFloat(avgRatio))
                            ZStack(alignment: .trailing) {
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: avgY))
                                    path.addLine(to: CGPoint(x: plotWidth, y: avgY))
                                }
                                .stroke(accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                                Text("avg")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(accentColor)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: Capsule())
                                    .position(x: plotWidth - 16, y: max(10, avgY - 10))
                            }
                            .transition(.opacity)
                            .animation(.easeOut(duration: 0.35).delay(0.2), value: revealed)
                        }

                        // Bars strictly anchored at bottom, rising with a staggered left-to-right spring wave
                        HStack(alignment: .bottom, spacing: barSpacing) {
                            ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, bucket in
                                let valueRatio = min(1.0, Double(bucket.totalTokens) / maxVal)
                                let targetHeight = bucket.totalTokens > 0 ? max(4.0, plotHeight * CGFloat(valueRatio)) : 0
                                let isHovered = hoveredIndex == idx
                                let isDimmed = hoveredIndex != nil && !isHovered
                                let stagger = min(0.28, Double(idx) * (timeRange == .days7 ? 0.035 : 0.011))

                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    UnevenRoundedRectangle(
                                        topLeadingRadius: barCornerRadius,
                                        bottomLeadingRadius: 0,
                                        bottomTrailingRadius: 0,
                                        topTrailingRadius: barCornerRadius,
                                        style: .continuous
                                    )
                                    .fill(accentGradient)
                                    .frame(height: revealed ? targetHeight : 0)
                                    .opacity(isDimmed ? 0.32 : 1.0)
                                    .animation(
                                        .spring(response: 0.48, dampingFraction: 0.80)
                                            .delay(revealed ? stagger : 0),
                                        value: revealed
                                    )
                                    .animation(.easeOut(duration: 0.12), value: hoveredIndex)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering {
                                        hoveredIndex = idx
                                    } else if hoveredIndex == idx {
                                        hoveredIndex = nil
                                    }
                                }
                            }
                        }
                        .id("\(epoch)-\(buckets.count)")

                        // Floating Glass Tooltip anchored above hovered bar
                        if let idx = hoveredIndex, idx >= 0, idx < buckets.count {
                            let bucket = buckets[idx]
                            let slotWidth = plotWidth / CGFloat(max(1, buckets.count))
                            let rawX = slotWidth * (CGFloat(idx) + 0.5)
                            let clampedX = min(max(95, rawX), max(95, plotWidth - 95))

                            HoverTooltipPill(
                                bucket: bucket,
                                timeRange: timeRange,
                                accentColor: accentColor
                            )
                            .position(x: clampedX, y: 24)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: plotWidth, height: plotHeight)

                    // Right-aligned Y-Axis (just like macOS Screen Time / Battery!)
                    VStack(alignment: .trailing) {
                        Text(TokenFormatter.compact(maxVal))
                        Spacer()
                        Text(TokenFormatter.compact(maxVal / 2.0))
                        Spacer()
                        Text("0")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: yAxisWidth, height: plotHeight, alignment: .trailing)
                }
            }

            // Clean X-Axis Labels
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, bucket in
                        Text(xAxisLabel(for: bucket.date, index: idx))
                            .font(.system(size: 10))
                            .foregroundStyle(hoveredIndex == idx ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                    }
                }
                Spacer().frame(width: 46)
            }
        }
    }

    private var gridLine: some View {
        GeometryReader { g in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: g.size.width, y: 0.5))
            }
            .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        }
        .frame(height: 1)
    }

    private var barSpacing: CGFloat {
        switch timeRange {
        case .days7: return 14
        case .day24h: return 4
        case .days30: return 3
        }
    }

    private var barCornerRadius: CGFloat {
        switch timeRange {
        case .days7: return 6
        case .day24h: return 3.5
        case .days30: return 3
        }
    }

    private func xAxisLabel(for date: Date, index: Int) -> String {
        let f = DateFormatter()
        switch timeRange {
        case .days7:
            f.dateFormat = "EEE"
            return f.string(from: date)
        case .day24h:
            guard index % 4 == 0 || index == buckets.count - 1 else { return "" }
            f.dateFormat = "HH"
            return f.string(from: date)
        case .days30:
            guard index % 5 == 0 || index == buckets.count - 1 else { return "" }
            f.dateFormat = "M/d"
            return f.string(from: date)
        }
    }
}

// MARK: - Floating Glass Hover Tooltip

private struct HoverTooltipPill: View {
    let bucket: TokenBucket
    let timeRange: DashboardTimeRange
    let accentColor: Color

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = (timeRange == .day24h) ? "MMM d, HH:00" : "EEE, MMM d"
        return f.string(from: bucket.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(dateLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 6)
                Text(TokenFormatter.compact(bucket.totalTokens))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accentColor)
                    .monospacedDigit()
            }
            Text("In \(TokenFormatter.compact(bucket.uncachedInputTokens)) · Cache \(TokenFormatter.compact(bucket.cachedInputTokens)) · Out \(TokenFormatter.compact(bucket.outputTokens))")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        .fixedSize()
    }
}

// MARK: - Token Composition Proportion Strip

private struct TokenCompositionStrip: View {
    let uncachedInput: Int64
    let cachedInput: Int64
    let output: Int64
    let accentColor: Color

    private var total: Double {
        max(1.0, Double(uncachedInput + cachedInput + output))
    }

    var body: some View {
        let outputColor = Color(red: 0.94, green: 0.56, blue: 0.22)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 2) {
                    if uncachedInput > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accentColor)
                            .frame(width: max(3, w * CGFloat(Double(uncachedInput) / total)))
                    }
                    if cachedInput > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accentColor.opacity(0.32))
                            .frame(width: max(3, w * CGFloat(Double(cachedInput) / total)))
                    }
                    if output > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(outputColor)
                            .frame(width: max(3, w * CGFloat(Double(output) / total)))
                    }
                }
            }
            .frame(height: 7)
            .clipShape(Capsule())

            HStack(spacing: 16) {
                LegendItem(color: accentColor, label: "Input", value: TokenFormatter.compact(uncachedInput))
                LegendItem(color: accentColor.opacity(0.35), label: "Cached", value: TokenFormatter.compact(cachedInput))
                LegendItem(color: outputColor, label: "Output", value: TokenFormatter.compact(output))
                Spacer()
            }
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
    }
}

// MARK: - Provider Tab Button & Native Blur Backdrop

private struct ProviderTabButton: View {
    let provider: ProviderID
    let snapshot: ProviderSnapshot
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: provider == .codex ? "terminal.fill" : "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .secondary)

                Text(provider.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if let plan = snapshot.planLabel, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? accent : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (isSelected ? accent : Color.secondary).opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            )
            .shadow(color: isSelected ? .black.opacity(0.08) : .clear, radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CompactStatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

import Foundation

// MARK: - Time Range

public enum DashboardTimeRange: String, CaseIterable, Identifiable, Sendable {
    case day24h = "Day"
    case days7 = "Week"
    case days30 = "Month"

    public var id: String { rawValue }

    public var durationSeconds: TimeInterval {
        switch self {
        case .day24h: return 24 * 3600
        case .days7: return 7 * 24 * 3600
        case .days30: return 30 * 24 * 3600
        }
    }

    public var bucketIntervalSeconds: TimeInterval {
        switch self {
        case .day24h: return 3600       // 1-hour buckets
        case .days7: return 24 * 3600   // 1-day buckets
        case .days30: return 24 * 3600  // 1-day buckets
        }
    }
}

public enum ProviderFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case codex = "Codex"
    case antigravity = "Antigravity"

    public var id: String { rawValue }

    public func matches(_ provider: ProviderID) -> Bool {
        switch self {
        case .all: return true
        case .codex: return provider == .codex
        case .antigravity: return provider == .antigravity
        }
    }
}

// MARK: - Option 1: Exact Local Token Usage

public struct TokenUsageEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let provider: ProviderID
    public let model: String
    public let uncachedInputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64

    public init(
        timestamp: Date,
        provider: ProviderID,
        model: String,
        uncachedInputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64 = 0
    ) {
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.uncachedInputTokens = max(0, uncachedInputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
    }

    public var totalInputTokens: Int64 {
        uncachedInputTokens + cachedInputTokens
    }

    public var totalTokens: Int64 {
        uncachedInputTokens + cachedInputTokens + outputTokens
    }
}

public struct TokenBucket: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let uncachedInputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64

    public init(
        date: Date,
        uncachedInputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64
    ) {
        self.id = "\(Int64(date.timeIntervalSince1970))"
        self.date = date
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    public var totalTokens: Int64 {
        uncachedInputTokens + cachedInputTokens + outputTokens
    }
}

public struct ModelTokenSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let model: String
    public let uncachedInputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let turnCount: Int

    public init(
        provider: ProviderID,
        model: String,
        uncachedInputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        reasoningTokens: Int64,
        turnCount: Int
    ) {
        self.id = "\(provider.rawValue)::\(model)"
        self.provider = provider
        self.model = model
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.turnCount = turnCount
    }

    public var totalInputTokens: Int64 {
        uncachedInputTokens + cachedInputTokens
    }

    public var totalTokens: Int64 {
        uncachedInputTokens + cachedInputTokens + outputTokens
    }

    public var cacheHitRate: Double {
        let denom = Double(totalInputTokens)
        guard denom > 0 else { return 0 }
        return Double(cachedInputTokens) / denom
    }
}

// MARK: - Option 2: Probing-Based Quota History & Cycle-Aware Fitting

public struct QuotaProbeSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let provider: ProviderID
    public let windowId: String
    public let windowLabel: String
    public let group: String?
    public let usedPercent: Int
    public let resetsAt: Date?
    public let windowDurationMins: Int?

    public init(
        timestamp: Date,
        provider: ProviderID,
        windowId: String,
        windowLabel: String,
        group: String? = nil,
        usedPercent: Int,
        resetsAt: Date? = nil,
        windowDurationMins: Int? = nil
    ) {
        self.timestamp = timestamp
        self.provider = provider
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.group = group
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    public var seriesKey: String {
        "\(provider.rawValue)::\(windowId)"
    }

    public var displayTitle: String {
        if let group, !group.isEmpty {
            return "\(provider.displayName) · \(group) · \(windowLabel)"
        }
        return "\(provider.displayName) · \(windowLabel)"
    }
}

public struct QuotaCycle: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let windowId: String
    public let windowLabel: String
    public let group: String?
    public let cycleIndex: Int
    public let samples: [QuotaProbeSample]

    public init(
        provider: ProviderID,
        windowId: String,
        windowLabel: String,
        group: String?,
        cycleIndex: Int,
        samples: [QuotaProbeSample]
    ) {
        self.id = "\(provider.rawValue)::\(windowId)::c\(cycleIndex)"
        self.provider = provider
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.group = group
        self.cycleIndex = cycleIndex
        self.samples = samples
    }

    public var startedAt: Date { samples.first?.timestamp ?? .distantPast }
    public var endedAt: Date { samples.last?.timestamp ?? .distantPast }
    public var latestResetsAt: Date? { samples.last?.resetsAt }
    public var peakUsedPercent: Int { samples.map(\.usedPercent).max() ?? 0 }
}

public struct QuotaDeltaEvent: Equatable, Sendable {
    public let startTime: Date
    public let endTime: Date
    public let provider: ProviderID
    public let windowId: String
    public let windowLabel: String
    public let group: String?
    public let deltaPercent: Int
    public let crossedResetBoundary: Bool
}

public struct BurnRateEstimate: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let windowId: String
    public let windowLabel: String
    public let group: String?
    public let currentUsedPercent: Int
    public let resetsAt: Date?
    public let burnRatePercentPerHour: Double
    public let projectedExhaustionDate: Date?
    public let willExhaustBeforeReset: Bool
    public let activeCycleSampleCount: Int
    public let cycleCountInRange: Int

    public init(
        provider: ProviderID,
        windowId: String,
        windowLabel: String,
        group: String?,
        currentUsedPercent: Int,
        resetsAt: Date?,
        burnRatePercentPerHour: Double,
        projectedExhaustionDate: Date?,
        willExhaustBeforeReset: Bool,
        activeCycleSampleCount: Int,
        cycleCountInRange: Int
    ) {
        self.id = "\(provider.rawValue)::\(windowId)"
        self.provider = provider
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.group = group
        self.currentUsedPercent = currentUsedPercent
        self.resetsAt = resetsAt
        self.burnRatePercentPerHour = burnRatePercentPerHour
        self.projectedExhaustionDate = projectedExhaustionDate
        self.willExhaustBeforeReset = willExhaustBeforeReset
        self.activeCycleSampleCount = activeCycleSampleCount
        self.cycleCountInRange = cycleCountInRange
    }

    public var currentRemainingPercent: Int {
        max(0, 100 - currentUsedPercent)
    }

    public var displayTitle: String {
        if let group, !group.isEmpty {
            return "\(group) · \(windowLabel)"
        }
        return windowLabel
    }
}

public struct TokensPerPercentEstimate: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let windowId: String
    public let windowLabel: String
    public let group: String?
    public let estimatedTokensPerPercent: Double
    public let matchedIntervals: Int
    public let totalDeltaPercent: Int
    public let totalMatchedTokens: Int64

    public init(
        provider: ProviderID,
        windowId: String,
        windowLabel: String,
        group: String?,
        estimatedTokensPerPercent: Double,
        matchedIntervals: Int,
        totalDeltaPercent: Int,
        totalMatchedTokens: Int64
    ) {
        self.id = "\(provider.rawValue)::\(windowId)"
        self.provider = provider
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.group = group
        self.estimatedTokensPerPercent = estimatedTokensPerPercent
        self.matchedIntervals = matchedIntervals
        self.totalDeltaPercent = totalDeltaPercent
        self.totalMatchedTokens = totalMatchedTokens
    }
}

// MARK: - Complete Dashboard Snapshot

public struct DashboardAnalytics: Equatable, Sendable {
    public let generatedAt: Date
    public let timeRange: DashboardTimeRange
    public let providerFilter: ProviderFilter
    public let selectedModel: String?
    public let availableModels: [String]

    // Token summary
    public let totalUncachedInputTokens: Int64
    public let totalCachedInputTokens: Int64
    public let totalOutputTokens: Int64
    public let totalReasoningTokens: Int64
    public let totalTurns: Int
    public let tokenBuckets: [TokenBucket]
    public let modelSummaries: [ModelTokenSummary]

    // Probing / cycle-aware quota summary
    public let probeCycles: [QuotaCycle]
    public let burnRates: [BurnRateEstimate]
    public let totalBurnedDeltaPercent: Int
    public let tokensPerPercentEstimates: [TokensPerPercentEstimate]

    public var totalInputTokens: Int64 {
        totalUncachedInputTokens + totalCachedInputTokens
    }

    public var totalTokens: Int64 {
        totalUncachedInputTokens + totalCachedInputTokens + outputTokensSafe
    }

    private var outputTokensSafe: Int64 { totalOutputTokens }

    public var cacheHitRate: Double {
        let denom = Double(totalInputTokens)
        guard denom > 0 else { return 0 }
        return Double(totalCachedInputTokens) / denom
    }

    public static func empty(
        timeRange: DashboardTimeRange = .days7,
        providerFilter: ProviderFilter = .codex,
        selectedModel: String? = nil,
        now: Date = Date()
    ) -> DashboardAnalytics {
        DashboardAnalytics(
            generatedAt: now,
            timeRange: timeRange,
            providerFilter: providerFilter,
            selectedModel: selectedModel,
            availableModels: [],
            totalUncachedInputTokens: 0,
            totalCachedInputTokens: 0,
            totalOutputTokens: 0,
            totalReasoningTokens: 0,
            totalTurns: 0,
            tokenBuckets: [],
            modelSummaries: [],
            probeCycles: [],
            burnRates: [],
            totalBurnedDeltaPercent: 0,
            tokensPerPercentEstimates: []
        )
    }
}

// MARK: - Formatting Helpers

public enum TokenFormatter {
    public static func compact(_ value: Int64) -> String {
        let absVal = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        if absVal >= 1_000_000_000 {
            return String(format: "%@%.2fB", sign, absVal / 1_000_000_000)
        } else if absVal >= 1_000_000 {
            return String(format: "%@%.2fM", sign, absVal / 1_000_000)
        } else if absVal >= 1_000 {
            return String(format: "%@%.1fK", sign, absVal / 1_000)
        } else {
            return "\(value)"
        }
    }

    public static func compact(_ value: Double) -> String {
        compact(Int64(value.rounded()))
    }
}

import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "codex"
    case antigravity = "antigravity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    public var shortCode: String {
        switch self {
        case .codex: return "C"
        case .antigravity: return "A"
        }
    }
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var group: String?
    public var label: String
    public var usedPercent: Int
    public var resetsAt: Date?
    public var windowDurationMins: Int?

    public init(
        id: String,
        group: String? = nil,
        label: String,
        usedPercent: Int,
        resetsAt: Date?,
        windowDurationMins: Int? = nil
    ) {
        self.id = id
        self.group = group
        self.label = label
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    public var isFiveHourWindow: Bool {
        if windowDurationMins == 300 { return true }
        let l = label.lowercased()
        return l.contains("5h") || l.contains("5-hour") || l.contains("5 hour") || l.contains("five hour")
    }

    public var isWeeklyWindow: Bool {
        if windowDurationMins == 10080 { return true }
        let l = label.lowercased()
        return l.contains("week") || l.contains("7-day") || l.contains("7 day") || l.contains("7d")
    }

    /// Formats a live countdown & reset timestamp relative to `now`, or `nil` when no active reset timer exists.
    public func formattedResetSummary(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 {
            return "Resetting soon…"
        }

        let totalMinutes = Int(remaining / 60.0)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        let countdown: String
        if days > 0 {
            countdown = "\(days)d \(hours)h"
        } else if hours > 0 {
            countdown = "\(hours)h \(minutes)m"
        } else {
            countdown = "\(max(1, minutes))m"
        }

        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(resetsAt) {
            formatter.dateFormat = "HH:mm"
            return "Resets in \(countdown) · today \(formatter.string(from: resetsAt))"
        } else {
            formatter.dateFormat = "MMM d, HH:mm"
            return "Resets in \(countdown) · \(formatter.string(from: resetsAt))"
        }
    }
}

public enum ProviderStatus: Codable, Equatable, Sendable {
    case idle
    case loading
    case ready
    case cliMissing(installHint: String)
    case needsAuth(message: String)
    case error(message: String)
}

public struct ProviderSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var status: ProviderStatus
    public var planLabel: String?
    public var accountEmail: String?
    public var creditsBalance: String?
    public var windows: [QuotaWindow]
    public var refreshWarning: String?
    public var binaryPath: String?
    public var updatedAt: Date?

    public var id: String { provider.rawValue }

    public init(
        provider: ProviderID,
        status: ProviderStatus = .idle,
        planLabel: String? = nil,
        accountEmail: String? = nil,
        creditsBalance: String? = nil,
        windows: [QuotaWindow] = [],
        refreshWarning: String? = nil,
        binaryPath: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.provider = provider
        self.status = status
        self.planLabel = planLabel
        self.accountEmail = accountEmail
        self.creditsBalance = creditsBalance
        self.windows = windows
        self.refreshWarning = refreshWarning
        self.binaryPath = binaryPath
        self.updatedAt = updatedAt
    }

    /// Returns the highest usage percentage among active quota windows.
    public var peakUsedPercent: Int? {
        windows.map(\.usedPercent).max()
    }

    /// Returns the primary 5-hour limit window if this provider/plan exposes one.
    public var fiveHourWindow: QuotaWindow? {
        windows.first(where: \.isFiveHourWindow)
    }

    /// Returns the primary weekly (7-day) limit window if this provider/plan exposes one.
    public var weeklyWindow: QuotaWindow? {
        windows.first(where: \.isWeeklyWindow)
    }

    /// Returns the highest used percentage across this provider's weekly (7-day) limit windows.
    public var peakWeeklyUsedPercent: Int? {
        let weeklyUsed = windows.filter(\.isWeeklyWindow).map(\.usedPercent).max()
        return weeklyUsed ?? peakUsedPercent
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var providerOrder: [ProviderID]
    public var selectedProvider: ProviderID
    public var showWeeklyIndicator: Bool
    public var refreshIntervalMinutes: Int
    public var customCodexPath: String
    public var customAgyPath: String

    public init(
        providerOrder: [ProviderID] = ProviderID.allCases,
        selectedProvider: ProviderID = .codex,
        showWeeklyIndicator: Bool = true,
        refreshIntervalMinutes: Int = 5,
        customCodexPath: String = "",
        customAgyPath: String = ""
    ) {
        self.providerOrder = Self.normalizedOrder(providerOrder)
        self.selectedProvider = selectedProvider
        self.showWeeklyIndicator = showWeeklyIndicator
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.customCodexPath = customCodexPath
        self.customAgyPath = customAgyPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOrder = try c.decodeIfPresent([ProviderID].self, forKey: .providerOrder) ?? ProviderID.allCases
        let normalized = Self.normalizedOrder(decodedOrder)
        self.providerOrder = normalized
        self.selectedProvider = try c.decodeIfPresent(ProviderID.self, forKey: .selectedProvider) ?? normalized[0]
        self.showWeeklyIndicator = try c.decodeIfPresent(Bool.self, forKey: .showWeeklyIndicator) ?? true
        self.refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 5
        self.customCodexPath = try c.decodeIfPresent(String.self, forKey: .customCodexPath) ?? ""
        self.customAgyPath = try c.decodeIfPresent(String.self, forKey: .customAgyPath) ?? ""
    }

    public static func normalizedOrder(_ raw: [ProviderID]) -> [ProviderID] {
        var result: [ProviderID] = []
        for item in raw where !result.contains(item) {
            result.append(item)
        }
        for fallback in ProviderID.allCases where !result.contains(fallback) {
            result.append(fallback)
        }
        return result
    }
}

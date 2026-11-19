import Foundation

/// Persists periodic quota probe samples and computes cycle-aware quota burn,
/// burn-rate / exhaustion fitting, and hybrid token-to-quota correlation.
public final class QuotaHistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let historyURL: URL
    private var samples: [QuotaProbeSample] = []

    /// Maximum age of probe history retained on disk (35 days).
    private static let retentionSeconds: TimeInterval = 35 * 24 * 3600

    /// Threshold beyond which a forward jump in `resetsAt` indicates a new reset cycle
    /// (large enough to ignore ±1–2m minute-rounding jitter from `agy /usage`).
    public static let resetShiftThresholdSeconds: TimeInterval = 10 * 60

    public init(historyURL: URL? = nil) {
        self.historyURL = historyURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("quota", isDirectory: true)
            .appendingPathComponent("probe-history.jsonl")
        self.samples = Self.loadSamples(from: self.historyURL)
    }

    /// Records all quota windows from a ready `ProviderSnapshot` as probe samples.
    public func record(snapshot: ProviderSnapshot, now: Date = Date()) {
        guard snapshot.status == .ready, !snapshot.windows.isEmpty else { return }
        let ts = snapshot.updatedAt ?? now

        var newSamples: [QuotaProbeSample] = []
        lock.lock()
        for w in snapshot.windows {
            let sample = QuotaProbeSample(
                timestamp: ts,
                provider: snapshot.provider,
                windowId: w.id,
                windowLabel: w.label,
                group: w.group,
                usedPercent: w.usedPercent,
                resetsAt: w.resetsAt,
                windowDurationMins: w.windowDurationMins
            )
            // Avoid duplicate samples for the same window within 10 seconds
            if let last = samples.last(where: { $0.seriesKey == sample.seriesKey }),
               abs(sample.timestamp.timeIntervalSince(last.timestamp)) < 10,
               last.usedPercent == sample.usedPercent {
                continue
            }
            samples.append(sample)
            newSamples.append(sample)
        }
        lock.unlock()

        if !newSamples.isEmpty {
            appendSamplesToDisk(newSamples)
        }
    }

    public func allSamples(since cutoffDate: Date) -> [QuotaProbeSample] {
        lock.lock()
        let filtered = samples.filter { $0.timestamp >= cutoffDate }
        lock.unlock()
        return filtered
    }

    // MARK: - Persistence

    private static func loadSamples(from url: URL) -> [QuotaProbeSample] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-retentionSeconds)

        var loaded: [QuotaProbeSample] = []
        var droppedOld = false

        for rawLine in content.split(whereSeparator: \.isNewline) {
            guard let data = String(rawLine).data(using: .utf8),
                  let sample = try? decoder.decode(QuotaProbeSample.self, from: data) else {
                continue
            }
            if sample.timestamp >= cutoff {
                loaded.append(sample)
            } else {
                droppedOld = true
            }
        }

        loaded.sort { $0.timestamp < $1.timestamp }

        // Compact file if old entries were pruned
        if droppedOld {
            rewriteSamples(loaded, to: url)
        }
        return loaded
    }

    private func appendSamplesToDisk(_ newSamples: [QuotaProbeSample]) {
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var lines = Data()
        for s in newSamples {
            if let data = try? encoder.encode(s) {
                lines.append(data)
                lines.append(0x0A) // '\n'
            }
        }
        guard !lines.isEmpty else { return }

        if FileManager.default.fileExists(atPath: historyURL.path),
           let handle = try? FileHandle(forWritingTo: historyURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lines)
        } else {
            try? lines.write(to: historyURL, options: .atomic)
        }
    }

    private static func rewriteSamples(_ items: [QuotaProbeSample], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for item in items {
            if let encoded = try? encoder.encode(item) {
                data.append(encoded)
                data.append(0x0A)
            }
        }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Cycle-Aware Analytics & Fitting Engine

public enum DashboardAnalyticsEngine {

    /// Segments raw probe samples into discrete reset cycles per `(provider, windowId)`.
    ///
    /// A new cycle begins whenever:
    /// 1. `curr.usedPercent < prev.usedPercent` (usage dropped after a reset), OR
    /// 2. `prev.resetsAt` exists and `curr.timestamp > prev.resetsAt + 60s` (reset elapsed while offline/sleeping), OR
    /// 3. Both `prev.resetsAt` and `curr.resetsAt` exist and `curr.resetsAt - prev.resetsAt > 10m`
    ///    (forward shift of reset boundary, ignoring ±1–2m minute-rounding jitter).
    public static func segmentCycles(from samples: [QuotaProbeSample]) -> [QuotaCycle] {
        let grouped = Dictionary(grouping: samples, by: \.seriesKey)
        var allCycles: [QuotaCycle] = []

        for key in grouped.keys.sorted() {
            let sorted = (grouped[key] ?? []).sorted { $0.timestamp < $1.timestamp }
            guard let first = sorted.first else { continue }

            var cycleIndex = 0
            var currentBatch: [QuotaProbeSample] = [first]

            for sample in sorted.dropFirst() {
                let prev = currentBatch[currentBatch.count - 1]
                if shouldStartNewCycle(previous: prev, current: sample) {
                    allCycles.append(
                        QuotaCycle(
                            provider: first.provider,
                            windowId: first.windowId,
                            windowLabel: prev.windowLabel,
                            group: prev.group,
                            cycleIndex: cycleIndex,
                            samples: currentBatch
                        )
                    )
                    cycleIndex += 1
                    currentBatch = [sample]
                } else {
                    currentBatch.append(sample)
                }
            }

            if let last = currentBatch.last {
                allCycles.append(
                    QuotaCycle(
                        provider: first.provider,
                        windowId: first.windowId,
                        windowLabel: last.windowLabel,
                        group: last.group,
                        cycleIndex: cycleIndex,
                        samples: currentBatch
                    )
                )
            }
        }

        return allCycles
    }

    public static func shouldStartNewCycle(previous prev: QuotaProbeSample, current curr: QuotaProbeSample) -> Bool {
        // 1. Usage dropped -> definitely crossed a reset
        if curr.usedPercent < prev.usedPercent {
            return true
        }
        // 2. Previous reset timestamp has already passed (e.g., Mac slept across reset)
        if let prevReset = prev.resetsAt, curr.timestamp.timeIntervalSince(prevReset) > 60 {
            return true
        }
        // 3. Reset boundary jumped forward beyond rounding jitter
        if let prevReset = prev.resetsAt, let currReset = curr.resetsAt {
            if currReset.timeIntervalSince(prevReset) > QuotaHistoryStore.resetShiftThresholdSeconds {
                return true
            }
        }
        return false
    }

    /// Computes incremental `ΔusedPercent` intervals across segmented cycles without reset corruption.
    public static func computeDeltaEvents(from cycles: [QuotaCycle]) -> [QuotaDeltaEvent] {
        let bySeries = Dictionary(grouping: cycles) { "\($0.provider.rawValue)::\($0.windowId)" }
        var deltas: [QuotaDeltaEvent] = []

        for key in bySeries.keys.sorted() {
            let seriesCycles = (bySeries[key] ?? []).sorted { $0.cycleIndex < $1.cycleIndex }
            var previousCycleEnd: Date?

            for (idx, cycle) in seriesCycles.enumerated() {
                let pts = cycle.samples
                guard let first = pts.first else { continue }

                // If a new cycle started after a prior cycle and already has non-zero usage,
                // attribute `first.usedPercent` to the post-reset interval.
                if idx > 0, first.usedPercent > 0, let prevEnd = previousCycleEnd {
                    let prevReset = seriesCycles[idx - 1].latestResetsAt
                    let intervalStart = (prevReset != nil && prevReset! < first.timestamp) ? prevReset! : prevEnd
                    deltas.append(
                        QuotaDeltaEvent(
                            startTime: intervalStart,
                            endTime: first.timestamp,
                            provider: cycle.provider,
                            windowId: cycle.windowId,
                            windowLabel: cycle.windowLabel,
                            group: cycle.group,
                            deltaPercent: first.usedPercent,
                            crossedResetBoundary: true
                        )
                    )
                }

                // Intra-cycle monotonic increments
                for i in 1..<pts.count {
                    let prev = pts[i - 1]
                    let curr = pts[i]
                    let diff = max(0, curr.usedPercent - prev.usedPercent)
                    if diff > 0 {
                        deltas.append(
                            QuotaDeltaEvent(
                                startTime: prev.timestamp,
                                endTime: curr.timestamp,
                                provider: cycle.provider,
                                windowId: cycle.windowId,
                                windowLabel: cycle.windowLabel,
                                group: cycle.group,
                                deltaPercent: diff,
                                crossedResetBoundary: false
                            )
                        )
                    }
                }

                previousCycleEnd = pts.last?.timestamp
            }
        }

        return deltas.sorted { $0.endTime < $1.endTime }
    }

    /// Fits burn rate (`%/hour`) and projected exhaustion strictly within the **latest active cycle**
    /// for each `(provider, windowId)` series using recency-weighted linear regression.
    public static func fitBurnRates(from cycles: [QuotaCycle], now: Date = Date()) -> [BurnRateEstimate] {
        let bySeries = Dictionary(grouping: cycles) { "\($0.provider.rawValue)::\($0.windowId)" }
        var estimates: [BurnRateEstimate] = []

        for key in bySeries.keys.sorted() {
            let seriesCycles = (bySeries[key] ?? []).sorted { $0.cycleIndex < $1.cycleIndex }
            guard let activeCycle = seriesCycles.last,
                  let latest = activeCycle.samples.last else {
                continue
            }

            let slope = weightedLinearSlopePercentPerHour(samples: activeCycle.samples)
            let remaining = Double(max(0, 100 - latest.usedPercent))

            let projectedDate: Date?
            if latest.usedPercent >= 100 {
                projectedDate = latest.timestamp
            } else if slope > 0.05 {
                let hoursToFull = remaining / slope
                if hoursToFull <= 24 * 30 {
                    projectedDate = latest.timestamp.addingTimeInterval(hoursToFull * 3600)
                } else {
                    projectedDate = nil
                }
            } else {
                projectedDate = nil
            }

            let willExhaust: Bool
            if let projectedDate, let resetsAt = latest.resetsAt {
                willExhaust = projectedDate < resetsAt && resetsAt > now
            } else {
                willExhaust = false
            }

            estimates.append(
                BurnRateEstimate(
                    provider: activeCycle.provider,
                    windowId: activeCycle.windowId,
                    windowLabel: latest.windowLabel,
                    group: latest.group,
                    currentUsedPercent: latest.usedPercent,
                    resetsAt: latest.resetsAt,
                    burnRatePercentPerHour: max(0, slope),
                    projectedExhaustionDate: projectedDate,
                    willExhaustBeforeReset: willExhaust,
                    activeCycleSampleCount: activeCycle.samples.count,
                    cycleCountInRange: seriesCycles.count
                )
            )
        }

        return estimates
    }

    /// Recency-weighted ordinary least squares slope (`% / hour`) within a single cycle.
    /// Exponentially weights recent samples higher (half-life = 2 hours) so recent pace changes dominate.
    public static func weightedLinearSlopePercentPerHour(samples: [QuotaProbeSample]) -> Double {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else {
            return 0
        }

        let spanSeconds = last.timestamp.timeIntervalSince(first.timestamp)
        guard spanSeconds >= 60 else { return 0 } // Need at least 1 minute of span

        if samples.count == 2 {
            let dPct = Double(last.usedPercent - first.usedPercent)
            let dHours = spanSeconds / 3600.0
            return max(0, dPct / dHours)
        }

        let t0 = first.timestamp.timeIntervalSince1970
        let tLast = last.timestamp.timeIntervalSince1970
        let halfLifeHours = 2.0
        let lambda = log(2.0) / halfLifeHours

        var sumW = 0.0
        var sumWX = 0.0
        var sumWY = 0.0

        for s in samples {
            let x = (s.timestamp.timeIntervalSince1970 - t0) / 3600.0
            let y = Double(s.usedPercent)
            let ageHours = max(0, (tLast - s.timestamp.timeIntervalSince1970) / 3600.0)
            let w = exp(-lambda * ageHours)
            sumW += w
            sumWX += w * x
            sumWY += w * y
        }

        guard sumW > 0 else { return 0 }
        let meanX = sumWX / sumW
        let meanY = sumWY / sumW

        var num = 0.0
        var den = 0.0
        for s in samples {
            let x = (s.timestamp.timeIntervalSince1970 - t0) / 3600.0
            let y = Double(s.usedPercent)
            let ageHours = max(0, (tLast - s.timestamp.timeIntervalSince1970) / 3600.0)
            let w = exp(-lambda * ageHours)
            let dx = x - meanX
            num += w * dx * (y - meanY)
            den += w * dx * dx
        }

        guard den > 1e-9 else { return 0 }
        return max(0, num / den)
    }

    /// Hybrid correlation: matches non-zero probed `ΔusedPercent` intervals against exact local
    /// `TokenUsageEvent`s in the same time window to estimate `~tokens per 1% quota`.
    public static func estimateTokensPerPercent(
        deltas: [QuotaDeltaEvent],
        tokenEvents: [TokenUsageEvent]
    ) -> [TokensPerPercentEstimate] {
        // Filter to clean intra-cycle intervals (<= 6h) with positive delta
        let validDeltas = deltas.filter {
            !$0.crossedResetBoundary &&
            $0.deltaPercent >= 1 &&
            $0.endTime.timeIntervalSince($0.startTime) > 0 &&
            $0.endTime.timeIntervalSince($0.startTime) <= 6 * 3600
        }

        let tokensByProvider = Dictionary(grouping: tokenEvents, by: \.provider)
        let deltasBySeries = Dictionary(grouping: validDeltas) { "\($0.provider.rawValue)::\($0.windowId)" }

        var results: [TokensPerPercentEstimate] = []
        for key in deltasBySeries.keys.sorted() {
            guard let seriesDeltas = deltasBySeries[key], let sample = seriesDeltas.first else { continue }
            let providerTokens = tokensByProvider[sample.provider] ?? []
            guard !providerTokens.isEmpty else { continue }

            var matchedTokens: Int64 = 0
            var matchedDeltaPct = 0
            var matchedCount = 0

            for d in seriesDeltas {
                var intervalTokens: Int64 = 0
                for tok in providerTokens where tok.timestamp > d.startTime && tok.timestamp <= d.endTime {
                    intervalTokens += tok.totalTokens
                }
                // Only count intervals where local activity actually occurred
                if intervalTokens > 0 {
                    matchedTokens += intervalTokens
                    matchedDeltaPct += d.deltaPercent
                    matchedCount += 1
                }
            }

            if matchedDeltaPct >= 1, matchedTokens > 0 {
                results.append(
                    TokensPerPercentEstimate(
                        provider: sample.provider,
                        windowId: sample.windowId,
                        windowLabel: sample.windowLabel,
                        group: sample.group,
                        estimatedTokensPerPercent: Double(matchedTokens) / Double(matchedDeltaPct),
                        matchedIntervals: matchedCount,
                        totalDeltaPercent: matchedDeltaPct,
                        totalMatchedTokens: matchedTokens
                    )
                )
            }
        }

        return results
    }

    /// Builds a complete `DashboardAnalytics` view model from raw token events & probe samples.
    public static func buildAnalytics(
        tokenEvents: [TokenUsageEvent],
        probeSamples: [QuotaProbeSample],
        timeRange: DashboardTimeRange,
        providerFilter: ProviderFilter,
        modelFilter: String? = nil,
        now: Date = Date()
    ) -> DashboardAnalytics {
        let cutoff = now.addingTimeInterval(-timeRange.durationSeconds)

        let providerTokens = tokenEvents.filter {
            $0.timestamp >= cutoff && providerFilter.matches($0.provider)
        }
        let filteredProbes = probeSamples.filter {
            $0.timestamp >= cutoff && providerFilter.matches($0.provider)
        }

        // 1. Model breakdown across ALL models of this provider (so model filter stays populated)
        struct ModelAcc {
            let provider: ProviderID
            let model: String
            var uncached: Int64 = 0
            var cached: Int64 = 0
            var output: Int64 = 0
            var reasoning: Int64 = 0
            var turns: Int = 0
        }
        var modelMap: [String: ModelAcc] = [:]

        for ev in providerTokens {
            let key = "\(ev.provider.rawValue)::\(ev.model)"
            var acc = modelMap[key] ?? ModelAcc(provider: ev.provider, model: ev.model)
            acc.uncached += ev.uncachedInputTokens
            acc.cached += ev.cachedInputTokens
            acc.output += ev.outputTokens
            acc.reasoning += ev.reasoningTokens
            acc.turns += 1
            modelMap[key] = acc
        }

        let modelSummaries = modelMap.values
            .map {
                ModelTokenSummary(
                    provider: $0.provider,
                    model: $0.model,
                    uncachedInputTokens: $0.uncached,
                    cachedInputTokens: $0.cached,
                    outputTokens: $0.output,
                    reasoningTokens: $0.reasoning,
                    turnCount: $0.turns
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }

        let availableModels = modelSummaries.map(\.model)
        let activeModelFilter: String? = {
            guard let m = modelFilter, availableModels.contains(m) else { return nil }
            return m
        }()

        let filteredTokens: [TokenUsageEvent]
        if let activeModelFilter {
            filteredTokens = providerTokens.filter { $0.model == activeModelFilter }
        } else {
            filteredTokens = providerTokens
        }

        var totalUncached: Int64 = 0
        var totalCached: Int64 = 0
        var totalOutput: Int64 = 0
        var totalReasoning: Int64 = 0
        for ev in filteredTokens {
            totalUncached += ev.uncachedInputTokens
            totalCached += ev.cachedInputTokens
            totalOutput += ev.outputTokens
            totalReasoning += ev.reasoningTokens
        }

        // 2. Time buckets (hourly for Day, daily for Week/Month)
        let buckets = bucketizeTokens(events: filteredTokens, timeRange: timeRange, now: now)

        // 3. Cycle-segmented probe history, deltas, burn rates, and hybrid correlation
        let cycles = segmentCycles(from: filteredProbes)
        let deltas = computeDeltaEvents(from: cycles)
        let burnRates = fitBurnRates(from: cycles, now: now)
        let totalBurnedDelta = deltas.reduce(0) { $0 + $1.deltaPercent }
        let tokensPerPct = estimateTokensPerPercent(deltas: deltas, tokenEvents: providerTokens)

        return DashboardAnalytics(
            generatedAt: now,
            timeRange: timeRange,
            providerFilter: providerFilter,
            selectedModel: activeModelFilter,
            availableModels: availableModels,
            totalUncachedInputTokens: totalUncached,
            totalCachedInputTokens: totalCached,
            totalOutputTokens: totalOutput,
            totalReasoningTokens: totalReasoning,
            totalTurns: filteredTokens.count,
            tokenBuckets: buckets,
            modelSummaries: modelSummaries,
            probeCycles: cycles,
            burnRates: burnRates,
            totalBurnedDeltaPercent: totalBurnedDelta,
            tokensPerPercentEstimates: tokensPerPct
        )
    }

    private static func bucketizeTokens(
        events: [TokenUsageEvent],
        timeRange: DashboardTimeRange,
        now: Date
    ) -> [TokenBucket] {
        let cal = Calendar.current
        let bucketStarts: [Date]

        switch timeRange {
        case .day24h:
            let currentHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
            bucketStarts = (0..<24).reversed().compactMap {
                cal.date(byAdding: .hour, value: -$0, to: currentHour)
            }
        case .days7:
            let today = cal.startOfDay(for: now)
            bucketStarts = (0..<7).reversed().compactMap {
                cal.date(byAdding: .day, value: -$0, to: today)
            }
        case .days30:
            let today = cal.startOfDay(for: now)
            bucketStarts = (0..<30).reversed().compactMap {
                cal.date(byAdding: .day, value: -$0, to: today)
            }
        }

        struct BucketAcc {
            var uncached: Int64 = 0
            var cached: Int64 = 0
            var output: Int64 = 0
            var reasoning: Int64 = 0
        }
        var accByStart: [Date: BucketAcc] = [:]
        for start in bucketStarts {
            accByStart[start] = BucketAcc()
        }

        for ev in events {
            let start: Date
            switch timeRange {
            case .day24h:
                start = cal.dateInterval(of: .hour, for: ev.timestamp)?.start ?? ev.timestamp
            case .days7, .days30:
                start = cal.startOfDay(for: ev.timestamp)
            }
            if var acc = accByStart[start] {
                acc.uncached += ev.uncachedInputTokens
                acc.cached += ev.cachedInputTokens
                acc.output += ev.outputTokens
                acc.reasoning += ev.reasoningTokens
                accByStart[start] = acc
            }
        }

        return bucketStarts.map { start in
            let acc = accByStart[start] ?? BucketAcc()
            return TokenBucket(
                date: start,
                uncachedInputTokens: acc.uncached,
                cachedInputTokens: acc.cached,
                outputTokens: acc.output,
                reasoningTokens: acc.reasoning
            )
        }
    }
}

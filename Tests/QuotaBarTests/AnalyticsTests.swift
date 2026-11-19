import Foundation
import QuotaBarCore
import Testing

@Suite("Dashboard Analytics & Token Scanner Tests")
struct AnalyticsTests {

    // MARK: - Option 1: Exact Local Token Log Parsers

    @Test("Codex session parser deduplicates cumulative snapshots and separates cached input")
    func codexSessionParserDeduplicatesAndSeparatesCachedInput() {
        let jsonl = """
        {"timestamp":"2026-11-19T07:23:40.000Z","type":"turn_context","payload":{"model":"gpt-6.2-sol","cwd":"/tmp"}}
        {"timestamp":"2026-11-19T07:23:47.943Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18124,"cached_input_tokens":12160,"output_tokens":163,"reasoning_output_tokens":20,"total_tokens":18287},"last_token_usage":{"input_tokens":18124,"cached_input_tokens":12160,"output_tokens":163,"reasoning_output_tokens":20,"total_tokens":18287}}}}
        {"timestamp":"2026-11-19T07:23:48.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18124,"cached_input_tokens":12160,"output_tokens":163,"reasoning_output_tokens":20,"total_tokens":18287},"last_token_usage":{"input_tokens":18124,"cached_input_tokens":12160,"output_tokens":163,"reasoning_output_tokens":20,"total_tokens":18287}}}}
        {"timestamp":"2026-11-19T07:23:56.260Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36746,"cached_input_tokens":30208,"output_tokens":405,"reasoning_output_tokens":50,"total_tokens":37151},"last_token_usage":{"input_tokens":18622,"cached_input_tokens":18048,"output_tokens":242,"reasoning_output_tokens":30,"total_tokens":18864}}}}
        """

        let events = TokenLogScanner.parseCodexSessionContent(jsonl)
        #expect(events.count == 2)

        #expect(events[0].provider == .codex)
        #expect(events[0].model == "gpt-6.2-sol")
        #expect(events[0].uncachedInputTokens == 18124 - 12160)
        #expect(events[0].cachedInputTokens == 12160)
        #expect(events[0].outputTokens == 163)
        #expect(events[0].reasoningTokens == 20)
        #expect(events[0].totalTokens == 18287)

        #expect(events[1].uncachedInputTokens == 18622 - 18048)
        #expect(events[1].cachedInputTokens == 18048)
        #expect(events[1].outputTokens == 242)
        #expect(events[1].totalTokens == 18864)
    }

    @Test("Antigravity transcript parser extracts fresh input, cache read, and output tokens")
    func antigravityTranscriptParserExtractsFreshAndCachedTokens() {
        let jsonl = """
        {"created_at":"2026-11-19T03:11:08Z","type":"PLANNER_RESPONSE","model":"gemini-4-neon-medium","input_tokens":13502,"cache_read_tokens":0,"output_tokens":308}
        {"created_at":"2026-11-19T03:11:16Z","type":"PLANNER_RESPONSE","input_tokens":2133,"cache_read_tokens":13341,"output_tokens":273}
        {"created_at":"2026-11-19T03:11:20Z","type":"USER_INPUT","content":"hello"}
        """

        let events = TokenLogScanner.parseAntigravityTranscriptContent(jsonl)
        #expect(events.count == 2)

        #expect(events[0].provider == .antigravity)
        #expect(events[0].model == "gemini-4-neon-medium")
        #expect(events[0].uncachedInputTokens == 13502)
        #expect(events[0].cachedInputTokens == 0)
        #expect(events[0].outputTokens == 308)
        #expect(events[0].totalTokens == 13810)

        #expect(events[1].model == "gemini-4-neon-medium")
        #expect(events[1].uncachedInputTokens == 2133)
        #expect(events[1].cachedInputTokens == 13341)
        #expect(events[1].outputTokens == 273)
        #expect(events[1].totalTokens == 15747)
    }

    // MARK: - Option 2: Cycle Segmentation, Delta Aggregation & Burn-Rate Fitting

    @Test("Cycle segmentation absorbs ±2m countdown jitter and splits on reset drops")
    func cycleSegmentationHandlesJitterAndResets() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let reset1 = t0.addingTimeInterval(5 * 3600)
        let reset2 = t0.addingTimeInterval(10 * 3600)

        let samples: [QuotaProbeSample] = [
            // Cycle 0: monotonic rise with ±2m agy countdown jitter (stays in Cycle 0)
            QuotaProbeSample(timestamp: t0, provider: .antigravity, windowId: "5h", windowLabel: "5h limit", usedPercent: 10, resetsAt: reset1),
            QuotaProbeSample(timestamp: t0.addingTimeInterval(1800), provider: .antigravity, windowId: "5h", windowLabel: "5h limit", usedPercent: 25, resetsAt: reset1.addingTimeInterval(90)),
            QuotaProbeSample(timestamp: t0.addingTimeInterval(3600), provider: .antigravity, windowId: "5h", windowLabel: "5h limit", usedPercent: 40, resetsAt: reset1.addingTimeInterval(-60)),

            // Cycle 1: crossed reset1 and dropped to 15% with new reset2
            QuotaProbeSample(timestamp: reset1.addingTimeInterval(1200), provider: .antigravity, windowId: "5h", windowLabel: "5h limit", usedPercent: 15, resetsAt: reset2),
            QuotaProbeSample(timestamp: reset1.addingTimeInterval(3000), provider: .antigravity, windowId: "5h", windowLabel: "5h limit", usedPercent: 35, resetsAt: reset2)
        ]

        let cycles = DashboardAnalyticsEngine.segmentCycles(from: samples)
        #expect(cycles.count == 2)
        #expect(cycles[0].samples.count == 3)
        #expect(cycles[1].samples.count == 2)

        // Incremental deltas: (25-10) + (40-25) + 15 (post-reset) + (35-15) = 65%
        let deltas = DashboardAnalyticsEngine.computeDeltaEvents(from: cycles)
        let totalBurned = deltas.reduce(0) { $0 + $1.deltaPercent }
        #expect(totalBurned == 65)
    }

    @Test("Cycle segmentation splits when resetsAt shifts forward even without a percent drop")
    func cycleSegmentationSplitsWhenResetsAtJumpsForwardWithoutPercentDrop() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let reset1 = t0.addingTimeInterval(5 * 3600)
        let reset2 = t0.addingTimeInterval(10 * 3600)

        let samples: [QuotaProbeSample] = [
            QuotaProbeSample(timestamp: t0, provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 20, resetsAt: reset1),
            QuotaProbeSample(timestamp: t0.addingTimeInterval(6 * 3600), provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 25, resetsAt: reset2)
        ]

        let cycles = DashboardAnalyticsEngine.segmentCycles(from: samples)
        #expect(cycles.count == 2)
    }

    @Test("Burn rate regression fits strictly inside the active cycle")
    func burnRateFitsStrictlyWithinActiveCycle() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let reset1 = t0.addingTimeInterval(5 * 3600)
        let reset2 = t0.addingTimeInterval(10 * 3600)

        let samples: [QuotaProbeSample] = [
            // Old slow cycle (5%/hr)
            QuotaProbeSample(timestamp: t0, provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 10, resetsAt: reset1),
            QuotaProbeSample(timestamp: t0.addingTimeInterval(2 * 3600), provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 20, resetsAt: reset1),

            // Active fast cycle (30%/hr: 10% -> 40% -> 70% over 2 hours)
            QuotaProbeSample(timestamp: reset1.addingTimeInterval(600), provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 10, resetsAt: reset2),
            QuotaProbeSample(timestamp: reset1.addingTimeInterval(600 + 3600), provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 40, resetsAt: reset2),
            QuotaProbeSample(timestamp: reset1.addingTimeInterval(600 + 7200), provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 70, resetsAt: reset2)
        ]

        let cycles = DashboardAnalyticsEngine.segmentCycles(from: samples)
        let rates = DashboardAnalyticsEngine.fitBurnRates(from: cycles, now: reset1.addingTimeInterval(600 + 7200))
        #expect(rates.count == 1)
        let est = rates[0]
        #expect(abs(est.burnRatePercentPerHour - 30.0) < 0.5)
        #expect(est.willExhaustBeforeReset == true)
        #expect(est.cycleCountInRange == 2)
        #expect(est.activeCycleSampleCount == 3)
    }

    @Test("Hybrid correlation estimates tokens per 1% quota from matched intervals")
    func hybridTokensPerPercentCorrelation() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let reset = t0.addingTimeInterval(5 * 3600)

        let probes: [QuotaProbeSample] = [
            QuotaProbeSample(timestamp: t0, provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 10, resetsAt: reset),
            QuotaProbeSample(timestamp: t0.addingTimeInterval(600), provider: .codex, windowId: "primary", windowLabel: "5-Hour Window", usedPercent: 15, resetsAt: reset)
        ]

        let tokens: [TokenUsageEvent] = [
            TokenUsageEvent(
                timestamp: t0.addingTimeInterval(300),
                provider: .codex,
                model: "gpt-6.2-sol",
                uncachedInputTokens: 100_000,
                cachedInputTokens: 350_000,
                outputTokens: 50_000
            )
        ]

        let cycles = DashboardAnalyticsEngine.segmentCycles(from: probes)
        let deltas = DashboardAnalyticsEngine.computeDeltaEvents(from: cycles)
        let corr = DashboardAnalyticsEngine.estimateTokensPerPercent(deltas: deltas, tokenEvents: tokens)

        #expect(corr.count == 1)
        #expect(abs(corr[0].estimatedTokensPerPercent - 100_000) < 1.0)
        #expect(corr[0].totalDeltaPercent == 5)
        #expect(corr[0].totalMatchedTokens == 500_000)
    }

    @Test("Model filter scopes token totals and buckets while preserving availableModels")
    func modelFilterScopesTokensAndPreservesModelList() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let events: [TokenUsageEvent] = [
            TokenUsageEvent(timestamp: now.addingTimeInterval(-600), provider: .antigravity, model: "gemini-4-neon-medium", uncachedInputTokens: 1000, cachedInputTokens: 2000, outputTokens: 500),
            TokenUsageEvent(timestamp: now.addingTimeInterval(-300), provider: .antigravity, model: "gemini-4-carbon-medium", uncachedInputTokens: 5000, cachedInputTokens: 5000, outputTokens: 1000)
        ]

        let filtered = DashboardAnalyticsEngine.buildAnalytics(
            tokenEvents: events,
            probeSamples: [],
            timeRange: .day24h,
            providerFilter: .antigravity,
            modelFilter: "gemini-4-neon-medium",
            now: now
        )

        #expect(filtered.selectedModel == "gemini-4-neon-medium")
        #expect(filtered.availableModels.count == 2)
        #expect(filtered.totalTokens == 3500)
        #expect(filtered.totalTurns == 1)
    }
}

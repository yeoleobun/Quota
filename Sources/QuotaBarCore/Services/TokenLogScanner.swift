import Foundation

/// Scans local OpenAI Codex and Google Antigravity session logs to extract exact per-turn token usage.
/// Uses an in-memory `(mtime, size)` cache so repeated dashboard refreshes only re-parse modified files.
public final class TokenLogScanner: @unchecked Sendable {
    private struct CachedFile {
        let mtime: Date
        let size: UInt64
        let events: [TokenUsageEvent]
    }

    private let lock = NSLock()
    private var fileCache: [String: CachedFile] = [:]

    private let codexSessionsRoot: URL
    private let antigravityBrainRoot: URL

    public init(
        codexSessionsRoot: URL? = nil,
        antigravityBrainRoot: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.codexSessionsRoot = codexSessionsRoot ?? home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.antigravityBrainRoot = antigravityBrainRoot ?? home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
    }

    /// Scans Codex and Antigravity local logs modified within `lookbackDays` and returns all token events sorted by timestamp.
    public func scanEvents(since cutoffDate: Date) -> [TokenUsageEvent] {
        var allEvents: [TokenUsageEvent] = []
        allEvents.append(contentsOf: scanCodexSessions(since: cutoffDate))
        allEvents.append(contentsOf: scanAntigravityTranscripts(since: cutoffDate))
        allEvents.sort { $0.timestamp < $1.timestamp }
        return allEvents.filter { $0.timestamp >= cutoffDate }
    }

    // MARK: - Codex Scanner (~/.codex/sessions/**/*.jsonl)

    private func scanCodexSessions(since cutoffDate: Date) -> [TokenUsageEvent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexSessionsRoot.path) else { return [] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: codexSessionsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [TokenUsageEvent] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else {
                continue
            }
            // Skip files whose last modification is older than our cutoff window
            if mtime < cutoffDate { continue }
            let size = UInt64(values.fileSize ?? 0)
            let events = loadOrParse(url: url, mtime: mtime, size: size) { content in
                Self.parseCodexSessionContent(content)
            }
            results.append(contentsOf: events)
        }
        return results
    }

    // MARK: - Antigravity Scanner (~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl)

    private func scanAntigravityTranscripts(since cutoffDate: Date) -> [TokenUsageEvent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: antigravityBrainRoot.path) else { return [] }
        guard let convDirs = try? fm.contentsOfDirectory(
            at: antigravityBrainRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var results: [TokenUsageEvent] = []

        for convDir in convDirs {
            let transcriptURL = convDir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl")

            guard let values = try? transcriptURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else {
                continue
            }
            if mtime < cutoffDate { continue }
            let size = UInt64(values.fileSize ?? 0)
            let events = loadOrParse(url: transcriptURL, mtime: mtime, size: size) { content in
                Self.parseAntigravityTranscriptContent(content)
            }
            results.append(contentsOf: events)
        }
        return results
    }

    private func loadOrParse(
        url: URL,
        mtime: Date,
        size: UInt64,
        parser: (String) -> [TokenUsageEvent]
    ) -> [TokenUsageEvent] {
        let key = url.path
        lock.lock()
        if let cached = fileCache[key], cached.mtime == mtime, cached.size == size {
            let events = cached.events
            lock.unlock()
            return events
        }
        lock.unlock()

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let parsed = parser(content)

        lock.lock()
        fileCache[key] = CachedFile(mtime: mtime, size: size, events: parsed)
        lock.unlock()
        return parsed
    }

    // MARK: - Pure Parsers (Unit-Testable)

    /// Parses a Codex `rollout-*.jsonl` file content into deduplicated per-turn `TokenUsageEvent`s.
    ///
    /// Notes on Codex schema:
    /// - `turn_context` carries `payload.model`
    /// - `event_msg` with `payload.type == "token_count"` carries `payload.info.total_token_usage` and `last_token_usage`.
    /// - `input_tokens` INCLUDES `cached_input_tokens`; `output_tokens` INCLUDES `reasoning_output_tokens`.
    /// - Consecutive `token_count` events can occasionally repeat the same cumulative `total_token_usage.total_tokens`,
    ///   so we only emit an event when cumulative total strictly increases.
    public static func parseCodexSessionContent(_ content: String) -> [TokenUsageEvent] {
        var events: [TokenUsageEvent] = []
        var currentModel = "Codex"
        var prevCumulativeTotal: Int64 = 0

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            // Fast substring pre-filter before JSON parsing
            let lineStr = String(rawLine)
            let isTurnContext = lineStr.contains("\"turn_context\"")
            let isTokenCount = lineStr.contains("\"token_count\"")
            guard isTurnContext || isTokenCount else { continue }

            guard let data = lineStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                continue
            }

            if type == "turn_context",
               let payload = obj["payload"] as? [String: Any],
               let model = payload["model"] as? String,
               !model.isEmpty {
                currentModel = model
                continue
            }

            guard type == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let timestamp = parseISO8601(tsStr, frac: isoFrac, plain: isoPlain) else {
                continue
            }

            let totalUsage = info["total_token_usage"] as? [String: Any]
            let lastUsage = info["last_token_usage"] as? [String: Any]
            let cumulativeTotal = int64Value(totalUsage?["total_tokens"])

            // Deduplicate repeated snapshots with identical cumulative totals
            if cumulativeTotal > 0 {
                if cumulativeTotal <= prevCumulativeTotal {
                    continue
                }
                prevCumulativeTotal = cumulativeTotal
            }

            guard let usage = lastUsage ?? totalUsage else { continue }
            let rawInput = int64Value(usage["input_tokens"])
            let cached = int64Value(usage["cached_input_tokens"])
            let output = int64Value(usage["output_tokens"])
            let reasoning = int64Value(usage["reasoning_output_tokens"])

            let uncachedInput = max(0, rawInput - cached)
            guard uncachedInput > 0 || cached > 0 || output > 0 else { continue }

            events.append(
                TokenUsageEvent(
                    timestamp: timestamp,
                    provider: .codex,
                    model: currentModel,
                    uncachedInputTokens: uncachedInput,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    reasoningTokens: reasoning
                )
            )
        }

        return events
    }

    /// Parses an Antigravity `transcript.jsonl` file content into per-step `TokenUsageEvent`s.
    ///
    /// Notes on Antigravity schema:
    /// - Each JSONL step may include `created_at`, `model`, `input_tokens`, `cache_read_tokens`, `output_tokens`.
    /// - `input_tokens` is non-cached (fresh) input tokens; `cache_read_tokens` is tracked separately.
    public static func parseAntigravityTranscriptContent(_ content: String) -> [TokenUsageEvent] {
        var events: [TokenUsageEvent] = []
        var lastKnownModel = "Antigravity"

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let lineStr = String(rawLine)
            // Fast pre-filter: only lines containing token fields or model
            guard lineStr.contains("\"input_tokens\"") || lineStr.contains("\"output_tokens\"") || lineStr.contains("\"model\"") else {
                continue
            }

            guard let data = lineStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let model = obj["model"] as? String, !model.isEmpty {
                lastKnownModel = model
            }

            let uncachedInput = int64Value(obj["input_tokens"])
            let cached = int64Value(obj["cache_read_tokens"])
            let output = int64Value(obj["output_tokens"])

            guard uncachedInput > 0 || cached > 0 || output > 0 else { continue }
            guard let tsStr = obj["created_at"] as? String,
                  let timestamp = parseISO8601(tsStr, frac: isoFrac, plain: isoPlain) else {
                continue
            }

            let stepModel = (obj["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lastKnownModel

            events.append(
                TokenUsageEvent(
                    timestamp: timestamp,
                    provider: .antigravity,
                    model: stepModel,
                    uncachedInputTokens: uncachedInput,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    reasoningTokens: 0
                )
            )
        }

        return events
    }

    private static func parseISO8601(_ str: String, frac: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> Date? {
        if let d = frac.date(from: str) { return d }
        return plain.date(from: str)
    }

    private static func int64Value(_ raw: Any?) -> Int64 {
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        return 0
    }
}

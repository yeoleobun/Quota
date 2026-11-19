import Darwin
import Foundation

public enum AntigravityProvider {
    public static func fetchSnapshot(customPath: String = "", now: Date = Date()) async -> ProviderSnapshot {
        guard let binary = BinaryLocator.findAgy(customPath: customPath) else {
            return ProviderSnapshot(
                provider: .antigravity,
                status: .cliMissing(
                    installHint: "Antigravity CLI (agy) is not installed yet."
                ),
                updatedAt: now
            )
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let snap = queryAgyUsageViaPTY(binaryPath: binary, now: now)
                continuation.resume(returning: snap)
            }
        }
    }

    // MARK: - ANSI & `/usage` Output Parser

    /// Strips all CSI (including `<`, `>`, `?` private modes), OSC, charset sequences, and backspaces.
    public static func stripANSI(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        let esc = "\u{001B}"
        let bel = "\u{0007}"
        let patterns = [
            // CSI sequences including kitty keyboard protocol like \x1b[>4;2m and \x1b[<1u
            "\(esc)\\[[0-9;<=>?]*[ -/]*[@-~]",
            // OSC sequences terminated by BEL or ST
            "\(esc)\\][^\(bel)\(esc)]*(\(bel)|\(esc)\\\\)",
            // Charset / single-char escapes
            "\(esc)[()][AB012]",
            "\(esc)[>=]"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }

        // Remove backspace characters and remaining non-printable control chars (except \n, \t)
        var cleanedScalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\u{0008}" {
                if !cleanedScalars.isEmpty && cleanedScalars.last != "\n" {
                    cleanedScalars.removeLast()
                }
            } else if scalar == "\n" || scalar == "\t" || scalar.value >= 0x20 {
                cleanedScalars.append(scalar)
            }
        }
        return String(cleanedScalars)
    }

    /// Parses output from `agy` `/usage` into `ProviderSnapshot`.
    ///
    /// Expected `agy /usage` structure per group:
    /// ```
    /// GEMINI MODELS
    /// Models within this group: Gemini Flash, Gemini Pro
    /// Weekly Limit Remaining
    /// [█████████████████████████████████████████████████░] 98.80%
    /// Refreshes in 167h 9m
    /// Five Hour Limit Remaining
    /// [████████████████████████████████████████████████░░] 95.18%
    /// Refreshes in 4h 9m
    /// ```
    public static func parseUsageOutput(
        _ rawOutput: String,
        binaryPath: String? = nil,
        now: Date = Date()
    ) -> ProviderSnapshot {
        let cleaned = stripANSI(rawOutput)
        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        var accountEmail: String?
        var planLabel: String?
        var currentGroup: String?
        var pendingLimitLabel: String?
        var pendingIsRemaining = true
        var pendingWindowMins: Int?
        var windows: [QuotaWindow] = []

        for idx in lines.indices {
            let line = lines[idx]
            let lower = line.lowercased()

            // Extract account email: "Account: user@example.com"
            if lower.hasPrefix("account:") {
                let email = line.dropFirst("account:".count).trimmingCharacters(in: .whitespaces)
                if email.contains("@") {
                    accountEmail = email
                }
                continue
            }

            // Extract subscription tier badge: e.g. "auto · (Google AI Ultra)" or "(Google AI Pro)"
            if let tier = extractPlanTier(from: line) {
                planLabel = tier
            }

            // Detect model group header: e.g. "GEMINI MODELS", "CLAUDE AND GPT MODELS"
            if let groupName = parseModelGroupHeader(line) {
                currentGroup = groupName
                pendingLimitLabel = nil
                continue
            }

            // Detect window title line: e.g. "Weekly Limit Remaining", "Five Hour Limit Remaining"
            if let windowSpec = parseWindowTitleLine(line) {
                // Check if percentage is on the SAME line (e.g. "Gemini Pro 65% remaining · Resets in 4h 30m")
                if let pct = extractPercentageValue(from: line) {
                    let used = windowSpec.isRemaining
                        ? max(0, min(100, 100 - Int(pct.rounded())))
                        : max(0, min(100, Int(pct.rounded())))
                    var resetDate = extractResetDate(from: line, now: now)
                    if resetDate == nil, idx + 1 < lines.count {
                        resetDate = extractResetDate(from: lines[idx + 1], now: now)
                    }
                    let group = currentGroup ?? windowSpec.inlineGroup
                    let winId = makeWindowID(group: group, label: windowSpec.label, index: windows.count)
                    windows.append(
                        QuotaWindow(
                            id: winId,
                            group: group,
                            label: windowSpec.label,
                            usedPercent: used,
                            resetsAt: resetDate,
                            windowDurationMins: windowSpec.durationMins
                        )
                    )
                    pendingLimitLabel = nil
                } else {
                    pendingLimitLabel = windowSpec.label
                    pendingIsRemaining = windowSpec.isRemaining
                    pendingWindowMins = windowSpec.durationMins
                }
                continue
            }

            // Detect bar + percentage line following a pending window title: "[██████░] 98.80%"
            if let label = pendingLimitLabel, let pct = extractPercentageValue(from: line) {
                let lineIndicatesUsed = lower.contains("used") && !lower.contains("remaining") && !lower.contains("left")
                let isRemaining = lineIndicatesUsed ? false : pendingIsRemaining
                let roundedPct = Int(pct.rounded())
                let used = isRemaining ? max(0, min(100, 100 - roundedPct)) : max(0, min(100, roundedPct))

                var resetDate = extractResetDate(from: line, now: now)
                if resetDate == nil, idx + 1 < lines.count {
                    resetDate = extractResetDate(from: lines[idx + 1], now: now)
                }

                let winId = makeWindowID(group: currentGroup, label: label, index: windows.count)
                windows.append(
                    QuotaWindow(
                        id: winId,
                        group: currentGroup,
                        label: label,
                        usedPercent: used,
                        resetsAt: resetDate,
                        windowDurationMins: pendingWindowMins
                    )
                )
                pendingLimitLabel = nil
                pendingWindowMins = nil
            }
        }

        // Deduplicate by (group + label), keeping the latest occurrence
        var deduped: [QuotaWindow] = []
        var indexByKey: [String: Int] = [:]
        for w in windows {
            let key = "\(w.group?.lowercased() ?? "")::\(w.label.lowercased())"
            if let existingIdx = indexByKey[key] {
                deduped[existingIdx] = w
            } else {
                indexByKey[key] = deduped.count
                deduped.append(w)
            }
        }

        if deduped.isEmpty {
            let fullLower = cleaned.lowercased()
            if accountEmail == nil && (fullLower.contains("currently not signed in") || fullLower.contains("sign in") || fullLower.contains("authenticate")) {
                return ProviderSnapshot(
                    provider: .antigravity,
                    status: .needsAuth(message: "Run `agy` once in Terminal to sign in with your Google account."),
                    binaryPath: binaryPath,
                    updatedAt: now
                )
            }
            return ProviderSnapshot(
                provider: .antigravity,
                status: .error(message: "Could not read quota summary from `agy /usage`. Click refresh to retry."),
                accountEmail: accountEmail,
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        return ProviderSnapshot(
            provider: .antigravity,
            status: .ready,
            planLabel: planLabel ?? "AGY",
            accountEmail: accountEmail,
            windows: deduped,
            binaryPath: binaryPath,
            updatedAt: now
        )
    }

    // MARK: - Line Helpers

    private static func parseModelGroupHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃╭╮╯╰─")))
        let upper = trimmed.uppercased()
        // Matches e.g. "GEMINI MODELS", "CLAUDE AND GPT MODELS"
        if upper == "GEMINI MODELS" {
            return "Gemini Models"
        }
        if upper == "CLAUDE AND GPT MODELS" || upper == "CLAUDE & GPT MODELS" {
            return "Claude and GPT models"
        }
        if trimmed == upper,
           upper.hasSuffix("MODELS"),
           upper.count <= 40,
           !upper.contains(":"),
           !upper.contains("%") {
            return trimmed.capitalized
        }
        return nil
    }

    private struct WindowTitleSpec {
        let inlineGroup: String?
        let label: String
        let isRemaining: Bool
        let durationMins: Int?
    }

    private static func parseWindowTitleLine(_ line: String) -> WindowTitleSpec? {
        let lower = line.lowercased()
        // Ignore explanatory callout box paragraph lines (prefixed with │ or ┃)
        if lower.hasPrefix("│") || lower.hasPrefix("┃") {
            return nil
        }
        if lower.hasPrefix("models within this group") {
            return nil
        }

        let isRemaining = !lower.contains("used") || lower.contains("remaining") || lower.contains("left")

        // Only match concise window title headers (never long prose sentences)
        if lower.count <= 45 {
            if lower.contains("weekly limit") {
                return WindowTitleSpec(inlineGroup: nil, label: "Weekly limit", isRemaining: isRemaining, durationMins: 10080)
            }
            if lower.contains("five hour limit") || lower.contains("5-hour limit") || lower.contains("5 hour limit") || lower.contains("5h limit") {
                return WindowTitleSpec(inlineGroup: nil, label: "5h limit", isRemaining: isRemaining, durationMins: 300)
            }
        }

        // Single-line compact format fallback (e.g. "Gemini Pro / Flash  65% remaining · Resets in 4h 30m")
        if extractPercentageValue(from: line) != nil,
           (lower.contains("gemini") || lower.contains("claude") || lower.contains("gpt")) {
            let cleanedLabel = line
                .replacingOccurrences(of: #"[│┃╭╮╯╰─]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\d+(?:\.\d+)?\s*%.*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "·:-")))
            if !cleanedLabel.isEmpty {
                return WindowTitleSpec(inlineGroup: nil, label: cleanedLabel, isRemaining: isRemaining, durationMins: nil)
            }
        }

        return nil
    }

    private static func extractPercentageValue(from text: String) -> Double? {
        let pattern = #"(\d{1,3}(?:\.\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let numRange = Range(match.range(at: 1), in: text),
              let rawVal = Double(text[numRange]),
              (0.0...100.0).contains(rawVal) else {
            return nil
        }
        return rawVal
    }

    public static func extractResetDate(from text: String, now: Date = Date()) -> Date? {
        let lower = text.lowercased()
        // Only parse lines that explicitly state "Refreshes in ..." or "Resets in ..."
        guard lower.contains("refresh") || lower.contains("reset") else {
            return nil
        }

        var totalSeconds: TimeInterval = 0
        var matchedAny = false

        let units: [(String, Double)] = [
            (#"(\d+)\s*d(?:ays?)?\b"#, 86400),
            (#"(\d+)\s*h(?:ours?|rs?)?\b"#, 3600),
            (#"(\d+)\s*m(?:in(?:ute)?s?)?\b"#, 60)
        ]

        for (pattern, multiplier) in units {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
               let valRange = Range(match.range(at: 1), in: lower),
               let value = Double(lower[valRange]) {
                totalSeconds += value * multiplier
                matchedAny = true
            }
        }

        if matchedAny && totalSeconds > 0 {
            return now.addingTimeInterval(totalSeconds)
        }
        return nil
    }

    private static func extractPlanTier(from line: String) -> String? {
        // Matches the status bar subscription label rendered in parentheses, e.g.
        // "auto ·  (Google AI Ultra)", "(Google AI Pro)", "(Google AI Ultra 5x)", "(Gemini Code Assist Enterprise)"
        let pattern = #"\(((?:Google AI|Gemini|AI Pro|AI Ultra|Enterprise|Free)[^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
            .replacingOccurrences(of: "Google ", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeWindowID(group: String?, label: String, index: Int) -> String {
        let g = (group ?? "default").lowercased().replacingOccurrences(of: " ", with: "-")
        let l = label.lowercased().replacingOccurrences(of: " ", with: "-")
        return "agy-\(g)-\(l)-\(index)"
    }

    // MARK: - POSIX PTY Runner for `agy`

    private static func queryAgyUsageViaPTY(binaryPath: String, now: Date) -> ProviderSnapshot {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 50, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
            return ProviderSnapshot(
                provider: .antigravity,
                status: .error(message: "Failed to allocate PTY for agy CLI."),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = []
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        process.environment = env
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
        } catch {
            close(masterFD)
            close(slaveFD)
            return ProviderSnapshot(
                provider: .antigravity,
                status: .error(message: "Failed to launch agy: \(error.localizedDescription)"),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        close(slaveFD)

        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        defer {
            if process.isRunning {
                process.terminate()
            }
            close(masterFD)
        }

        func writePTY(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                _ = Darwin.write(masterFD, base, rawBuf.count)
            }
        }

        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 8192)

        func drainAvailable() {
            while true {
                let n = Darwin.read(masterFD, &buf, buf.count)
                if n > 0 {
                    collected.append(buf, count: n)
                } else {
                    break
                }
            }
        }

        let start = Date()
        var sentUsage = false
        var usageSentAt: Date?

        while Date().timeIntervalSince(start) < 14.0 {
            drainAvailable()
            let currentText = String(decoding: collected, as: UTF8.self)
            let stripped = stripANSI(currentText)
            let lower = stripped.lowercased()

            // Wait until the TUI finishes signing in (renders user email `@`) before sending `/usage`
            if !sentUsage && ((lower.contains("@") && lower.contains("? for shortcuts")) || Date().timeIntervalSince(start) > 3.5) {
                writePTY("/usage\r")
                sentUsage = true
                usageSentAt = Date()
            }

            // Wait until the entire `/usage` modal has rendered its footer paragraph ("within each group")
            if let usageSentAt {
                if lower.contains("within each group") {
                    // Drain one more tick to capture trailing status bar plan tier
                    usleep(200_000)
                    drainAvailable()
                    break
                }
                if Date().timeIntervalSince(usageSentAt) > 8.0 && lower.contains("limit remaining") {
                    break
                }
            }

            if !process.isRunning {
                drainAvailable()
                break
            }
            usleep(150_000)
        }

        // Press Esc first so `agy` closes `/usage` and renders the header plan badge, e.g. `(Google AI Ultra)`
        writePTY("\u{001B}")
        let escSentAt = Date()
        while Date().timeIntervalSince(escSentAt) < 3.5 {
            usleep(150_000)
            drainAvailable()
            let strippedNow = stripANSI(String(decoding: collected, as: UTF8.self))
            if strippedNow.components(separatedBy: .newlines).contains(where: { extractPlanTier(from: $0) != nil }) {
                break
            }
        }

        // Exit CLI cleanly (Ctrl+D Ctrl+D)
        writePTY("\u{0004}\u{0004}")
        usleep(100_000)
        drainAvailable()

        let finalOutput = String(decoding: collected, as: UTF8.self)
        return parseUsageOutput(finalOutput, binaryPath: binaryPath, now: now)
    }
}

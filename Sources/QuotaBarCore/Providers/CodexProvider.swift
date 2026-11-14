import Foundation

// MARK: - Codex JSON-RPC Wire Payloads

public struct CodexRateLimitWindowWire: Decodable, Sendable {
    public let usedPercent: Int
    public let resetsAt: Int64?
    public let windowDurationMins: Int64?
}

public struct CodexCreditsWire: Decodable, Sendable {
    public let balance: String?
    public let hasCredits: Bool
    public let unlimited: Bool
}

public struct CodexRateLimitSnapshotWire: Decodable, Sendable {
    public let planType: String?
    public let limitId: String?
    public let limitName: String?
    public let normalModelSlug: String?
    public let primary: CodexRateLimitWindowWire?
    public let secondary: CodexRateLimitWindowWire?
    public let credits: CodexCreditsWire?
}

public struct CodexGetRateLimitsResultWire: Decodable, Sendable {
    public let accountId: String?
    public let ordinaryUsageAllowed: Bool?
    public let rateLimits: CodexRateLimitSnapshotWire
    public let rateLimitsByLimitId: [String: CodexRateLimitSnapshotWire]?
}

public struct CodexAccountDetailWire: Decodable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?
    public let workspaceName: String?
}

public struct CodexGetAccountResultWire: Decodable, Sendable {
    public let account: CodexAccountDetailWire?
    public let requiresOpenaiAuth: Bool
}

private struct RPCEnvelope<Result: Decodable>: Decodable {
    let id: Int?
    let result: Result?
    let error: RPCErrorWire?
}

private struct RPCErrorWire: Decodable {
    let code: Int?
    let message: String
}

// MARK: - Codex Provider

public enum CodexProvider {
    public static func fetchSnapshot(customPath: String = "", now: Date = Date()) async -> ProviderSnapshot {
        guard let binary = BinaryLocator.findCodex(customPath: customPath) else {
            return ProviderSnapshot(
                provider: .codex,
                status: .cliMissing(
                    installHint: "Install ChatGPT.app or run: brew install --cask codex"
                ),
                updatedAt: now
            )
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let snapshot = queryAppServerSync(binaryPath: binary, now: now)
                continuation.resume(returning: snapshot)
            }
        }
    }

    /// Parses a raw JSON-RPC `account/rateLimits/read` result JSON object into QuotaWindows.
    public static func parseRateLimitsResponseData(
        _ data: Data,
        accountData: Data? = nil,
        binaryPath: String? = nil,
        now: Date = Date()
    ) throws -> ProviderSnapshot {
        let decoder = JSONDecoder()
        let rpc = try decoder.decode(RPCEnvelope<CodexGetRateLimitsResultWire>.self, from: data)
        if let err = rpc.error {
            let lower = err.message.lowercased()
            if lower.contains("auth") || lower.contains("login") || lower.contains("unauthorized") {
                return ProviderSnapshot(
                    provider: .codex,
                    status: .needsAuth(message: err.message),
                    binaryPath: binaryPath,
                    updatedAt: now
                )
            }
            return ProviderSnapshot(
                provider: .codex,
                status: .error(message: err.message),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        guard let payload = rpc.result else {
            return ProviderSnapshot(
                provider: .codex,
                status: .error(message: "Empty rateLimits response from Codex app-server"),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        var email: String?
        var plan = payload.rateLimits.planType
        if let accountData,
           let accEnv = try? decoder.decode(RPCEnvelope<CodexGetAccountResultWire>.self, from: accountData),
           let accRes = accEnv.result {
            if accRes.requiresOpenaiAuth && accRes.account == nil {
                return ProviderSnapshot(
                    provider: .codex,
                    status: .needsAuth(message: "Sign in to ChatGPT / Codex to view subscription usage."),
                    binaryPath: binaryPath,
                    updatedAt: now
                )
            }
            email = accRes.account?.email
            if plan == nil {
                plan = accRes.account?.planType
            }
        }

        var windows: [QuotaWindow] = []
        if let p = payload.rateLimits.primary {
            windows.append(makeWindow(id: "primary", fallbackLabel: "5-Hour Window", wire: p))
        }
        if let s = payload.rateLimits.secondary {
            windows.append(makeWindow(id: "secondary", fallbackLabel: "Weekly Window", wire: s))
        }

        // Include any additional distinct model-specific buckets if exposed
        if let byId = payload.rateLimitsByLimitId {
            for key in byId.keys.sorted() where key != "codex" && key != payload.rateLimits.limitId {
                guard let extra = byId[key] else { continue }
                let prefix = extra.limitName ?? extra.normalModelSlug ?? key
                if let p = extra.primary {
                    windows.append(
                        makeWindow(
                            id: "\(key)-primary",
                            fallbackLabel: "\(prefix) (5h)",
                            wire: p,
                            customPrefix: prefix
                        )
                    )
                }
            }
        }

        let creditsText: String?
        if let credits = payload.rateLimits.credits {
            if credits.unlimited {
                creditsText = "Unlimited"
            } else if let bal = credits.balance, !bal.isEmpty {
                creditsText = bal
            } else {
                creditsText = nil
            }
        } else {
            creditsText = nil
        }

        return ProviderSnapshot(
            provider: .codex,
            status: .ready,
            planLabel: formatCodexPlanLabel(plan),
            accountEmail: email,
            creditsBalance: creditsText,
            windows: windows,
            binaryPath: binaryPath,
            updatedAt: now
        )
    }

    private static func formatCodexPlanLabel(_ rawPlan: String?) -> String? {
        guard let raw = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "promax": return "Pro Max"
        case "team": return "Team"
        case "business", "self_serve_business_usage_based": return "Business"
        case "self_serve_business_prolite": return "Business Lite"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based": return "Enterprise"
        case "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        default: return raw.capitalized
        }
    }

    private static func makeWindow(
        id: String,
        fallbackLabel: String,
        wire: CodexRateLimitWindowWire,
        customPrefix: String? = nil
    ) -> QuotaWindow {
        let baseLabel: String
        switch wire.windowDurationMins {
        case 300:
            baseLabel = "5-Hour Window"
        case 10080:
            baseLabel = "7-Day Window"
        case let mins?:
            if mins >= 1440 && mins % 1440 == 0 {
                baseLabel = "\(mins / 1440)-Day Window"
            } else if mins >= 60 && mins % 60 == 0 {
                baseLabel = "\(mins / 60)-Hour Window"
            } else {
                baseLabel = "\(mins)m Window"
            }
        case nil:
            baseLabel = fallbackLabel
        }

        let finalLabel = customPrefix.map { "\($0) · \(baseLabel)" } ?? baseLabel
        let resetDate = wire.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return QuotaWindow(
            id: id,
            label: finalLabel,
            usedPercent: wire.usedPercent,
            resetsAt: resetDate,
            windowDurationMins: wire.windowDurationMins.map(Int.init)
        )
    }

    private static func queryAppServerSync(binaryPath: String, now: Date) -> ProviderSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "--stdio"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ProviderSnapshot(
                provider: .codex,
                status: .error(message: "Failed to start codex app-server: \(error.localizedDescription)"),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        // Watchdog timer so background poll can never hang
        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeoutWork)
        defer {
            timeoutWork.cancel()
            try? stdinPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        func sendLine(_ json: String) -> Bool {
            guard let data = (json + "\n").data(using: .utf8) else { return false }
            let fd = stdinPipe.fileHandleForWriting.fileDescriptor
            return data.withUnsafeBytes { rawBuf -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                let written = Darwin.write(fd, base, rawBuf.count)
                return written == rawBuf.count
            }
        }

        var buffer = Data()
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        var readScratch = [UInt8](repeating: 0, count: 4096)

        func readResponse(matchingId targetId: Int) -> Data? {
            while true {
                if let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    buffer.removeSubrange(0...newlineRange.lowerBound)
                    if lineData.isEmpty { continue }
                    if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                       let id = obj["id"] as? Int,
                       id == targetId {
                        return lineData
                    }
                    continue
                }

                // Single POSIX read(2): returns immediately as soon as >=1 byte arrives
                let n = Darwin.read(outFD, &readScratch, readScratch.count)
                if n > 0 {
                    buffer.append(readScratch, count: n)
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return nil
                }
            }
        }

        let initReq = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"quota","version":"0.2.0"}}}"#
        guard sendLine(initReq), readResponse(matchingId: 1) != nil else {
            return ProviderSnapshot(
                provider: .codex,
                status: .error(message: "Codex app-server did not complete handshake."),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        _ = sendLine(#"{"method":"initialized"}"#)

        _ = sendLine(#"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#)
        let accountLine = readResponse(matchingId: 2)

        // Check early if account/read explicitly reports not signed in
        if let accountLine,
           let accEnv = try? JSONDecoder().decode(RPCEnvelope<CodexGetAccountResultWire>.self, from: accountLine),
           let accRes = accEnv.result,
           accRes.requiresOpenaiAuth && accRes.account == nil {
            return ProviderSnapshot(
                provider: .codex,
                status: .needsAuth(message: "Sign in to ChatGPT.app to view Codex usage."),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        _ = sendLine(#"{"id":3,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#)
        guard let limitsLine = readResponse(matchingId: 3) else {
            return ProviderSnapshot(
                provider: .codex,
                status: .error(message: "Timed out fetching Codex rate limits. Will retry automatically."),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }

        do {
            return try parseRateLimitsResponseData(
                limitsLine,
                accountData: accountLine,
                binaryPath: binaryPath,
                now: now
            )
        } catch {
            return ProviderSnapshot(
                provider: .codex,
                status: .error(message: "Decode error: \(error.localizedDescription)"),
                binaryPath: binaryPath,
                updatedAt: now
            )
        }
    }
}

import Foundation
import QuotaBarCore
import Testing

@Suite("Quota Parser Tests")
struct ParserTests {
    @Test("Decodes Codex app-server rateLimits & account JSON")
    func codexRateLimitsDecoding() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rateLimitsJSON = """
        {
          "id": 3,
          "result": {
            "accountId": "acc_123",
            "ordinaryUsageAllowed": true,
            "rateLimits": {
              "planType": "prolite",
              "limitId": "codex",
              "primary": {
                "usedPercent": 88,
                "resetsAt": 1800259200,
                "windowDurationMins": 10080
              }
            }
          }
        }
        """.data(using: .utf8)!

        let accountJSON = """
        {
          "id": 2,
          "result": {
            "account": {
              "type": "chatgpt",
              "email": "dev@example.com",
              "planType": "prolite"
            },
            "requiresOpenaiAuth": true
          }
        }
        """.data(using: .utf8)!

        let snapshot = try CodexProvider.parseRateLimitsResponseData(
            rateLimitsJSON,
            accountData: accountJSON,
            binaryPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            now: now
        )

        #expect(snapshot.status == .ready)
        #expect(snapshot.planLabel == "Pro Lite")
        #expect(snapshot.accountEmail == "dev@example.com")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "7-Day Window")
        #expect(snapshot.windows[0].usedPercent == 88)
        #expect(snapshot.windows[0].remainingPercent == 12)
    }

    @Test("Parses real agy 1.5.8 /usage multi-group TUI output accurately")
    func realAgyUsageOutputParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sampleAgyTUI = """
        \u{001B}[>4m\u{001B}[>4;2m\u{001B}[>5u
        Welcome to the Antigravity CLI. You are currently not signed in.
        ⣷  Signing in...\u{001B}[>4m\u{001B}[<1u
        └ Models & Quota
        \u{001B}[1mAccount: dev@example.com\u{001B}[m
        ⣷  Loading quota summary...
        \u{001B}[1mGEMINI MODELS\u{001B}[m
        Models within this group: Gemini Flash, Gemini Pro
        \u{001B}[1mWeekly Limit Remaining\u{001B}[m
        [█████████████████████████████████████████████████░] 98.80%
        Refreshes in 167h 9m
        \u{001B}[1mFive Hour Limit Remaining\u{001B}[m
        [████████████████████████████████████████████████░░] 95.18%
        Refreshes in 4h 9m
        \u{001B}[1mCLAUDE AND GPT MODELS\u{001B}[m
        Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
        \u{001B}[1mWeekly Limit Remaining\u{001B}[m
        [██████████████████████████████████████████████████] 100.00%
        Quota available
        \u{001B}[1mFive Hour Limit Remaining\u{001B}[m
        [██████████████████████████████████████████████████] 100.00%
        Quota available
        │Within each group, models share a weekly limit and a 5-hour limit.
        auto ·  (Google AI Ultra)
        """

        let snapshot = AntigravityProvider.parseUsageOutput(sampleAgyTUI, binaryPath: "~/.local/bin/agy", now: now)
        #expect(snapshot.status == .ready)
        #expect(snapshot.accountEmail == "dev@example.com")
        #expect(snapshot.planLabel == "AI Ultra")
        #expect(snapshot.windows.count == 4)

        // Gemini Models
        #expect(snapshot.windows[0].group == "Gemini Models")
        #expect(snapshot.windows[0].label == "Weekly limit")
        #expect(snapshot.windows[0].remainingPercent == 99)
        #expect(snapshot.windows[0].usedPercent == 1)
        #expect(snapshot.windows[0].formattedResetSummary(now: now)?.hasPrefix("Resets in 6d 23h") == true)

        #expect(snapshot.windows[1].group == "Gemini Models")
        #expect(snapshot.windows[1].label == "5h limit")
        #expect(snapshot.windows[1].remainingPercent == 95)
        #expect(snapshot.windows[1].usedPercent == 5)
        #expect(snapshot.windows[1].formattedResetSummary(now: now)?.hasPrefix("Resets in 4h 9m") == true)

        // Claude and GPT models
        #expect(snapshot.windows[2].group == "Claude and GPT models")
        #expect(snapshot.windows[2].label == "Weekly limit")
        #expect(snapshot.windows[2].remainingPercent == 100)
        #expect(snapshot.windows[2].resetsAt == nil)

        #expect(snapshot.windows[3].group == "Claude and GPT models")
        #expect(snapshot.windows[3].label == "5h limit")
        #expect(snapshot.windows[3].remainingPercent == 100)
        #expect(snapshot.windows[3].resetsAt == nil)
    }

    @Test("Retains last usage on refresh failure with warning and clears warning on next success")
    func resilientRefreshMergeLifecycle() {
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        let good = ProviderSnapshot(
            provider: .codex,
            status: .ready,
            planLabel: "Pro Lite",
            accountEmail: "dev@example.com",
            windows: [QuotaWindow(id: "w1", label: "7-Day Window", usedPercent: 88, resetsAt: t1.addingTimeInterval(86400), windowDurationMins: 10080)],
            updatedAt: t1
        )

        // 1. Auth or transient failure keeps previous windows AND attaches refreshWarning
        let failed = ProviderSnapshot(
            provider: .codex,
            status: .needsAuth(message: "Session expired. Open ChatGPT.app to sign in."),
            updatedAt: t1.addingTimeInterval(300)
        )
        let mergedAfterFail = QuotaStore.mergeSnapshot(previous: good, incoming: failed)
        #expect(mergedAfterFail.status == .ready)
        #expect(mergedAfterFail.windows.count == 1)
        #expect(mergedAfterFail.windows[0].remainingPercent == 12)
        #expect(mergedAfterFail.refreshWarning == "Session expired. Open ChatGPT.app to sign in.")

        // 2. Next successful refresh updates usage and clears refreshWarning automatically
        let recovered = ProviderSnapshot(
            provider: .codex,
            status: .ready,
            planLabel: "Pro Lite",
            accountEmail: "dev@example.com",
            windows: [QuotaWindow(id: "w1", label: "7-Day Window", usedPercent: 89, resetsAt: t1.addingTimeInterval(86400), windowDurationMins: 10080)],
            updatedAt: t1.addingTimeInterval(600)
        )
        let mergedAfterRecovery = QuotaStore.mergeSnapshot(previous: mergedAfterFail, incoming: recovered)
        #expect(mergedAfterRecovery.status == .ready)
        #expect(mergedAfterRecovery.windows[0].remainingPercent == 11)
        #expect(mergedAfterRecovery.refreshWarning == nil)
    }
}

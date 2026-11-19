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
        │across all users, while your weekly limit is tied directly to your individual
        0% context · auto ·  (Google AI Ultra)
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

    @Test("BinaryLocator honors custom path -> PATH priority and skips IDE GUI launchers for agy")
    func binaryLocatorPriorityOrder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("quota-locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let customDir = root.appendingPathComponent("custom", isDirectory: true)
        let pathDir1 = root.appendingPathComponent("path1", isDirectory: true)
        let pathDir2 = root.appendingPathComponent("path2", isDirectory: true)
        let fakeIDEBin = root.appendingPathComponent("Antigravity.app/Contents/Resources/app/bin", isDirectory: true)

        for dir in [customDir, pathDir1, pathDir2, fakeIDEBin] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func makeExec(_ url: URL) throws {
            try "#!/bin/sh\necho ok\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let customCodex = customDir.appendingPathComponent("codex")
        let path1Codex = pathDir1.appendingPathComponent("codex")
        let path2Codex = pathDir2.appendingPathComponent("codex")
        try makeExec(customCodex)
        try makeExec(path1Codex)
        try makeExec(path2Codex)

        // 1. Custom path overrides PATH
        #expect(
            BinaryLocator.findCodex(
                customPath: customCodex.path,
                pathDirectories: [pathDir1.path, pathDir2.path],
                includeStandardFallbacks: false
            ) == customCodex.path
        )

        // 2. Earlier PATH entry wins when custom path is unset
        #expect(
            BinaryLocator.findCodex(
                customPath: "",
                pathDirectories: [pathDir1.path, pathDir2.path],
                includeStandardFallbacks: false
            ) == path1Codex.path
        )

        // 3. IDE wrapper inside `.app/Contents/Resources/app/bin/agy` is skipped in favor of real CLI
        let fakeIDEAgy = fakeIDEBin.appendingPathComponent("agy")
        try makeExec(fakeIDEAgy)
        let symlinkInPath1 = pathDir1.appendingPathComponent("agy")
        try fm.createSymbolicLink(at: symlinkInPath1, withDestinationURL: fakeIDEAgy)

        let realCLIAgy = pathDir2.appendingPathComponent("agy")
        try makeExec(realCLIAgy)

        #expect(
            BinaryLocator.findAgy(
                customPath: "",
                pathDirectories: [pathDir1.path, pathDir2.path],
                includeStandardFallbacks: false
            ) == realCLIAgy.path
        )
    }

    @Test("UpdateService compares semantic versions and parses GitHub release payloads")
    func updateServiceParsingAndVersioning() throws {
        #expect(UpdateService.isNewerVersion("v0.1.4", than: "0.1.3") == true)
        #expect(UpdateService.isNewerVersion("0.2.0", than: "0.1.9") == true)
        #expect(UpdateService.isNewerVersion("0.1.3", than: "0.1.3") == false)
        #expect(UpdateService.isNewerVersion("0.1.2", than: "0.1.3") == false)
        #expect(UpdateService.isNewerVersion("0.2.0", than: "0.2.0-beta.1") == true)
        #expect(UpdateService.isNewerVersion("0.2.0-beta.1", than: "0.2.0") == false)

        let releaseJSON = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/yeoleobun/Quota/releases/tag/v0.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Quota-macos-arm64.zip",
              "browser_download_url": "https://github.com/yeoleobun/Quota/releases/download/v0.2.0/Quota-macos-arm64.zip"
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://github.com/yeoleobun/Quota/releases/download/v0.2.0/SHA256SUMS.txt"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try UpdateService.parseLatestReleaseData(releaseJSON, currentVersion: "0.1.3")
        #expect(parsed?.version == "0.2.0")
        #expect(parsed?.zipDownloadURL.lastPathComponent == "Quota-macos-arm64.zip")
        #expect(parsed?.sha256SumsURL?.lastPathComponent == "SHA256SUMS.txt")

        // Same or newer local version returns nil
        let upToDate = try UpdateService.parseLatestReleaseData(releaseJSON, currentVersion: "0.2.0")
        #expect(upToDate == nil)

        // SHA256SUMS.txt extraction
        let sums = """
        8d4f6ef68c22bd1c2af692e4271f8a515b2512c543ef3b8213f84f43681b3c65  Quota-macos-arm64.zip
        151535b9648f6bfaff7141e21d5ac6072a07eb04e4da24d055266d9be6a8358e  Quota-macos-arm64.dmg
        """
        #expect(
            UpdateService.extractExpectedSHA256(from: sums) ==
                "8d4f6ef68c22bd1c2af692e4271f8a515b2512c543ef3b8213f84f43681b3c65"
        )
    }
}

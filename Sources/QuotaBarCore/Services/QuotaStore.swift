import AppKit
import Combine
import Foundation

public enum QuotaAlertLevel: Sendable {
    case normal
    case warning
    case critical
}

@MainActor
public final class QuotaStore: ObservableObject {
    @Published public private(set) var snapshots: [ProviderID: ProviderSnapshot] = [
        .codex: ProviderSnapshot(provider: .codex, status: .idle),
        .antigravity: ProviderSnapshot(provider: .antigravity, status: .idle)
    ]
    @Published public var settings: AppSettings {
        didSet {
            persistSettings()
            reschedulePollingTimer()
        }
    }
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var now: Date = Date()
    @Published public private(set) var updateState: AppUpdateState = .idle

    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var updateTimer: Timer?

    private static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("quota", isDirectory: true)
    }

    private static var settingsURL: URL {
        configDirectoryURL.appendingPathComponent("settings.json")
    }

    private static var cacheURL: URL {
        configDirectoryURL.appendingPathComponent("snapshots.json")
    }

    public init() {
        self.settings = Self.loadSettings()
        if let cached = Self.loadCachedSnapshots() {
            for (k, v) in cached {
                self.snapshots[k] = v
            }
        }
        startClockTimer()
        reschedulePollingTimer()
        startUpdateCheckTimer()

        Task {
            await refreshAll()
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            _ = await self?.checkForUpdates(userInitiated: false)
        }
    }

    public func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        snapshots[provider] ?? ProviderSnapshot(provider: provider, status: .idle)
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        now = Date()

        let codexPath = settings.customCodexPath
        let agyPath = settings.customAgyPath
        let fetchTime = Date()

        async let codexSnap = CodexProvider.fetchSnapshot(customPath: codexPath, now: fetchTime)
        async let agySnap = AntigravityProvider.fetchSnapshot(customPath: agyPath, now: fetchTime)

        let (cResult, aResult) = await (codexSnap, agySnap)

        snapshots[.codex] = Self.mergeSnapshot(previous: snapshots[.codex], incoming: cResult)
        snapshots[.antigravity] = Self.mergeSnapshot(previous: snapshots[.antigravity], incoming: aResult)
        now = Date()
        isRefreshing = false
        persistCache()
    }

    // MARK: - Menu Bar Weekly Watermark Indicator

    /// Returns the Green / Yellow / Red weekly watermark level for `settings.selectedProvider`,
    /// or `nil` when the indicator option is turned off or weekly usage has not loaded yet.
    /// Watermarks (remaining %):
    /// - Green (`.normal`): > 25% remaining (< 75% used)
    /// - Yellow (`.warning`): 11% – 25% remaining (75% – 89% used)
    /// - Red (`.critical`): <= 10% remaining (>= 90% used)
    public var selectedWeeklyWatermark: QuotaAlertLevel? {
        guard settings.showWeeklyIndicator else { return nil }
        guard let used = snapshots[settings.selectedProvider]?.peakWeeklyUsedPercent else {
            return nil
        }
        if used >= 90 { return .critical }
        if used >= 75 { return .warning }
        return .normal
    }

    // MARK: - Onboarding / Auth Actions

    public func openTerminalToInstallAgy() {
        let cmd = #"curl -fsSL https://antigravity.google/cli/install.sh | bash && echo "" && echo "Installed! Starting agy for sign-in..." && ~/.local/bin/agy"#
        runCommandInTerminalApp(cmd)
    }

    public func openAgyAppOrLogin() {
        let appURL = URL(fileURLWithPath: "/Applications/Antigravity.app")
        if BinaryLocator.findAgy(customPath: settings.customAgyPath) != nil {
            let path = BinaryLocator.findAgy(customPath: settings.customAgyPath) ?? "~/.local/bin/agy"
            runCommandInTerminalApp(path)
        } else if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    public func openChatGPTApp() {
        let codexAppURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let chatGPTAppURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        if let path = BinaryLocator.findCodex(customPath: settings.customCodexPath),
           !path.contains(".app/Contents/") {
            runCommandInTerminalApp("\(path) login")
        } else if FileManager.default.fileExists(atPath: codexAppURL.path) {
            NSWorkspace.shared.openApplication(at: codexAppURL, configuration: NSWorkspace.OpenConfiguration())
        } else if FileManager.default.fileExists(atPath: chatGPTAppURL.path) {
            NSWorkspace.shared.openApplication(at: chatGPTAppURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func runCommandInTerminalApp(_ command: String) {
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptURL = tmpDir.appendingPathComponent("quota-helper.command")
        let scriptBody = """
        #!/bin/zsh
        clear
        echo "=== Quota Setup ==="
        \(command)
        """
        do {
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Resilient Snapshot Merging

    /// Preserves the last known usage windows whenever a refresh fails (whether due to outdated auth
    /// or a temporary CLI/network error), attaches `refreshWarning`, and clears the warning automatically
    /// as soon as a subsequent refresh succeeds.
    public nonisolated static func mergeSnapshot(previous: ProviderSnapshot?, incoming: ProviderSnapshot) -> ProviderSnapshot {
        // Success: clear any prior refreshWarning and preserve known plan tier if incoming fell back to generic "AGY"
        if incoming.status == .ready {
            var clean = incoming
            clean.refreshWarning = nil
            if (clean.planLabel == nil || clean.planLabel == "AGY"),
               let prevPlan = previous?.planLabel,
               prevPlan != "AGY" {
                clean.planLabel = prevPlan
            }
            return clean
        }

        // Failure: if we have previous valid usage windows, keep showing them and surface a warning banner
        if let previous, !previous.windows.isEmpty {
            var retained = previous
            retained.status = .ready
            switch incoming.status {
            case .needsAuth(let message):
                retained.refreshWarning = message
            case .error:
                retained.refreshWarning = "Refresh failed (auth may be outdated or temporary error)."
            case .cliMissing(let installHint):
                retained.refreshWarning = installHint
            default:
                break
            }
            return retained
        }

        return incoming
    }

    private func startClockTimer() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
            }
        }
    }

    private func reschedulePollingTimer() {
        pollTimer?.invalidate()
        let seconds = TimeInterval(max(1, settings.refreshIntervalMinutes) * 60)
        pollTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
    }

    // MARK: - Serverless GitHub Releases Update Check & Self-Update

    private func startUpdateCheckTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    @discardableResult
    public func checkForUpdates(userInitiated: Bool) async -> AppUpdateState {
        if case .updating = updateState {
            return updateState
        }
        let previousAvailable: ReleaseAssetInfo? = {
            if case .updateAvailable(let info) = updateState { return info }
            return nil
        }()

        if userInitiated {
            updateState = .checking
        }

        do {
            if let latest = try await UpdateService.fetchLatestUpdate() {
                updateState = .updateAvailable(latest)
            } else {
                updateState = userInitiated
                    ? .upToDate(version: UpdateService.currentAppVersion)
                    : .idle
            }
        } catch {
            if let previousAvailable {
                updateState = .updateAvailable(previousAvailable)
            } else if userInitiated {
                updateState = .failed(message: error.localizedDescription)
            } else {
                updateState = .idle
            }
        }
        return updateState
    }

    public func installAvailableUpdate(_ release: ReleaseAssetInfo) async throws {
        updateState = .updating(version: release.version)
        do {
            try await UpdateService.stageAndLaunchReplacement(for: release)
            NSApplication.shared.terminate(nil)
        } catch {
            updateState = .updateAvailable(release)
            throw error
        }
    }

    private static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    private func persistSettings() {
        do {
            try FileManager.default.createDirectory(at: Self.configDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: Self.settingsURL, options: .atomic)
        } catch {
            // Non-fatal
        }
    }

    private static func loadCachedSnapshots() -> [ProviderID: ProviderSnapshot]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([ProviderSnapshot].self, from: data) else { return nil }
        var dict: [ProviderID: ProviderSnapshot] = [:]
        for item in list {
            dict[item.provider] = item
        }
        return dict
    }

    private func persistCache() {
        do {
            try FileManager.default.createDirectory(at: Self.configDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let list = ProviderID.allCases.compactMap { snapshots[$0] }
            let data = try encoder.encode(list)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            // Non-fatal
        }
    }
}

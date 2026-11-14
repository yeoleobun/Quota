import Foundation

public enum BinaryLocator {
    private static let cacheLock = NSLock()
    private static var cachedLoginShellPATH: [String]?

    /// Resolves the `codex` CLI binary in priority order:
    /// 1. Explicit user override (`customCodexPath` in `~/.config/quota/settings.json`)
    /// 2. `PATH` (current process `PATH`, then login shell `PATH`)
    /// 3. Standalone CLI package managers (`Homebrew`, `~/.local/bin`, `bun`, `volta`, `mise`, `asdf`, `npm`, `nvm`)
    /// 4. Bundled desktop app runtimes (`Codex.app`, then `ChatGPT.app`)
    public static func findCodex(
        customPath: String = "",
        pathDirectories: [String]? = nil,
        includeStandardFallbacks: Bool = true
    ) -> String? {
        if let custom = resolveCustomExecutable(customPath) {
            return custom
        }

        let searchDirs = pathDirectories ?? combinedPATHDirectories()
        if let fromPATH = findInDirectories(named: "codex", directories: searchDirs) {
            return fromPATH
        }

        guard includeStandardFallbacks else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 3. Standalone CLI locations (when GUI app PATH does not include them)
        let standaloneCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.local/share/mise/shims/codex",
            "\(home)/.asdf/shims/codex",
            "\(home)/.npm-global/bin/codex"
        ]
        for path in standaloneCandidates where isExecutable(path) {
            return path
        }

        // Check NVM node installations (newest version first)
        let nvmVersions = "\(home)/.nvm/versions/node"
        if let nodes = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            for node in nodes.sorted(by: versionCompareDesc) {
                let candidate = "\(nvmVersions)/\(node)/bin/codex"
                if isExecutable(candidate) {
                    return candidate
                }
            }
        }

        // 4. Desktop app bundled runtimes (`Codex.app` first, then `ChatGPT.app`)
        let appCandidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/bin/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        ]
        for path in appCandidates where isExecutable(path) {
            return path
        }

        return nil
    }

    /// Resolves the Antigravity CLI (`agy`) binary in priority order:
    /// 1. Explicit user override (`customAgyPath` in `~/.config/quota/settings.json`)
    /// 2. `PATH` (current process `PATH`, then login shell `PATH`, excluding IDE GUI launchers)
    /// 3. Standard CLI install locations (`~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy`)
    public static func findAgy(
        customPath: String = "",
        pathDirectories: [String]? = nil,
        includeStandardFallbacks: Bool = true
    ) -> String? {
        if let custom = resolveCustomExecutable(customPath) {
            return custom
        }

        let searchDirs = pathDirectories ?? combinedPATHDirectories()
        if let fromPATH = findInDirectories(
            named: "agy",
            directories: searchDirs,
            filter: isAgyCLIBinary
        ) {
            return fromPATH
        }

        guard includeStandardFallbacks else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ]
        for path in candidates where isExecutable(path) && isAgyCLIBinary(path) {
            return path
        }

        return nil
    }

    // MARK: - Helpers

    private static func resolveCustomExecutable(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return isExecutable(expanded) ? expanded : nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Excludes Electron/VS Code IDE window launcher scripts (`.../Contents/Resources/app/bin/agy`)
    /// so Quota only invokes the terminal Antigravity CLI.
    private static func isAgyCLIBinary(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return !resolved.contains(".app/Contents/Resources/app/bin/")
    }

    private static func findInDirectories(
        named binaryName: String,
        directories: [String],
        filter: (String) -> Bool = { _ in true }
    ) -> String? {
        for rawDir in directories {
            let trimmed = rawDir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let dir = (trimmed as NSString).expandingTildeInPath
            let candidate = (dir as NSString).appendingPathComponent(binaryName)
            if isExecutable(candidate), filter(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func combinedPATHDirectories() -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func appendUnique(_ dirs: [String]) {
            for dir in dirs where !dir.isEmpty && seen.insert(dir).inserted {
                result.append(dir)
            }
        }

        if let envPATH = ProcessInfo.processInfo.environment["PATH"] {
            appendUnique(envPATH.split(separator: ":").map(String.init))
        }
        appendUnique(loginShellPATHDirectories())
        return result
    }

    private static func loginShellPATHDirectories() -> [String] {
        cacheLock.lock()
        if let cached = cachedLoginShellPATH {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellExec = isExecutable(shell) ? shell : "/bin/zsh"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellExec)
        proc.arguments = ["-lc", #"printf "%s" "$PATH""#]
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        var resolved: [String] = []
        do {
            try proc.run()
            let timeout = DispatchWorkItem {
                if proc.isRunning {
                    proc.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: timeout)
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            timeout.cancel()

            if proc.terminationStatus == 0,
               let text = String(data: data, encoding: .utf8) {
                resolved = text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ":")
                    .map(String.init)
            }
        } catch {
            resolved = []
        }

        cacheLock.lock()
        cachedLoginShellPATH = resolved
        cacheLock.unlock()
        return resolved
    }

    private static func versionCompareDesc(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedDescending
    }
}

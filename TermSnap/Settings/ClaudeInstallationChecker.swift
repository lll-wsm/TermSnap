import Foundation

/// Checks whether `claude` is installed and reachable from the user's interactive shell PATH.
///
/// Strategy (in order):
///  1. Run `/bin/zsh -ilc 'command -v claude'` — `-i` is critical: PATH additions like
///     `~/.local/bin` or nvm/pyenv shims usually live in `~/.zshrc`, which `-l` alone
///     does NOT load (login ≠ interactive for zsh). With `-i` we see the same PATH
///     Terminal sees when the user types a command.
///  2. Fallback: scan a handful of well-known user-level bin directories. Catches the
///     case where the shell check errored out (corrupt rc, slow plugin, sandbox quirks).
enum ClaudeInstallationChecker {
    /// Returns true if `claude` resolves. Synchronous; ~300ms typical, hard timeout 3s.
    /// Run off the main thread for snappier UI.
    static func isInstalled(timeout: TimeInterval = 3.0) -> Bool {
        if checkViaShell(timeout: timeout) { return true }
        return checkCommonPaths()
    }

    // MARK: - Shell check

    private static func checkViaShell(timeout: TimeInterval) -> Bool {
        let process = Process()
        process.launchPath = "/bin/zsh"
        // -i: interactive (loads .zshrc, where most users put PATH additions)
        // -l: login (loads .zprofile)
        // -c: run command and exit
        process.arguments = ["-ilc", "command -v claude"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            NSLog("TermSnap: ClaudeInstallationChecker shell launch failed: \(error)")
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            NSLog("TermSnap: ClaudeInstallationChecker shell check timed out")
            return false
        }

        let ok = process.terminationStatus == 0
        if ok, let data = try? outPipe.fileHandleForReading.readToEnd(),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            NSLog("TermSnap: claude resolved via shell at \(s)")
        }
        return ok
    }

    // MARK: - Fallback path scan

    /// Bin directories where `claude` is commonly installed. Order is hot-paths-first.
    private static var commonBinPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    private static func checkCommonPaths() -> Bool {
        let fm = FileManager.default
        for path in commonBinPaths where fm.isExecutableFile(atPath: path) {
            NSLog("TermSnap: claude found via common-path scan at \(path)")
            return true
        }
        return false
    }
}


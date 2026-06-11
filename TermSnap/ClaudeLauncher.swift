import AppKit

/// Launches `claude` in a NEW Terminal window with the provider's environment variables
/// applied INLINE — variables apply only to the `claude` child process, never polluting
/// the parent shell or other windows.
///
/// Implementation notes:
///  - "New window" is forced by `set newWin to do script ""` (a hidden first script call
///    opens an empty window); the real command runs `in newWin`. Without this, `do script`
///    would inject the command into whatever tab is currently frontmost.
///  - Token comes from `provider.apiKeyEnv` (e.g. `"$GLM_API_KEY"`) as a literal — Terminal's
///    interactive zsh loads `~/.zshrc` and expands it. The real secret never touches our
///    process and only the variable name lands in `.zsh_history`.
enum ClaudeLauncher {
    @MainActor
    static func launch(at directoryPath: String, provider: ClaudeProvider) {
        NSLog("TermSnap: Launching Claude (model=\(provider.modelName)) at: \(directoryPath)")

        NSApp.activate(ignoringOtherApps: true)

        let snippet = ClaudeModelsConfig.launchSnippet(for: provider)
        // `cd 'path'` with single-quote escaping: `'` becomes `'\''`.
        let escapedPath = directoryPath.replacingOccurrences(of: "'", with: "'\\''")
        let fullCommand = "cd '\(escapedPath)' && clear && \(snippet)"

        // Escape the full command for embedding inside an AppleScript "" string.
        let escapedCommand = fullCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            set newWin to do script ""
            do script "\(escapedCommand)" in newWin
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            NSLog("TermSnap: Failed to create AppleScript for Claude launch")
            showErrorAlert(message: "创建 AppleScript 失败")
            return
        }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        if let error = error {
            let errCode = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            NSLog("TermSnap: Claude launch AppleScript error \(errCode): \(message)")

            if errCode == -1743 {
                showErrorAlert(message: "授权失败：请在 系统设置 > 隐私与安全性 > 自动化 中允许 TermSnap 控制“终端”。\n\n提示：如果列表中没有 TermSnap，请尝试在终端执行：\ntccutil reset AppleEvents com.lll.TermSnap")
            } else {
                showErrorAlert(message: "启动 Claude Code 失败 (\(errCode)): \(message)")
            }
        }
    }

    private static func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

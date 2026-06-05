import AppKit

enum TerminalLauncher {
    @MainActor
    static func openDirectory(_ directoryPath: String) {
        NSLog("TermSnap: Attempting to open Terminal at: \(directoryPath)")

        // Ensure the app is active to help trigger the permission dialog
        NSApp.activate(ignoringOtherApps: true)

        let escapedPath = directoryPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        set targetPath to "\(escapedPath)"
        tell application "Terminal"
            do script "cd " & quoted form of targetPath & " && clear"
            activate
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            NSLog("TermSnap: Failed to create AppleScript")
            showErrorAlert(message: "创建 AppleScript 失败")
            return
        }

        // Execute on main thread for first attempt to ensure UI/Permission prompt works
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        if let error = error {
            let errCode = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            NSLog("TermSnap: AppleScript error \(errCode): \(message)")
            
            if errCode == -1743 {
                showErrorAlert(message: "授权失败：请在 系统设置 > 隐私与安全性 > 自动化 中允许 TermSnap 控制“终端”。\n\n提示：如果列表中没有 TermSnap，请尝试在终端执行：\ntccutil reset AppleEvents com.lll.TermSnap")
            } else {
                showErrorAlert(message: "脚本执行失败 (\(errCode)): \(message)")
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

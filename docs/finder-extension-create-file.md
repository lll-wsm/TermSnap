# Finder 右键「创建新文件」实现

## 整体流程

```
用户在 Finder 右键 → FIFinderSync.menu(for:) 构建菜单
  → 显示「创建新文件」子菜单 (模板列表)
  → 用户点击模板名称 → createFileAction(_:)
  → 写入共享 UserDefaults (模板路径 + 目标目录)
  → 发送 Darwin Notification → 主应用 processRequests()
  → 验证模板存在 → 处理文件名冲突 → FileManager.copyItem()
  → Finder 中选中新文件
```

## 架构概览

```
┌─────────────────────────────────┐     ┌──────────────────────────┐
│  TermSnapFinderExtension        │     │  TermSnap (主应用)        │
│  (独立进程, Sandboxed)           │     │                          │
│                                 │     │                          │
│  FinderSyncExtension            │     │  AppDelegate             │
│  ├─ menu(for:) 构建右键菜单      │     │  ├─ 监听 Darwin 通知      │
│  ├─ createFileAction(_:) 触发   │     │  ├─ processRequests()    │
│  └─ openTerminalAction(_:) 触发 │     │  │  ├─ 打开终端           │
│                                 │     │  │  └─ 创建文件           │
│  TemplateManager (共享副本)      │     │  └─ 验证、冲突处理、写入   │
│  AppSettings (共享副本)          │     │                          │
│                                 │     │  TemplateManager (共享副本) │
│  ──────── 共享 UserDefaults ────────  │  AppSettings (共享副本)     │
│        (group.com.lll.TermSnap) │     │                          │
│                                 │     │                          │
│  ─────── Darwin Notification ──────  │                          │
│        (com.lll.TermSnap.request)│    │                          │
└─────────────────────────────────┘     └──────────────────────────┘
```

## 跨进程通信

扩展和主应用无法直接通信，通过两层机制实现：

### 第一层：共享 UserDefaults (数据传递)

```swift
let defaults = UserDefaults(suiteName: "group.com.lll.TermSnap")!
```

| Key | 类型 | 用途 |
|-----|------|------|
| `createFileTemplatePath` | String | 模板文件的完整路径 |
| `createFileTargetDir` | String | 要创建文件的目标目录 |
| `lastOpenTerminalPath` | String | 要打开终端的目录 |
| `enabledTemplates` | [String] | 用户启用的模板文件名列表 |
| `showCreateFileMenu` | Bool | 是否显示创建文件菜单 |

### 第二层：Darwin Notification (信号通知)

```swift
// 扩展端 — 发送通知
let center = CFNotificationCenterGetDarwinNotifyCenter()
CFNotificationCenterPostNotification(center,
    CFNotificationName("com.lll.TermSnap.request" as CFString),
    nil, nil, true)

// 主应用端 — 接收通知
CFNotificationCenterAddObserver(center, observer,
    { (_, _, _, _, _) in
        // 回调中调用 processRequests()
    },
    "com.lll.TermSnap.request" as CFString,
    nil, .deliverImmediately)
```

**为什么用 Darwin Notification 而不是 DistributedNotificationCenter？**

- Darwin 通知是内核级通知，不需要 RunLoop，即使接收方未运行也能投递
- 不携带 payload（userInfo 始终为 nil），所以数据必须通过共享 UserDefaults 传递
- 跨进程信号传递最可靠的方式

### 完整通信流程

```
扩展端                               主应用端
  │                                     │
  ├─ defaults.set(templatePath, ...)    │
  ├─ defaults.set(targetDirPath, ...)   │
  ├─ defaults.synchronize()             │
  ├─ CFNotificationPost(...)  ────────→ 收到通知
  │                                     ├─ sharedDefaults.synchronize()
  │                                     ├─ 读取 createFileTemplatePath
  │                                     ├─ 读取 createFileTargetDir
  │                                     ├─ 验证 → 复制 → 冲突处理
  │                                     ├─ removeObject(forKey:)
  │                                     └─ defaults.synchronize()
```

## 模板系统

### 目录结构

```
~/Library/Group Containers/group.com.lll.TermSnap/
├── Templates/           ← 用户放置模板文件
│   ├── Markdown.md
│   ├── Python.py
│   ├── 新建文本文档.txt
│   └── ...
├── Icons/               ← 可选的自定义图标
│   ├── Markdown.png
│   └── Python.pdf
└── ...

~/.config/TermSnap/      ← 符号链接，方便用户访问
```

### TemplateManager

同时存在于主应用和扩展中（两份相同代码）：

```swift
class TemplateManager: ObservableObject {
    static let shared = TemplateManager()

    var templatesDir: URL {
        configDir.appendingPathComponent("Templates")
    }

    func getEnabledTemplates() -> [URL] {
        let enabled = AppSettings.enabledTemplates  // 从 UserDefaults 读取
        return availableTemplates.filter { enabled.contains($0.lastPathComponent) }
    }
}
```

- `availableTemplates` — 模板目录中所有文件（排除 `.` 开头的隐藏文件）
- `getEnabledTemplates()` — 只返回用户在设置中启用的模板
- 图标查找顺序：`Icons/{name}.png` → `Icons/{name}.pdf` → 系统文件类型图标

## 菜单构建

```swift
override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    // 1. 同步 UserDefaults
    // 2. 根据 menuLayout 决定嵌套/平铺
    // 3. 如果 showTerminalMenu → 添加「打开终端」
    // 4. 如果 showCreateFileMenu && !templates.isEmpty:
    //    → 添加「创建新文件」子菜单
    //    → 每个模板一个 NSMenuItem，title = 文件名
}
```

菜单结构：

```
右键菜单
└── TermSnap (如果 menuLayout = "nested")
    ├── 打开终端            ← openTerminalAction(_:)
    └── 创建新文件           ← 子菜单
        ├── Markdown.md     ← createFileAction(_:)
        ├── Python.py
        ├── 新建文本文档.txt
        └── ...
```

## 文件创建流程 (主应用端)

```swift
// AppDelegate.swift — processRequests()
// 2. Process File Creation Request
let templatePath = sharedDefaults.string(forKey: "createFileTemplatePath") ?? ""
let targetDirPath = sharedDefaults.string(forKey: "createFileTargetDir") ?? ""

// 验证模板存在
guard FileManager.default.fileExists(atPath: templatePath) else { ... }

// 文件名冲突处理：file.txt → file 2.txt → file 3.txt
while FileManager.default.fileExists(atPath: finalDestURL.path) {
    finalDestURL = targetDir.appendingPathComponent("\(name) \(counter).\(ext)")
    counter += 1
}

// 复制模板到目标位置
try FileManager.default.copyItem(at: templateURL, to: finalDestURL)

// 在 Finder 中选中新文件
NSWorkspace.shared.activateFileViewerSelecting([finalDestURL])
```

## ⚠️ representedObject 陷阱

这是开发中遇到的关键问题。

### 现象

- 菜单显示正常，模板列表正确
- 点击模板项后没有任何反应，日志也看不到

### 原因

菜单构建时设置了 `NSMenuItem.representedObject`：

```swift
item.representedObject = template.path  // 在 menu(for:) 中设置
```

但 **Finder 显示子菜单时会创建 NSMenuItem 的副本，且不会保留 `representedObject`**。用户点击的子菜单项是 Finder 的副本，其 `representedObject` 为 `nil`：

```swift
@objc func createFileAction(_ sender: NSMenuItem) {
    guard let templatePath = sender.representedObject as? String else { return }
    // ↑ sender 是 Finder 的副本，representedObject == nil → 静默返回
}
```

### 解决方案

不依赖 `representedObject`，改用菜单项的 **title**（Finder 会保留）来重建模板路径：

```swift
@objc func createFileAction(_ sender: AnyObject?) {
    guard let menuItem = sender as? NSMenuItem else { return }

    // 用 title 重建路径：title 就是模板文件名
    let templateURL = TemplateManager.shared.templatesDir
        .appendingPathComponent(menuItem.title)

    guard FileManager.default.fileExists(atPath: templateURL.path) else {
        return
    }

    let targetDirPath = getTargetURL().path

    // 写入共享 UserDefaults → 发送 Darwin 通知
    defaults.set(templateURL.path, forKey: "createFileTemplatePath")
    defaults.set(targetDirPath, forKey: "createFileTargetDir")
    defaults.synchronize()
    notifyMainApp()
}
```

**关键教训**：在 FIFinderSync 的子菜单中，**只有 `title` 是 Finder 可靠保留的属性**，`representedObject` 和 `tag` 在副本中都会丢失。

## 相关文件

| 文件 | 作用 |
|------|------|
| `TermSnapFinderExtension/FinderSyncExtension.swift` | FIFinderSync 子类，菜单构建 + 动作触发 + 发送通知 |
| `TermSnapFinderExtension/TemplateManager.swift` | 模板文件管理，读取 Templates 目录 |
| `TermSnapFinderExtension/AppSettings.swift` | 共享 UserDefaults 封装，设置读写 |
| `TermSnap/AppDelegate.swift` | 主应用，接收通知 + processRequests() 处理文件创建 |
| `TermSnap/Settings/SettingsView.swift` | 设置界面，模板选择 + 开关 |
| `TermSnap/Settings/TemplateManager.swift` | 主应用中的模板管理器（与扩展中相同） |

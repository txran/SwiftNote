import AppKit
import SwiftNoteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var pendingURLs: [URL] = []
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        // 无头走查外观：SWIFTNOTE_APPEARANCE=dark|light 只影响本进程（系统深浅色不改）
        if let style = ProcessInfo.processInfo.environment["SWIFTNOTE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
        }
        MainMenuBuilder.install()

        // 快捷键改动后重建菜单（NSMenuItem 的键位是拷贝进去的，改设置不会自动生效）
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification, object: nil, queue: .main) { note in
            let keys = note.userInfo?[AppSettings.changedKeysKey] as? [String] ?? []
            MainMenuBuilder.rebuildIfShortcutsChanged(keys)
        }

        let controller = MainWindowController(store: .shared)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        let restored = EditorStore.shared.restoreSession()
        if !restored {
            EditorStore.shared.newDocument()
        }
        controller.refreshAll()

        if !pendingURLs.isEmpty {
            EditorStore.shared.open(urls: pendingURLs)
            pendingURLs = []
        }

        // 命令行传入文件（开发期冒烟测试用）
        let cliURLs = CommandLine.arguments.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !cliURLs.isEmpty {
            EditorStore.shared.open(urls: cliURLs)
        }

        controller.window?.makeKeyAndOrderFront(nil)
        controller.applySnapshotAutomation()
        controller.scheduleDebugSnapshot()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if windowController == nil {
            pendingURLs.append(contentsOf: urls)
        } else {
            EditorStore.shared.open(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.syncPlainScrollToDocument()
        let dirty = EditorStore.shared.documents.filter { $0.isDirty }
        guard !dirty.isEmpty else {
            EditorStore.shared.persistSession()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "有 \(dirty.count) 个文档未保存"
        alert.informativeText = dirty.map { "· \($0.displayName)" }.joined(separator: "\n")
        alert.addButton(withTitle: "全部保存")
        alert.addButton(withTitle: "不保存退出")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for doc in dirty {
                if !EditorStore.shared.save(document: doc) {
                    return .terminateCancel
                }
            }
            EditorStore.shared.persistSession()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 纯文本面板没有 editor 对象，滚动位置要先从视图抄回文档，再落盘
        windowController?.syncPlainScrollToDocument()
        EditorStore.shared.persistSession()
    }
}

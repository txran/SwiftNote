import AppKit
import SwiftNoteKit

/// 菜单与快捷键（设计说明书 5.7 快捷键路由、App 层统一派发）
///
/// 可自定义的动作一律通过 `ShortcutAction` 取键位（`AppSettings.shortcut(_:)`），
/// 其余系统标准动作（撤销/剪切/粘贴、窗口、应用菜单）保持固定——
/// 这些是 macOS 通用约定，改了对用户没有收益，还会和文本框内建行为打架。
enum MainMenuBuilder {
    static func install() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item("关于 SwiftNote", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        let settings = item("设置…", #selector(SettingsWindowController.showSettings(_:)), .showSettings)
        settings.target = SettingsWindowController.shared
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(plainItem("隐藏 SwiftNote", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(plainItem("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h",
                                  modifiers: [.command, .option]))
        appMenu.addItem(item("显示全部", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(plainItem("退出 SwiftNote", #selector(NSApplication.terminate(_:)), "q"))

        // 文件菜单
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(item("新建", #selector(MainWindowController.newDocument(_:)), .newDocument))
        fileMenu.addItem(item("打开…", #selector(MainWindowController.openDocument(_:)), .openDocument))
        fileMenu.addItem(item("快速打开最近文件…", #selector(MainWindowController.quickOpenRecent(_:)), .quickOpenRecent))
        // 子菜单内容动态生成：最近文件随时在变，菜单每次打开时重建（FR-11）
        let recentItem = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "最近打开")
        recentMenu.delegate = RecentFilesMenuDelegate.shared
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("保存", #selector(MainWindowController.saveDocument(_:)), .saveDocument))
        fileMenu.addItem(item("另存为…", #selector(MainWindowController.saveDocumentAs(_:)), .saveDocumentAs))
        fileMenu.addItem(item("从磁盘重新加载", #selector(MainWindowController.reloadFromDisk(_:)), .reloadFromDisk))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("对比文件…", #selector(MainWindowController.compareFiles(_:)), .compareFiles))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("关闭标签", #selector(MainWindowController.closeCurrentTab(_:)), .closeTab))
        fileMenu.addItem(plainItem("关闭窗口", #selector(NSWindow.performClose(_:)), "w",
                                   modifiers: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("在 Finder 中显示", #selector(MainWindowController.revealInFinder(_:)), .revealInFinder))

        // 编辑菜单（撤销/剪切/拷贝/粘贴/全选走系统标准键位，不开放自定义）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(plainItem("撤销", Selector(("undo:")), "z"))
        editMenu.addItem(plainItem("重做", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(plainItem("剪切", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(plainItem("拷贝", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(plainItem("粘贴", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(plainItem("全选", #selector(NSText.selectAll(_:)), "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("查找…", #selector(MainWindowController.performFind(_:)), .find))
        editMenu.addItem(item("查找并替换…", #selector(MainWindowController.performFindAndReplace(_:)), .findAndReplace))
        editMenu.addItem(item("查找下一个", #selector(MainWindowController.findNextMatch(_:)), .findNext))
        editMenu.addItem(item("查找上一个", #selector(MainWindowController.findPreviousMatch(_:)), .findPrevious))

        // 格式菜单
        let formatItem = NSMenuItem()
        mainMenu.addItem(formatItem)
        let formatMenu = NSMenu(title: "格式")
        formatItem.submenu = formatMenu
        formatMenu.addItem(item("格式化 JSON", #selector(MainWindowController.formatJSON(_:)), .formatJSON))
        formatMenu.addItem(item("校验 JSON", #selector(MainWindowController.validateJSON(_:)), .validateJSON))
        formatMenu.addItem(.separator())
        // 这两个 action 由编辑器容器自己实现（响应链在窗口控制器之前），
        // 只对「选了一段 JSON/XML」有意义，右键菜单里也有同样的入口
        formatMenu.addItem(item("格式化选中片段",
                                #selector(EditorContainerView.formatSelection(_:)),
                                .formatSelection))
        formatMenu.addItem(item("格式化整篇报文",
                                #selector(EditorContainerView.formatWholeDocument(_:)),
                                .formatWholeDocument))

        // 视图菜单
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        viewMenu.addItem(item("下一个标签", #selector(MainWindowController.selectNextTab(_:)), .nextTab))
        viewMenu.addItem(item("上一个标签", #selector(MainWindowController.selectPreviousTab(_:)), .previousTab))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("自动换行", #selector(MainWindowController.toggleWrapLines(_:))))
        viewMenu.addItem(item("高亮当前行", #selector(MainWindowController.toggleHighlightCurrentLine(_:))))
        viewMenu.addItem(.separator())
        // 由对比窗口实现：主窗口是 key 时响应链上没有它，菜单项自动置灰
        viewMenu.addItem(item("下一处差异", #selector(CompareWindowController.nextDifference(_:)), .nextDifference))
        viewMenu.addItem(item("上一处差异", #selector(CompareWindowController.previousDifference(_:)), .previousDifference))

        // 窗口菜单
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(plainItem("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("缩放", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
        dumpKeyEquivalentsIfNeeded(mainMenu)
    }

    /// 无头验证：`SWIFTNOTE_MENU_DEBUG=1` 时把菜单实际键位打到日志
    private static func dumpKeyEquivalentsIfNeeded(_ menu: NSMenu) {
        guard ProcessInfo.processInfo.environment["SWIFTNOTE_MENU_DEBUG"] != nil else { return }
        var lines: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu, !item.isSeparatorItem {
                    walk(submenu)
                } else if !item.keyEquivalent.isEmpty {
                    let mask = item.keyEquivalentModifierMask
                    var flags: [String] = []
                    if mask.contains(.control) { flags.append("ctrl") }
                    if mask.contains(.option) { flags.append("opt") }
                    if mask.contains(.shift) { flags.append("shift") }
                    if mask.contains(.command) { flags.append("cmd") }
                    lines.append("\(item.title)=\(item.keyEquivalent)[\(flags.joined(separator: "+"))]")
                }
            }
        }
        walk(menu)
        AppLogger.info("菜单键位：\(lines.joined(separator: " "))")
        // 上面的清单只收有键位的项；「格式」菜单里几个动作默认无键位，单独列一遍
        if let formatMenu = menu.items.first(where: { $0.submenu?.title == "格式" })?.submenu {
            let titles = formatMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            AppLogger.info("格式菜单：\(titles.joined(separator: " | "))")
        }
        logRecentMenuIfNeeded()
    }

    /// 无头验证：手动催一次「最近打开」子菜单的 `menuNeedsUpdate` 并把结果打出来
    /// （菜单是打开时才现建的；启动阶段会话还没恢复，所以要在恢复之后再调一次）
    static func logRecentMenuIfNeeded() {
        guard ProcessInfo.processInfo.environment["SWIFTNOTE_MENU_DEBUG"] != nil else { return }
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.items.first(where: { $0.submenu?.title == "文件" })?.submenu,
              let recent = fileMenu.items.first(where: { $0.title == "最近打开" })?.submenu else { return }
        recent.delegate?.menuNeedsUpdate?(recent)
        let titles = recent.items.filter { !$0.isSeparatorItem }.map(\.title)
        AppLogger.info("最近打开菜单（\(titles.count) 项）：\(titles.joined(separator: " | "))")
    }

    /// 快捷键变更后重建菜单（`install()` 可重复调用）
    static func rebuildIfShortcutsChanged(_ changedKeys: [String]) {
        guard AppSettings.containsShortcutChange(changedKeys) else { return }
        install()
    }

    /// 可自定义动作的菜单项：键位来自设置，未设置就留空
    private static func item(_ title: String, _ action: Selector,
                             _ shortcut: ShortcutAction) -> NSMenuItem {
        let combo = AppSettings.shared.shortcut(shortcut)
        let menuItem = NSMenuItem(title: title, action: action,
                                  keyEquivalent: combo?.menuKeyEquivalent ?? "")
        if let combo { menuItem.keyEquivalentModifierMask = combo.nsModifiers }
        return menuItem
    }

    /// 固定键位（或没有快捷键）的系统动作
    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    private static func plainItem(_ title: String, _ action: Selector, _ keyEquivalent: String = "",
                                  modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty {
            menuItem.keyEquivalentModifierMask = modifiers
        }
        return menuItem
    }
}

/// 「最近打开」子菜单的内容来源
///
/// 菜单项在打开时才需要，所以走 `menuNeedsUpdate` 现建现用——
/// 这样不需要在每次打开/保存文件时去同步菜单，也不会漏掉「文件已被删」这种状态。
final class RecentFilesMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentFilesMenuDelegate()

    /// 超过这个条数就折起来走「快速打开」面板
    private static let inlineLimit = 10

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paths = EditorStore.shared.recentFiles.prefix(Self.inlineLimit)
        guard !paths.isEmpty else {
            let empty = NSMenuItem(title: "（暂无记录）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (index, path) in paths.enumerated() {
            let exists = FileManager.default.fileExists(atPath: path)
            let name = (path as NSString).lastPathComponent
            let dir = QuickOpenItem(path: path, isOpen: false, exists: exists).directory
            let title = "\(index + 1)  \(name)  —  \(dir)"
            let menuItem = NSMenuItem(title: title,
                                      action: #selector(MainWindowController.openRecentDocument(_:)),
                                      keyEquivalent: "")
            menuItem.representedObject = path
            menuItem.toolTip = path
            if !exists {
                menuItem.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
            }
            menu.addItem(menuItem)
        }
        if EditorStore.shared.recentFiles.count > Self.inlineLimit {
            let more = NSMenuItem(title: "全部最近文件…",
                                  action: #selector(MainWindowController.quickOpenRecent(_:)),
                                  keyEquivalent: "")
            menu.addItem(more)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "清除最近记录",
                                action: #selector(MainWindowController.clearRecentFiles(_:)),
                                keyEquivalent: ""))
    }
}

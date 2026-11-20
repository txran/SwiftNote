import AppKit
import SwiftNoteKit

/// 主窗口：标签栏（顶）+ 编辑区（中）+ 状态栏（底）
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let store: EditorStore
    private let tabBar = TabBarView()
    private let editorHost = NSView()
    private let statusBar = StatusBarView()
    private let searchPanel = SearchPanelView()
    private var mountedEditor: EditorContainerView?
    /// 大文件纯文本面板（与 mountedEditor 互斥：同一时刻只有一个挂在 editorHost 上）
    private var mountedPlainView: PlainTextPaneView?
    private var plainDocument: EditorDocument?
    /// 大文件行索引缓存（只留最近一份：行索引本身约等于文件大小的一半）
    private var plainIndexCache: [UUID: LineIndex] = [:]
    /// 上次生效的只读阈值：设置变更通知里据此判断「是不是这一项改了」
    private var lastThresholdMB = AppSettings.shared.largeFileThresholdMB
    private var plainIndexBuilding: Set<UUID> = []
    /// 对比窗口可能同时开多个（A↔B、C↔D），各自独立
    private var compareWindows: [CompareWindowController] = []
    /// 快速打开面板（⌘⇧O），首次使用时才建窗口
    private lazy var quickOpen = QuickOpenWindowController()

    init(store: EditorStore = .shared) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "SwiftNote"
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("SwiftNoteMainWindow")
        super.init(window: window)
        window.delegate = self
        buildContent()
        observeNotifications()
        layoutContent()
        refreshAll()
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 组装

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        tabBar.maxTabRows = AppSettings.shared.maxTabRows
        tabBar.minTabWidth = AppSettings.shared.minTabWidth
        tabBar.onSelect = { [weak self] index in self?.store.activate(index: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onOrderChanged = { [weak self] ids in self?.store.reorder(by: ids) }
        tabBar.onHeightChanged = { [weak self] _ in self?.layoutContent() }
        tabBar.onNewTab = { [weak self] in self?.store.newDocument() }
        content.addSubview(tabBar)

        editorHost.wantsLayer = true
        content.addSubview(editorHost)

        searchPanel.isHidden = true
        searchPanel.onHeightChanged = { [weak self] in self?.layoutContent() }
        content.addSubview(searchPanel)

        statusBar.onEncodingClick = { [weak self] button in self?.showEncodingMenu(from: button) }
        statusBar.onLineEndingClick = { [weak self] button in self?.showLineEndingMenu(from: button) }
        statusBar.onSyntaxClick = { [weak self] button in self?.showSyntaxMenu(from: button) }
        statusBar.onWrapToggle = { [weak self] _ in self?.toggleWrapLines(nil) }
        content.addSubview(statusBar)
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onDocumentsChanged),
                           name: .swiftNoteDocumentsChanged, object: nil)
        center.addObserver(self, selector: #selector(onActiveDocumentChanged),
                           name: .swiftNoteActiveDocumentChanged, object: nil)
        center.addObserver(self, selector: #selector(onDocumentStateChanged),
                           name: .swiftNoteDocumentStateChanged, object: nil)
        center.addObserver(self, selector: #selector(onCursorMoved(_:)),
                           name: .swiftNoteCursorMoved, object: nil)
        center.addObserver(self, selector: #selector(onValidationChanged(_:)),
                           name: .swiftNoteValidationChanged, object: nil)
        center.addObserver(self, selector: #selector(onSettingsChanged),
                           name: AppSettings.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(onDocumentContentLoaded(_:)),
                           name: .swiftNoteDocumentContentLoaded, object: nil)
        // FR-11 第二重保险：窗口回到前台时批量校验 mtime
        center.addObserver(self, selector: #selector(onAppBecameActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 通知响应

    @objc private func onDocumentsChanged() {
        refreshTabs()
    }

    @objc private func onActiveDocumentChanged() {
        // 鼠标点标签栏时 TabBarView 自己会更新选中态，但走菜单 / ⌘⇧[⌘⇧] /
        // 打开文件切换时只发这个通知，不刷一次标签栏就会「内容换了、选中还停在旧标签」
        refreshTabs()
        mountActiveEditor()
        statusBar.setValidationMessage(nil)
        refreshStatus()
        updateTitle()
    }

    @objc private func onDocumentStateChanged() {
        refreshTabs()
    }

    @objc private func onCursorMoved(_ note: Notification) {
        guard let line = note.userInfo?["line"] as? Int,
              let column = note.userInfo?["column"] as? Int else { return }
        statusBar.updatePosition(line: line, column: column)
    }

    @objc private func onValidationChanged(_ note: Notification) {
        let isError = note.userInfo?["isError"] as? Bool ?? true
        statusBar.setValidationMessage(note.userInfo?["message"] as? String, isError: isError)
    }

    @objc private func onAppBecameActive() {
        AppLogger.info("窗口激活 → 校验外部修改（\(store.documents.count) 个文档）")
        store.verifyExternalChanges()
        // 不走 refreshAll：那会重新挂载编辑区并抢焦点，
        // 用户切出去再切回来（比如在搜索框里找东西）时不该跳焦点
        refreshTabs()
        refreshStatus()
    }

    /// 会话恢复的内容是首帧之后异步到的；大文件面板的行索引此前可能按空内容建过，需要重建
    @objc private func onDocumentContentLoaded(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? UUID,
              store.documents.contains(where: { $0.id == id }) else { return }
        if plainIndexCache[id] != nil {
            plainIndexCache.removeValue(forKey: id)
        }
        plainIndexBuilding.remove(id)
        if plainDocument?.id == id {
            mountActiveEditor()
        }
    }

    @objc private func onSettingsChanged() {
        tabBar.maxTabRows = AppSettings.shared.maxTabRows
        tabBar.minTabWidth = AppSettings.shared.minTabWidth
        mountedEditor?.tabInsertsSpaces = AppSettings.shared.tabInsertsSpaces
        // 换行开关 / 当前行高亮：立即生效，不重启
        mountedEditor?.applyDisplaySettings()
        mountedPlainView?.applyWrap(AppSettings.shared.wrapLines)
        // 状态栏的换行指示跟着走（菜单、状态栏按钮、设置三处入口都汇到这一条通知）
        statusBar.updateWrapLines(AppSettings.shared.wrapLines)
        applyLargeFileThresholdIfNeeded()
        layoutContent()
    }

    /// 只读阈值改了：对已打开文档重新评估（否则得关掉重开才生效）
    private func applyLargeFileThresholdIfNeeded() {
        let threshold = AppSettings.shared.largeFileThresholdMB
        guard threshold != lastThresholdMB else { return }
        lastThresholdMB = threshold

        let result = store.reapplyLargeFilePolicy()
        // 恢复可编辑的文档要从纯文本面板换回 TextKit，行索引缓存先丢掉（大文件索引很占内存）
        for doc in result.promoted {
            plainIndexCache.removeValue(forKey: doc.id)
        }
        refreshTabs()
        mountActiveEditor()
        refreshStatus()

        var parts: [String] = []
        if !result.demoted.isEmpty { parts.append("\(result.demoted.count) 个改为只读") }
        if !result.promoted.isEmpty { parts.append("\(result.promoted.count) 个恢复可编辑") }
        if !result.skippedDirty.isEmpty { parts.append("\(result.skippedDirty.count) 个有未保存修改已跳过") }
        statusBar.setValidationMessage(parts.isEmpty
            ? "只读阈值已改为 \(threshold) MB"
            : "只读阈值 \(threshold) MB · " + parts.joined(separator: "，"))
    }

    // MARK: - 显示开关（FR-10）

    @objc func toggleWrapLines(_ sender: Any?) {
        AppSettings.shared.wrapLines.toggle()
    }

    @objc func toggleHighlightCurrentLine(_ sender: Any?) {
        AppSettings.shared.highlightCurrentLine.toggle()
        mountedEditor?.refreshCurrentLineHighlight()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleWrapLines(_:)):
            menuItem.state = AppSettings.shared.wrapLines ? .on : .off
            return store.activeDocument != nil
        case #selector(toggleHighlightCurrentLine(_:)):
            menuItem.state = AppSettings.shared.highlightCurrentLine ? .on : .off
            return store.activeDocument != nil
        case #selector(quickOpenRecent(_:)):
            return !store.recentFiles.isEmpty || !store.documents.isEmpty
        case #selector(clearRecentFiles(_:)):
            return !store.recentFiles.isEmpty
        default:
            return true
        }
    }

    // MARK: - 刷新

    func refreshAll() {
        refreshTabs()
        mountActiveEditor()
        refreshStatus()
        updateTitle()
    }

    /// 状态栏：外部提示优先于校验消息与只读标记
    private func refreshStatus() {
        let doc = store.activeDocument
        statusBar.update(document: doc)
        if let doc, doc.isFileMissing {
            statusBar.setExternalNotice("文件已在外部被删除或移动 · 内容仅在内存中，请另存为")
        } else if let doc, doc.hasExternalConflict {
            statusBar.setExternalNotice("磁盘文件已被外部修改 · 当前为本地版本，保存将覆盖磁盘")
        } else {
            statusBar.setExternalNotice(nil)
        }
    }

    private func refreshTabs() {
        // 关掉的标签不再占着行索引（一份索引约等于文件大小的一半）
        if !plainIndexCache.isEmpty {
            plainIndexCache = plainIndexCache.filter { id, _ in
                store.documents.contains { $0.id == id }
            }
        }
        let items = store.documents.map {
            TabBarItem(id: $0.id, title: $0.displayName, isDirty: $0.isDirty,
                       isReadOnly: $0.isReadOnly, hasConflict: $0.hasExternalConflict,
                       path: $0.fileURL?.path)
        }
        tabBar.maxTabRows = AppSettings.shared.maxTabRows
        tabBar.setItems(items, activeIndex: store.activeIndex)
        layoutContent()
        updateTitle()
    }

    private func mountActiveEditor() {
        guard let doc = store.activeDocument else {
            mountedEditor?.removeFromSuperview()
            mountedEditor = nil
            unmountPlainEditor()
            return
        }
        // 大文件走纯文本只读面板：不进 TextKit，打开耗时与内存都不随文件增长
        if doc.prefersPlainText {
            mountPlainEditor(doc)
            return
        }
        unmountPlainEditor()

        let editor = store.editor(for: doc)
        editor.onSearchStateInvalidated = { [weak self] in self?.searchPanel.refreshAfterTextEdit() }
        if mountedEditor !== editor {
            // 切走前把输入段收口，撤销步按「一段输入」切分
            mountedEditor?.breakUndoCoalescing()
            mountedEditor?.removeFromSuperview()
            editor.frame = editorHost.bounds
            editor.autoresizingMask = [.width, .height]
            editorHost.addSubview(editor)
            mountedEditor = editor
            searchPanel.editor = editor
        }
        editor.frame = editorHost.bounds
        editor.applyDisplaySettings()
        editor.focusEditor()
        editor.reportCursorPosition()
        // 挂载这一帧里 contentView.bounds 可能还是 0×0，带子会按零宽视口算位置；
        // 等这轮布局结束再补一次，保证色带与光标所在行对齐
        DispatchQueue.main.async { [weak editor] in
            editor?.refreshCurrentLineHighlight()
        }
    }

    // MARK: - 大文件纯文本面板

    /// 大文件模式：只读、无高亮、无折行、无搜索；滚动位置随文档保存
    private func mountPlainEditor(_ doc: EditorDocument) {
        if let previous = plainDocument, let view = mountedPlainView, previous.id != doc.id {
            previous.scrollPosition = view.verticalOffset
        }
        mountedEditor?.removeFromSuperview()
        mountedEditor = nil
        searchPanel.editor = nil

        let view: PlainTextPaneView
        if let existing = mountedPlainView {
            view = existing
        } else {
            view = PlainTextPaneView()
            view.onScrolled = { [weak self] in self?.refreshPlainPosition() }
            view.onSelectionChanged = { [weak self] in self?.refreshPlainPosition() }
            mountedPlainView = view
            editorHost.addSubview(view)
        }
        view.frame = editorHost.bounds
        view.autoresizingMask = [.width, .height]
        plainDocument = doc
        // 面板按「视觉段」自行排版，折行开关同样生效（见 ADR D-46）
        view.applyWrap(AppSettings.shared.wrapLines)

        if let cached = plainIndexCache[doc.id] {
            view.setContent(index: cached)
            restorePlainScroll(doc, in: view)
        } else {
            // 先给个空壳，索引在后台建（200MB 的 O(n) 扫描不能压主线程）
            view.setContent(text: "")
            buildPlainIndex(for: doc, in: view)
        }
        view.focusCanvas()
        statusBar.updatePosition(line: 0, column: 0)
        refreshStatus()
    }

    private func unmountPlainEditor() {
        guard let view = mountedPlainView else { return }
        if let doc = plainDocument {
            doc.scrollPosition = view.verticalOffset
        }
        view.removeFromSuperview()
        mountedPlainView = nil
        plainDocument = nil
    }

    private func restorePlainScroll(_ doc: EditorDocument, in view: PlainTextPaneView) {
        guard doc.scrollPosition > 0 else { return }
        view.scroll(toLinePosition: Double(doc.scrollPosition) / Double(max(view.lineHeight, 1)))
        doc.scrollPosition = 0   // scroll 只生效一次，避免之后切回来又被旧值顶走
    }

    private func buildPlainIndex(for doc: EditorDocument, in view: PlainTextPaneView) {
        guard !plainIndexBuilding.contains(doc.id) else { return }
        plainIndexBuilding.insert(doc.id)
        let id = doc.id
        let text = doc.cachedText
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let index = LineIndex(text: text)
            DispatchQueue.main.async {
                guard let self else { return }
                self.plainIndexBuilding.remove(id)
                // 只保留一份索引：多个大文件时内存换时间，切回来重建（后台）
                self.plainIndexCache = [id: index]
                AppLogger.info(String(format: "大文件索引 %.2fs（%d 行）",
                                      Date().timeIntervalSince(started), index.count))
                guard self.store.activeDocument?.id == id else { return }
                view.setContent(index: index)
                self.restorePlainScroll(doc, in: view)
                view.focusCanvas()
            }
        }
    }

    private func refreshPlainPosition() {
        guard let view = mountedPlainView else { return }
        if let caret = view.caretPosition {
            statusBar.updatePosition(line: caret.line, column: caret.column)
        } else {
            statusBar.updatePosition(line: 0, column: 0)
        }
    }

    private func updateTitle() {
        guard let doc = store.activeDocument else {
            window?.title = "SwiftNote"
            window?.representedURL = nil
            return
        }
        window?.title = doc.isDirty ? "● \(doc.displayName) — SwiftNote" : "\(doc.displayName) — SwiftNote"
        window?.representedURL = doc.fileURL
    }

    // MARK: - 布局

    private func layoutContent() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        let tabHeight = tabBar.desiredHeight
        let searchHeight = searchPanel.isHidden ? 0 : searchPanel.desiredHeight
        tabBar.frame = NSRect(x: 0, y: bounds.height - tabHeight, width: bounds.width, height: tabHeight)
        searchPanel.frame = NSRect(x: 0, y: bounds.height - tabHeight - searchHeight,
                                   width: bounds.width, height: searchHeight)
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: StatusBarView.height)
        editorHost.frame = NSRect(x: 0, y: StatusBarView.height,
                                  width: bounds.width,
                                  height: max(0, bounds.height - tabHeight - searchHeight - StatusBarView.height))
        mountedEditor?.frame = editorHost.bounds
        mountedPlainView?.frame = editorHost.bounds
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }

    /// 无头验证辅助：仅在设置了 SWIFTNOTE_SNAPSHOT 时生效，用于截图核对搜索面板状态
    func applySnapshotAutomation() {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTNOTE_SNAPSHOT"] != nil else { return }
        if let settingsHook = env["SWIFTNOTE_SETTINGS"] {
            let controller = SettingsWindowController.shared
            controller.showSettings(nil)
            // SWIFTNOTE_SETTINGS=shortcuts 直接切到快捷键页（无头截图用）
            if settingsHook == "shortcuts" { controller.selectPane(.shortcuts) }
        }
        // 双屏对比：SWIFTNOTE_COMPARE="左路径|右路径"，可选 SWIFTNOTE_COMPARE_EDIT/LINE 模拟编辑
        if let spec = env["SWIFTNOTE_COMPARE"] {
            let parts = spec.split(separator: "|").map(String.init)
            if parts.count == 2 {
                let compare = openCompareWindow(left: URL(fileURLWithPath: parts[0]),
                                                right: URL(fileURLWithPath: parts[1]))
                if let scrollLine = env["SWIFTNOTE_COMPARE_SCROLL"], let line = Int(scrollLine) {
                    // 大文件装载 + diff 需要几秒，滚动钩子必须晚于此
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak compare] in
                        compare?.simulateScrollLeft(toLine: line)
                        if let lines = compare?.topLinesForTesting() {
                            AppLogger.info("COMPARE 同步滚动：左顶行 \(lines.left)，右顶行 \(lines.right)")
                        }
                    }
                }
                // 差异导航：SWIFTNOTE_COMPARE_NAV="next,next,prev"
                if let nav = env["SWIFTNOTE_COMPARE_NAV"] {
                    let steps = nav.split(separator: ",").map(String.init)
                    for (i, step) in steps.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6 + Double(i) * 0.7) { [weak compare] in
                            guard let compare else { return }
                            if step == "next" { compare.nextDifference(nil) } else { compare.previousDifference(nil) }
                            AppLogger.info("COMPARE NAV \(step)：\(compare.navigationSummaryForTesting())")
                        }
                    }
                }
                if let edit = env["SWIFTNOTE_COMPARE_EDIT"] {
                    let line = Int(env["SWIFTNOTE_COMPARE_LINE"] ?? "2") ?? 2
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak compare] in
                        AppLogger.info("COMPARE 模拟编辑第 \(line) 行")
                        compare?.simulateEditLeft(line: line, text: edit)
                    }
                }
            }
        }
        // 换行符：SWIFTNOTE_EOL=lf|crlf|cr（切完可加 SWIFTNOTE_EOL_SAVE=1 落盘核对字节）
        if let raw = env["SWIFTNOTE_EOL"], let ending = LineEnding(rawValue: raw.uppercased()) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let doc = self.store.activeDocument else { return }
                let before = doc.lineEnding
                self.switchLineEnding(to: ending)
                AppLogger.info("EOL 切换：\(before.displayName) → \(doc.lineEnding.displayName) 脏=\(doc.isDirty)")
                if env["SWIFTNOTE_EOL_SAVE"] != nil {
                    let ok = self.store.save(document: doc)
                    AppLogger.info("EOL 保存：\(ok ? "成功" : "失败") \(doc.fileURL?.path ?? "未命名") 脏=\(doc.isDirty)")
                }
            }
        }
        // 右上角「＋」：SWIFTNOTE_NEW_TAB=1（先打印按钮位置，再模拟点击，核对文档数变化）
        if env["SWIFTNOTE_NEW_TAB"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                let before = self.store.documents.count
                AppLogger.info("NEW TAB 按钮：\(self.tabBar.newTabButtonSummary()) · 文档 \(before) 个")
                self.tabBar.simulateNewTabClick()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    AppLogger.info("NEW TAB 点击后：文档 \(self.store.documents.count) 个"
                        + "（之前 \(before)）· 当前=\(self.store.activeDocument?.displayName ?? "nil")")
                }
            }
        }
        // 右下角自动换行开关：SWIFTNOTE_WRAP_TOGGLE=1（切换一次，打印按钮标题与编辑器实际状态）
        if env["SWIFTNOTE_WRAP_TOGGLE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                AppLogger.info("WRAP 之前：\(self.statusBar.wrapSummary()) · 设置=\(AppSettings.shared.wrapLines)")
                self.toggleWrapLines(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    AppLogger.info("WRAP 之后：\(self.statusBar.wrapSummary()) · 设置=\(AppSettings.shared.wrapLines)"
                        + " · 编辑器 wrapLines=\(self.mountedEditor?.wrapsLines ?? false)")
                }
            }
        }
        // 大文件面板滚动到指定行（1 基，验证折行后顶行起算与命中一致）：SWIFTNOTE_PLAIN_SCROLL=5000
        if let spec = env["SWIFTNOTE_PLAIN_SCROLL"], let line = Int(spec) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let view = self.mountedPlainView else {
                    AppLogger.info("PLAIN SCROLL：没有大文件面板")
                    return
                }
                view.simulateUserScroll(toLine: line)
                AppLogger.info("PLAIN SCROLL 目标行\(line) 实际顶行=\(view.topLineForTesting)"
                    + " 折行=\(view.wrapsLines)")
                AppLogger.info("PLAIN 滚动后命中：\(view.hitTestSummary())")
            }
        }
        // 只读大文件面板的滚动条：SWIFTNOTE_SCROLLER_DEBUG=1
        // 画布曾把系统滚动条整条盖住（滚动时也看不见），这里核对层级与几何
        if env["SWIFTNOTE_SCROLLER_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                if let view = self.mountedPlainView {
                    // 先打印再 flash：flash 会插入 overlay 指示器视图，命中核对会被它干扰
                    AppLogger.info("SCROLLER 面板：\(view.scrollerDiagnostics())")
                    // overlay 风格默认「滚动时显示、随后淡出」，程序化滚动不 flash，
                    // 截图前手动亮一下，否则只能靠日志判断
                    view.flashScrollers()
                }
                AppLogger.info("SCROLLER 编辑器：\(self.mountedEditor?.scrollerDiagnostics() ?? "nil")")
            }
        }
        // 滚轮滚动后滚动条是否出现：SWIFTNOTE_SCROLLER_WHEEL=1
        if env["SWIFTNOTE_SCROLLER_WHEEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let view = self?.mountedPlainView else {
                    AppLogger.info("WHEEL：没有大文件面板")
                    return
                }
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                 wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)
                guard let cg, let event = NSEvent(cgEvent: cg) else { return }
                let before = view.topLineForTesting
                view.simulateScrollWheel(event)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    AppLogger.info("WHEEL 顶行 \(before) → \(view.topLineForTesting)")
                    AppLogger.info("WHEEL 之后：\(view.scrollerDiagnostics())")
                }
            }
        }
        // 大文件只读面板的拖选：SWIFTNOTE_PLAIN_SELECT="起行,起列,止行,止列"（0 基）
        if let spec = env["SWIFTNOTE_PLAIN_SELECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let view = self.mountedPlainView else {
                    AppLogger.info("PLAIN SELECT：没有大文件面板（当前文档未走纯文本模式）")
                    return
                }
                let parts = spec.split(separator: ",").compactMap { Int($0) }
                guard parts.count == 4 else { return }
                AppLogger.info("PLAIN 行数=\(view.lineCount)")
                AppLogger.info("PLAIN 命中：\(view.hitTestSummary())")
                AppLogger.info("PLAIN 拖选：\(view.simulateDragSelection(startRow: parts[0], startColumn: parts[1], endRow: parts[2], endColumn: parts[3]))")
                AppLogger.info("PLAIN 状态栏：\(self.statusBar.wrapSummary())")
            }
        }
        // 只读文档的可选中性 / 换行开关：SWIFTNOTE_READONLY_DEBUG=1
        if env["SWIFTNOTE_READONLY_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                let doc = self.store.activeDocument
                AppLogger.info("READONLY 文档=\(doc?.displayName ?? "nil")"
                    + " 只读=\(doc?.isReadOnly ?? false) 原因=\(doc?.readOnlyReason?.displayText ?? "-")"
                    + " 体积=\(doc?.fileSizeBytes ?? 0)")
                AppLogger.info("READONLY 视图：\(self.mountedEditor?.selectionDiagnostics() ?? "nil")")
                AppLogger.info("READONLY 状态栏：\(self.statusBar.wrapSummary())")
                if env["SWIFTNOTE_WRAP_TOGGLE"] != nil {
                    self.toggleWrapLines(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self else { return }
                        AppLogger.info("READONLY 换行切换后：\(self.statusBar.wrapSummary())"
                            + " · 设置=\(AppSettings.shared.wrapLines)"
                            + " · 编辑器 wrapLines=\(self.mountedEditor?.wrapsLines ?? false)")
                    }
                }
            }
        }
        // 选区 + 右键菜单 + 格式化：SWIFTNOTE_SELECT="定位,长度"，SWIFTNOTE_FORMAT=selected|whole|tojson
        if let spec = env["SWIFTNOTE_SELECT"] {
            let parts = spec.split(separator: ",").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let editor = self.mountedEditor, parts.count == 2 else { return }
                editor.selectRange(parts[0], parts[1])
                AppLogger.info("右键菜单：\(editor.contextMenuSummary())")
                if let mode = env["SWIFTNOTE_FORMAT"] {
                    let before = editor.text.count
                    if mode == "whole" {
                        editor.formatWholeDocument(nil)
                    } else if mode == "tojson" {
                        // 选中 → JSON（XML 报文结构转换 / JSON 重排）
                        editor.convertSelectionToJSON(nil)
                    } else {
                        editor.formatSelection(nil)
                    }
                    AppLogger.info("格式化(\(mode))：\(before) → \(editor.text.count) 字符")
                    if mode == "tojson" {
                        AppLogger.info("转换为 JSON 的结果：\(editor.selectedTextPreview(400))")
                        AppLogger.info("文档前 80 字符："
                            + "\(String(editor.text.prefix(80)).replacingOccurrences(of: "\n", with: "⏎"))")
                    }
                    // 格式化必须是「一步撤销」：格式化后立刻撤，长度应回到 before
                    if env["SWIFTNOTE_FORMAT_UNDO"] != nil {
                        editor.undo(nil)
                        let canUndo = editor.text.count
                        AppLogger.info("格式化撤销：长度 \(canUndo)（原 \(before)）"
                                       + (canUndo == before ? " ✅ 一步回退" : " ❌ 未回到原状"))
                    }
                }
            }
        }
        // 切标签（验证当前行高亮/行列号是否跟随）：SWIFTNOTE_TAB_SWITCH=下标,下标,…
        // 序列每 1.2s 切一个，用来模拟来回点击标签
        if let raw = env["SWIFTNOTE_TAB_SWITCH"] {
            let indices = raw.split(separator: ",").compactMap { Int($0) }
            for (step, index) in indices.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(step) * 1.2) { [weak self] in
                    guard let self else { return }
                    self.store.activate(index: index)
                    let doc = self.store.activeDocument
                    AppLogger.info("TAB SWITCH → 下标 \(index) 当前=\(doc?.displayName ?? "nil")"
                        + " 带=\(self.mountedEditor?.currentLineBandSummary() ?? "nil")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self else { return }
                        AppLogger.info("TAB SWITCH+0.8s → 带="
                            + "\(self.mountedEditor?.currentLineBandSummary() ?? "nil")")
                    }
                }
            }
        }
        // 标签右键菜单：SWIFTNOTE_TAB_MENU="下标[,copy|reveal]"（不给动作＝只打印菜单项状态）
        if let spec = env["SWIFTNOTE_TAB_MENU"] {
            let parts = spec.split(separator: ",").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let index = Int(parts[0]) else { return }
                AppLogger.info("TAB MENU[\(index)]：\(self.tabBar.contextMenuSummary(at: index))"
                    + "（文档 \(self.store.documents.count) 个：\(self.store.documents.map { $0.displayName }.joined(separator: ",")))")
                guard parts.count > 1 else { return }
                self.tabBar.triggerContextAction(parts[1], at: index)
                if parts[1] == "copy" {
                    let copied = NSPasteboard.general.string(forType: .string) ?? "nil"
                    AppLogger.info("TAB MENU 剪贴板：\(copied)")
                } else {
                    AppLogger.info("TAB MENU 已请求在访达中显示")
                }
            }
        }
        // 编码：SWIFTNOTE_ENCODING=convert:gbk | reload:utf8 | bom:toggle
        // 可加 SWIFTNOTE_ENCODING_SAVE=1 落盘核对字节（od -c 看有没有 BOM / 是不是 GBK）
        if let spec = env["SWIFTNOTE_ENCODING"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let doc = self.store.activeDocument else { return }
                let parts = spec.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
                func parseEncoding(_ s: String) -> FileEncoding? {
                    switch s {
                    case "gbk", "gb18030": return .gbk
                    case "utf8", "utf-8": return .utf8
                    default: return nil
                    }
                }
                let action = parts.first ?? ""
                if action == "bom", parts.count == 1 || parts.last == "toggle" {
                    self.toggleEncodingBOM()
                    AppLogger.info("ENCODING BOM → hasBOM=\(doc.hasBOM) 脏=\(doc.isDirty)")
                } else if let target = parts.last.flatMap(parseEncoding) {
                    let before = "\(doc.encoding.displayName) BOM=\(doc.hasBOM)"
                    if action == "reload" {
                        self.reloadWithEncoding(target)
                    } else {
                        self.convertEncoding(to: target)
                    }
                    AppLogger.info("ENCODING \(action) \(before) → \(doc.encoding.displayName) BOM=\(doc.hasBOM) 脏=\(doc.isDirty)")
                }
                if env["SWIFTNOTE_ENCODING_SAVE"] != nil {
                    let ok = self.store.save(document: doc)
                    AppLogger.info("ENCODING 保存：\(ok ? "成功" : "失败") \(doc.fileURL?.path ?? "未命名") 脏=\(doc.isDirty)")
                }
            }
        }
        // 只读阈值：SWIFTNOTE_THRESHOLD=<MB>（运行中改，验证「改了立即生效」）
        if let raw = env["SWIFTNOTE_THRESHOLD"], let mb = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, let doc = self.store.activeDocument else { return }
                let sizeMB = Double(doc.fileSizeBytes) / 1024 / 1024
                AppLogger.info(String(format: "THRESHOLD 改前 %dMB｜文档 %.1fMB 只读=%d 面板=%@",
                                      AppSettings.shared.largeFileThresholdMB, sizeMB,
                                      doc.isReadOnly ? 1 : 0,
                                      self.mountedPlainView != nil ? "纯文本" : "TextKit"))
                AppSettings.shared.largeFileThresholdMB = mb
                AppLogger.info(String(format: "THRESHOLD 改后 %dMB｜文档 %.1fMB 只读=%d 面板=%@",
                                      AppSettings.shared.largeFileThresholdMB, sizeMB,
                                      doc.isReadOnly ? 1 : 0,
                                      self.mountedPlainView != nil ? "纯文本" : "TextKit"))
            }
        }
        // 快速打开面板：SWIFTNOTE_QUICK_OPEN=<查询词>（空串＝只弹面板不输入）
        if let query = env["SWIFTNOTE_QUICK_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.presentQuickOpen(query: query)
                AppLogger.info("QUICKOPEN \(self.quickOpen.debugSummary)")
                // 会话已恢复，这时再看「最近打开」子菜单才是真实内容
                MainMenuBuilder.logRecentMenuIfNeeded()
            }
            // 回车打开：等面板把候选与首行选中摆好再触发
            if env["SWIFTNOTE_QUICK_OPEN_ENTER"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    let before = self.store.documents.count
                    let selected = self.quickOpen.currentSelectionName()
                    self.quickOpen.performOpenForTesting()
                    AppLogger.info("QUICKOPEN 回车：选中「\(selected)」 文档 \(before) → "
                                   + "\(self.store.documents.count) 面板可见=\(self.quickOpen.isVisible)")
                }
            }
        }
        // 中键关闭标签：合成真实中键事件派发给指定标签（验证 otherMouseDown 分支）
        if let spec = env["SWIFTNOTE_TAB_MIDDLE"], let index = Int(spec) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let before = self.store.documents.count
                let dispatched = self.tabBar.simulateMiddleClick(index: index)
                AppLogger.info("TAB 中键：index=\(index) 派发=\(dispatched) 文档 \(before) → \(self.store.documents.count)")
            }
        }
        // 自写防误报验证：等异步加载完成后强制保存一次，
        // 日志里不应出现「外部修改」（保存会换 inode 并触发自己的 vnode 事件）
        if env["SWIFTNOTE_AUTOSAVE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self,
                      let doc = self.store.activeDocument, doc.fileURL != nil else {
                    AppLogger.warn("AUTOSAVE 跳过：文档尚未落盘")
                    return
                }
                AppLogger.info("AUTOSAVE 触发：保存 \(doc.displayName)")
                self.store.save(document: doc)
            }
        }
        // 撤销栈诊断（FR-10）：打印每个编辑器实际使用的 NSUndoManager 是否就是窗口那一个。
        // 多标签共用一个窗口，若共用一条栈，切标签后按 ⌘Z 会撤掉别的标签的编辑。
        if env["SWIFTNOTE_UNDO_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self, let window = self.window else { return }
                // 无头运行时窗口不是 key，NSApp.target(forAction:) 会直接返回 nil；
                // 这里手动沿响应链找第一个响应该动作的对象，等价于菜单的 target 解析
                func responderTarget(_ selector: Selector) -> NSResponder? {
                    var current: NSResponder? = window.firstResponder
                    while let responder = current {
                        if responder.responds(to: selector) { return responder }
                        current = responder.nextResponder
                    }
                    return nil
                }
                func dispatch(_ selector: Selector) -> Bool {
                    guard let target = responderTarget(selector) else { return false }
                    return NSApp.sendAction(selector, to: target, from: nil)
                }
                let windowUndo = window.undoManager
                let undoSelector = Selector(("undo:"))
                let targetClass = NSApp.target(forAction: undoSelector, to: nil, from: nil)
                    .map { String(describing: type(of: $0)) } ?? "nil"
                let firstTextView = window.firstResponder as? NSTextView
                AppLogger.info("UNDO 派发：key=\(self.window?.isKeyWindow ?? false) 首响应=\(String(describing: type(of: window.firstResponder as Any))) undo:目标=\(targetClass)")
                AppLogger.info("UNDO 能力：textView.responds=\(firstTextView?.responds(to: undoSelector) ?? false) undoManager.responds=\(firstTextView?.undoManager?.responds(to: undoSelector) ?? false) window.responds=\(window.responds(to: undoSelector)) app.responds=\(NSApp.responds(to: undoSelector))")
                func id(_ m: UndoManager?) -> String { m.map { "\(ObjectIdentifier($0))" } ?? "nil" }
                for doc in self.store.documents {
                    guard let editor = self.store.editors[doc.id] else {
                        AppLogger.info("UNDO 栈：\(doc.displayName) 编辑器未创建")
                        continue
                    }
                    let mgr = editor.textView.undoManager
                    AppLogger.info("UNDO 栈：\(doc.displayName) mgr=\(id(mgr)) window=\(id(windowUndo)) 同一=\(mgr === windowUndo)")
                }
                // 连打合并：逐字敲（每次一个 runloop pass），然后只按一次 ⌘Z，看退回几个字
                if let type = env["SWIFTNOTE_UNDO_TYPE"], let editor = self.mountedEditor {
                    let chars = Array(type)
                    let gap = Double(env["SWIFTNOTE_UNDO_GAP"] ?? "0.3") ?? 0.3
                    for (i, ch) in chars.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(i + 1)) { [weak editor] in
                            guard let view = editor?.textView else { return }
                            view.insertText(String(ch), replacementRange: view.selectedRange())
                            AppLogger.info("UNDO 连打：第 \(i + 1) 字 len=\(view.string.utf16.count) 可编辑=\(view.isEditable) 首响应=\(view.window?.firstResponder === view)")
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(chars.count + 2)) { [weak self] in
                        guard let editor = self?.mountedEditor else { return }
                        func head(_ text: String) -> String {
                            String(text.prefix(16)).replacingOccurrences(of: "\n", with: "⏎")
                        }
                        let before = head(editor.text)
                        let lengthBefore = editor.textLength
                        let handled = dispatch(Selector(("undo:")))
                        AppLogger.info("UNDO 连打：打 \(chars.count) 字后一次 ⌘Z（派发=\(handled)）len \(lengthBefore)→\(editor.textLength) [\(before)] → [\(head(editor.text))] 仍可撤销=\(editor.textView.undoManager?.canUndo ?? false)")
                    }
                }
                guard let edit = env["SWIFTNOTE_UNDO_EDIT"],
                      let target = self.store.activeDocument,
                      let targetEditor = self.store.editors[target.id] else { return }
                let targetManager = targetEditor.textView.undoManager
                targetEditor.textView.insertText(edit, replacementRange: NSRange(location: 0, length: 0))
                AppLogger.info("UNDO 编辑：\(target.displayName) 插入 \(edit.count) 字 canUndo=\(targetManager?.canUndo ?? false)")
                guard let other = self.store.documents.firstIndex(where: { $0.id != target.id }) else { return }
                self.store.activate(index: other)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let visible = self.store.activeDocument else { return }
                    func head(_ text: String) -> String {
                        String(text.prefix(12)).replacingOccurrences(of: "\n", with: "⏎")
                    }
                    let visibleEditor = self.store.editor(for: visible)
                    let before = head(visibleEditor.text)
                    let editedBefore = head(targetEditor.text)
                    let visibleCanUndo = visibleEditor.textView.undoManager?.canUndo ?? false
                    // 走真实派发路径（菜单项 undo: 沿响应链找 target）
                    let handled = dispatch(Selector(("undo:")))
                    AppLogger.info("UNDO 跨标签：可见=\(visible.displayName) canUndo=\(visibleCanUndo) 派发=\(handled) 可见[\(before)]→[\(head(visibleEditor.text))] 被编辑标签[\(editedBefore)]→[\(head(targetEditor.text))]")
                }
            }
        }
        // FR-10 GWT 验证：敲字 → 保存 → 再敲字 → ⌘Z 只退保存之后的那一步。
        // 必须用真实按键事件：直接调 insertText 不经过 NSTextView 的输入会话，
        // 合并边界由合成调用的时机决定，测出来的结论和用户实际敲键不一致。
        if env["SWIFTNOTE_UNDO_SAVE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
                guard let self, let window = self.window, let doc = self.store.activeDocument,
                      let editor = self.mountedEditor else { return }
                func state(_ label: String) {
                    let head = String(editor.text.prefix(8)).replacingOccurrences(of: "\n", with: "⏎")
                    AppLogger.info("SAVE 撤销：\(label) len=\(editor.textLength) dirty=\(doc.isDirty) 首=[\(head)] 可撤销=\(editor.textView.undoManager?.canUndo ?? false) 组合层=\(editor.textView.undoManager?.groupingLevel ?? -1)")
                }
                var delay: Double = 0
                func step(_ body: @escaping () -> Void) {
                    delay += 0.35
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { body() }
                }
                // 无头运行时窗口不是 key，NSApp.target(forAction:) 会直接返回 nil；
                // 这里手动沿响应链找第一个响应该动作的对象，等价于菜单的 target 解析
                func responderTarget(_ selector: Selector) -> NSResponder? {
                    var current: NSResponder? = window.firstResponder
                    while let responder = current {
                        if responder.responds(to: selector) { return responder }
                        current = responder.nextResponder
                    }
                    return nil
                }
                func dispatch(_ selector: Selector) -> Bool {
                    guard let target = responderTarget(selector) else { return false }
                    return NSApp.sendAction(selector, to: target, from: nil)
                }
                // 注意：无头运行时应用不是激活态，AppKit 不处理菜单键位，
                // 所以「保存 / 撤销」用动作派发（与菜单 target 解析同一条路径）；
                // 输入用程序化插入，保证一次插入恰好是一个 undo 组。
                step {
                    self.window?.makeFirstResponder(editor.textView)
                    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
                    editor.textView.insertText("XYZ", replacementRange: NSRange(location: 0, length: 0))
                    state("① 插入 XYZ")
                }
                step {
                    let handled = dispatch(#selector(MainWindowController.saveDocument(_:)))
                    AppLogger.info("SAVE 撤销：② 保存动作 派发=\(handled) 目标=\(responderTarget(#selector(MainWindowController.saveDocument(_:))).map { String(describing: type(of: $0)) } ?? "nil")")
                    state("② 保存后")
                }
                step {
                    // 保存与下一次输入之间必须各自成组：断合并 + 挪光标（NSTextView 的输入会话以光标移动收口）
                    editor.breakUndoCoalescing()
                    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
                    editor.textView.insertText("QQ", replacementRange: NSRange(location: 0, length: 0))
                    state("③ 保存后又插入 QQ")
                }
                step {
                    let handled = dispatch(Selector(("undo:")))
                    state("④ ⌘Z（派发=\(handled)，只该退掉 QQ，且回到已保存内容）")
                }
                step {
                    let handled = dispatch(Selector(("undo:")))
                    state("⑤ 再 ⌘Z（派发=\(handled)，应退掉 XYZ）")
                }
            }
        }
        guard let term = env["SWIFTNOTE_SEARCH"] else { return }
        showSearchPanel(showsReplace: env["SWIFTNOTE_REPLACE"] != nil)
        searchPanel.setSearchTerm(term, replacement: env["SWIFTNOTE_REPLACE"])
        if env["SWIFTNOTE_REPLACE_ALL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.searchPanel.replaceAllTapped()
            }
        }
    }

    /// 调试：应用内自绘快照（排除窗口服务器缓存干扰）
    func scheduleDebugSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["SWIFTNOTE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["SWIFTNOTE_SNAPSHOT_DELAY"] ?? "1.5") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            let env = ProcessInfo.processInfo.environment
            // 对比窗口可能因为主窗口抢焦点而丢失 key 状态，按标题兜底定位
            let compareWindow = env["SWIFTNOTE_COMPARE"] != nil
                ? NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("对比") }
                : nil
            let target = env["SWIFTNOTE_SETTINGS"] != nil
                ? SettingsWindowController.shared.window
                : (env["SWIFTNOTE_QUICK_OPEN"] != nil
                   ? self?.quickOpen.window
                   : (compareWindow ?? NSApp.keyWindow ?? self?.window))
            guard let view = target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            // 布局诊断：标签栏被内容视图覆盖时，从这一行能直接看出谁占了多少高度
            let tree = view.subviews.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: " | ")
            NSLog("[snapshot] subviews: %@", tree)
            view.cacheDisplay(in: view.bounds, to: rep)
            // 单独把行号栏画一张：整窗快照里它一直是空白，
            // 单独 dump 才能区分「真的没画」和「整窗快照没抓到」
            if let gutter = Self.firstGutter(in: view),
               let grepp = gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds) {
                gutter.cacheDisplay(in: gutter.bounds, to: grepp)
                if let d = grepp.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: path + ".gutter.png"))
                    NSLog("[snapshot] gutter bounds=%@ hidden=%d alpha=%.2f",
                          NSStringFromRect(gutter.bounds),
                          gutter.isHidden ? 1 : 0, gutter.alphaValue)
                }
            }
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<Int32>.size)
                let kr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                let rss = kr == KERN_SUCCESS ? Double(info.resident_size) / 1024 / 1024 : 0
                NSLog("[snapshot] wrote \(path) size=\(view.bounds) rss=\(String(format: "%.0f", rss))MB window=\(target?.title ?? "nil")")
            }
        }
    }


    /// 递归找第一个行号栏（它嵌在 容器 → scrollView → 容器 里）
    private static func firstGutter(in view: NSView) -> NSView? {
        if view is LineNumberGutterView { return view }
        for sub in view.subviews {
            if let found = firstGutter(in: sub) { return found }
        }
        return nil
    }

    /// 退出前把当前大文件面板的滚动位置写回文档（会话恢复要记住它）
    func syncPlainScrollToDocument() {
        guard let view = mountedPlainView, let doc = plainDocument else { return }
        doc.scrollPosition = view.verticalOffset
    }

    // MARK: - 菜单动作

    @objc func newDocument(_ sender: Any?) {
        store.newDocument()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        store.open(urls: panel.urls)
    }

    // MARK: - 最近文件（FR-11）

    /// ⌘⇧O：快速打开面板；再按一次收起（面板已是 key window 时菜单键位仍会走到这里）
    @objc func quickOpenRecent(_ sender: Any?) {
        if quickOpen.isVisible {
            quickOpen.dismiss()
            return
        }
        presentQuickOpen(query: "")
    }

    private func presentQuickOpen(query: String) {
        let openPaths = store.documents.compactMap { $0.fileURL?.path }
        quickOpen.onOpen = { [weak self] item in
            self?.openRecent(path: item.path)
        }
        quickOpen.present(over: window, openPaths: openPaths, recentPaths: store.recentFiles)
        if !query.isEmpty { quickOpen.setQuery(query) }
    }

    /// 菜单「最近打开」子菜单：路径放在 representedObject 里
    @objc func openRecentDocument(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let path = item.representedObject as? String else { return }
        openRecent(path: path)
    }

    private func openRecent(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = "文件已不存在"
            alert.informativeText = "\((path as NSString).lastPathComponent) 已被删除或移动，可以从最近文件里移除它。"
            alert.addButton(withTitle: "从列表移除")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                store.removeRecent(path)
                NotificationCenter.default.post(name: .swiftNoteDocumentsChanged, object: store)
            }
            return
        }
        store.open(urls: [URL(fileURLWithPath: path)])
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        store.clearRecentFiles()
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = store.activeDocument else { return }
        store.save(document: doc)
        refreshAfterSave()
    }
    @objc func saveDocumentAs(_ sender: Any?) {
        guard let doc = store.activeDocument else { return }
        store.saveAs(document: doc)
        refreshAfterSave()
    }

    private func refreshAfterSave() {
        refreshTabs()
        refreshStatus()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        closeTab(at: store.activeIndex)
    }

    private func closeTab(at index: Int) {
        guard store.documents.indices.contains(index) else { return }
        if store.closeTab(index: index) {
            if store.documents.isEmpty {
                store.newDocument()
            }
            refreshAll()
        }
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard store.documents.count > 1 else { return }
        store.activate(index: (store.activeIndex + 1) % store.documents.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard store.documents.count > 1 else { return }
        let count = store.documents.count
        store.activate(index: (store.activeIndex - 1 + count) % count)
    }

    @objc func formatJSON(_ sender: Any?) {
        guard let doc = store.activeDocument, let editor = mountedEditor else { return }
        guard doc.syntaxMode == .json else {
            presentAlert(title: "当前文档不是 JSON", message: "格式化仅适用于 JSON 文件。")
            return
        }
        guard !doc.isReadOnly else {
            presentAlert(title: "只读模式", message: "只读文件不允许修改，请先另存为副本。")
            return
        }
        let text = editor.text
        if case .failure(let error) = JSONService.validate(text) {
            presentAlert(title: "JSON 校验失败", message: error.description)
            return
        }
        do {
            let formatted = try JSONService.format(text)
            editor.replaceTextAsSingleUndo(formatted)
            statusBar.setValidationMessage("已格式化", isError: false)
            refreshTabs()
        } catch let error as JSONValidationError {
            presentAlert(title: "格式化失败", message: error.description)
        } catch {
            presentAlert(title: "格式化失败", message: error.localizedDescription)
        }
    }

    @objc func validateJSON(_ sender: Any?) {
        guard let editor = mountedEditor else { return }
        switch JSONService.validate(editor.text) {
        case .success:
            statusBar.setValidationMessage("JSON 有效")
        case .failure(let error):
            statusBar.setValidationMessage("JSON 错误 · \(error)")
        }
    }

    /// 主动从磁盘重新加载（Cmd+R）；本地有修改时先确认，默认保留本地
    @objc func reloadFromDisk(_ sender: Any?) {
        guard let doc = store.activeDocument, doc.fileURL != nil else { return }
        if doc.isDirty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "「\(doc.displayName)」有未保存的修改"
            alert.informativeText = "从磁盘重新加载会丢弃这些修改，且无法撤销。"
            alert.addButton(withTitle: "保留本地版本")
            alert.addButton(withTitle: "重新加载")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        store.reload(document: doc)
        refreshAll()
    }

    // MARK: - 双屏对比（FR-09）

    @objc func compareFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择两个文件进行双屏对比（按住 ⌘ 可多选）"
        panel.prompt = "对比"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.count == 2 else {
            presentAlert(title: "请选择两个文件", message: "双屏对比需要恰好选中两个文件。")
            return
        }
        openCompareWindow(left: urls[0], right: urls[1])
    }

    /// 打开对比窗口（nil 表示该侧留空，稍后在标题栏选择）
    @discardableResult
    func openCompareWindow(left: URL?, right: URL?) -> CompareWindowController {
        let controller = CompareWindowController(store: store)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.compareWindows.removeAll { $0 === controller }
        }
        compareWindows.append(controller)
        controller.present(left: left, right: right)
        return controller
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = store.activeDocument?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 搜索替换（FR-08）

    @objc func performFind(_ sender: Any?) {
        showSearchPanel(showsReplace: false)
    }

    @objc func performFindAndReplace(_ sender: Any?) {
        showSearchPanel(showsReplace: true)
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard !searchPanel.isHidden else {
            showSearchPanel(showsReplace: false)
            return
        }
        searchPanel.findNext()
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard !searchPanel.isHidden else {
            showSearchPanel(showsReplace: false)
            return
        }
        searchPanel.findPrevious()
    }

    private func showSearchPanel(showsReplace: Bool) {
        if store.activeDocument?.prefersPlainText == true {
            presentAlert(title: "大文件模式不支持搜索",
                         message: "该文件以纯文本只读方式打开（超过大文件阈值），搜索与替换不可用。")
            return
        }
        guard mountedEditor != nil else { return }
        searchPanel.isHidden = false
        layoutContent()
        searchPanel.activate(showsReplace: showsReplace, selection: selectedText())
    }

    /// 编辑区选中文本作为查找初值（多行或过长不预填）
    private func selectedText() -> String? {
        guard let editor = mountedEditor else { return nil }
        let range = editor.textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= editor.textLength else { return nil }
        return (editor.text as NSString).substring(with: range)
    }

    // MARK: - 编码 / 语法菜单

    private func showEncodingMenu(from button: NSButton) {
        guard let doc = store.activeDocument else { return }
        let menu = NSMenu()

        // 上半段：点编码名 = 「转为该编码保存」。改的是内存文本将来怎么写盘，
        // 不读盘、不丢内容——这也是最常见的诉求（文件是 UTF-8，想改成 GBK 交付）
        for encoding in FileEncoding.allCases {
            let item = NSMenuItem(title: encoding.displayName,
                                  action: #selector(convertEncoding(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = encoding.rawValue
            item.state = doc.encoding == encoding ? .on : .off
            menu.addItem(item)
        }

        // BOM 只在 UTF-8 下有意义：GBK 文件带 BOM 是错误状态，不给这个开关
        if doc.encoding == .utf8 {
            let bomItem = NSMenuItem(title: "写入 UTF-8 BOM",
                                     action: #selector(toggleEncodingBOM(_:)),
                                     keyEquivalent: "")
            bomItem.target = self
            bomItem.state = doc.hasBOM ? .on : .off
            menu.addItem(bomItem)
        }

        menu.addItem(.separator())

        // 下半段：按另一个编码重新解码磁盘。与「转为」正交——
        // 文件本来是 GBK、却被当成 UTF-8 显示成乱码时，走这一条把内容读对
        let other: FileEncoding = doc.encoding == .utf8 ? .gbk : .utf8
        let reloadItem = NSMenuItem(title: "以 \(other.displayName) 重新解码…",
                                    action: #selector(reloadEncodingChosen(_:)),
                                    keyEquivalent: "")
        reloadItem.target = self
        reloadItem.representedObject = other.rawValue
        reloadItem.isEnabled = doc.fileURL != nil
        menu.addItem(reloadItem)

        let hint = NSMenuItem(title: "点编码名＝转为该编码保存；重新解码＝按该编码重读磁盘",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 2),
                   in: button)
    }

    @objc private func convertEncoding(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let encoding = FileEncoding(rawValue: raw) else { return }
        convertEncoding(to: encoding)
    }

    @objc private func reloadEncodingChosen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let encoding = FileEncoding(rawValue: raw) else { return }
        reloadWithEncoding(encoding)
    }

    @objc private func toggleEncodingBOM(_ item: NSMenuItem) { toggleEncodingBOM() }

    private func toggleEncodingBOM() {
        guard let doc = store.activeDocument else { return }
        guard !doc.isReadOnly else {
            presentAlert(title: "只读模式", message: "只读文件不能修改 BOM 设置。")
            return
        }
        guard doc.encoding == .utf8 else { return }
        doc.hasBOM.toggle()
        if !doc.isDirty { doc.markEdited() }
        refreshStatus()
        refreshTabs()
        store.scheduleSessionSave()
        statusBar.setValidationMessage(doc.hasBOM
                                       ? "保存时将写入 UTF-8 BOM"
                                       : "保存时不再写入 UTF-8 BOM")
    }

    /// 转为指定编码：只改「以后按什么编码写盘」，文本一个字节都不动
    private func convertEncoding(to target: FileEncoding) {
        guard let doc = store.activeDocument else { return }
        guard doc.encoding != target else { return }
        // 大文件先判：它们是只读的，但真正原因是体积，提示要说清楚
        if doc.prefersPlainText {
            presentAlert(title: "大文件模式不支持切换编码",
                         message: "该文件超过大文件阈值，以纯文本只读方式打开。请关闭本标签后重新打开。")
            return
        }
        guard !doc.isReadOnly else {
            presentAlert(title: "只读模式", message: "只读文件不能切换编码。")
            return
        }
        let editor = store.editor(for: doc)
        editor.syncToDocument()
        // GB18030 能编下所有 Unicode，所以这里的失败分支只是兜底；
        // 真正要拦的是「BMP 以外字符」——它会被写成 4 字节，只认 GBK 双字节区的工具读不了
        guard EncodingService.canEncode(editor.text, as: target) else {
            presentAlert(title: "无法转为 \(target.displayName)",
                         message: "当前文本包含 \(target.displayName) 无法表示的字符，请继续使用 UTF-8。")
            return
        }
        if target == .gbk, EncodingService.hasSupplementaryPlaneCharacters(in: editor.text) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "文本含 GBK 双字节区以外的字符"
            alert.informativeText = """
            文本里有 emoji 或生僻扩展汉字，转成 \(target.displayName) 后会被写成 GB18030 的四字节序列。
            SwiftNote 自己读得回来，但只认 GBK 的工具（部分 Java / MFC 报文程序）可能读错。
            """
            alert.addButton(withTitle: "仍然转换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        doc.encoding = target
        // 编码变了就得再写一次盘，哪怕文本没动过
        if !doc.isDirty { doc.markEdited() }
        refreshStatus()
        refreshTabs()
        store.scheduleSessionSave()
        statusBar.setValidationMessage("已转为 \(target.displayName)，保存后按该编码写入")
    }

    /// 按指定编码重新解码磁盘内容（原「切换编码」的行为）
    ///
    /// 与「转为」分开是有原因的：这两个动作在同一个菜单项上会冲突。
    /// 文件是 GBK 却被当成 UTF-8 显示乱码 → 要重新解码；
    /// 文件是 UTF-8、想改成 GBK 交付 → 要转为。点了才知道用户想哪个是不现实的。
    private func reloadWithEncoding(_ target: FileEncoding) {
        guard let doc = store.activeDocument else { return }
        guard let url = doc.fileURL else {
            presentAlert(title: "未保存的文件", message: "新文件还没有磁盘内容，只能「转为」某个编码。")
            return
        }
        if doc.prefersPlainText {
            presentAlert(title: "大文件模式不支持切换编码",
                         message: "该文件超过大文件阈值，以纯文本只读方式打开。请关闭本标签后重新打开。")
            return
        }

        if doc.isDirty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "「\(doc.displayName)」有未保存的修改"
            alert.informativeText = """
            按 \(target.displayName) 重新解码会从磁盘重读内容，未保存的修改将丢失（不可撤销）。

            想保留这些修改，请选「用 \(target.displayName) 另存为」——内容写到副本里，原文件不动。
            """
            alert.addButton(withTitle: "用 \(target.displayName) 另存为…")
            alert.addButton(withTitle: "丢弃修改并重新解码")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let saved = store.saveAs(document: doc, encoding: target,
                                         bom: target == .utf8 ? doc.hasBOM : false)
                if saved {
                    refreshAll()
                    statusBar.setValidationMessage("已用 \(target.displayName) 另存为副本")
                }
                return
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }

        // 读盘不能留在主线程：13MB 日志同步 Data(contentsOf:) 会让切编码卡几百毫秒（R-17）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                guard let self else { return }
                // 读盘期间文档可能已被关闭：回来先确认它还活着
                guard self.store.documents.contains(where: { $0.id == doc.id }) else { return }
                guard let data else {
                    self.presentAlert(title: "读取失败", message: "无法读取 \(url.lastPathComponent)")
                    return
                }
                // 严格解码，不退化到容错：切错编码要明确报错，而不是给一堆替换字符
                guard let decoded = EncodingService.decode(data, as: target) else {
                    AppLogger.warn("按 \(target.displayName) 重新解码失败，文档未改动：\(url.lastPathComponent)")
                    self.presentAlert(title: "无法按 \(target.displayName) 解码",
                                      message: "\(url.lastPathComponent) 的内容不是合法的 \(target.displayName)。\n当前文档未做任何改动。")
                    return
                }
                let normalized = LineEnding.normalized(decoded.text)
                doc.encoding = target
                doc.hasBOM = decoded.hasBOM
                doc.lineEnding = LineEnding.detect(in: decoded.text)
                // 用文档自己的 editor（不是 mountedEditor：异步期间用户可能已切到别的标签）
                let editor = self.store.editor(for: doc)
                editor.replaceText(normalized)
                doc.markSaved(text: normalized)
                self.store.drafts.remove(for: doc.id)
                self.refreshAfterSave()
                self.statusBar.setValidationMessage("已按 \(target.displayName) 重新解码")
            }
        }
    }


    // MARK: - 换行符（EOL）

    private func showLineEndingMenu(from button: NSButton) {
        guard let doc = store.activeDocument else { return }
        let menu = NSMenu()
        for ending in LineEnding.allCases {
            let item = NSMenuItem(title: "\(ending.displayName)　\(ending.platformName)",
                                  action: #selector(selectLineEnding(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = ending.rawValue
            item.state = doc.lineEnding == ending ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "内存中统一按 LF 编辑，保存时按所选风格写入", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 2),
                   in: button)
    }

    @objc private func selectLineEnding(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let ending = LineEnding(rawValue: raw) else { return }
        switchLineEnding(to: ending)
    }

    /// 切换换行风格：只改文档元数据 + 标脏，文本不动。
    ///
    /// 文本不动是有意的：CRLF 文件的 `\r` 一旦进了 textStorage，
    /// 行号栏会把它算成可见字符、搜索高亮的 range 也要为它让位。
    /// 内存恒为 LF 后，「切 EOL」就退化成一次待保存的元数据变更——
    /// 跟 Notepad++ 一样，界面上只有右下角那个标签变了。
    private func switchLineEnding(to target: LineEnding) {
        guard let doc = store.activeDocument else { return }
        guard doc.lineEnding != target else { return }
        guard !doc.isReadOnly else {
            presentAlert(title: "只读模式", message: "只读文件不能修改换行符，请先另存为副本。")
            return
        }
        doc.lineEnding = target
        if !doc.isDirty { doc.markEdited() }
        refreshStatus()
        refreshTabs()
        store.scheduleSessionSave()
        statusBar.setValidationMessage("换行符已切换为 \(target.displayName)，保存后写入磁盘")
    }

    private func showSyntaxMenu(from button: NSButton) {
        guard let doc = store.activeDocument else { return }
        let menu = NSMenu()
        for mode in SyntaxMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectSyntax(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = doc.syntaxMode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 2),
                   in: button)
    }

    @objc private func selectSyntax(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let mode = SyntaxMode(rawValue: raw),
              let editor = mountedEditor else { return }
        editor.changeSyntaxMode(mode)
        statusBar.update(document: store.activeDocument)
        NotificationCenter.default.post(name: .swiftNoteDocumentStateChanged, object: store)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

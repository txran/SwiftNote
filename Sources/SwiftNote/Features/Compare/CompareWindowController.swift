import AppKit
import SwiftNoteKit

/// 双屏对比窗口（FR-09）
///
/// 交互约定：
/// - 两侧各自独立编辑；编辑停 0.5s 自动重算（后台线程，token 丢弃过期结果）
/// - 同步滚动按行映射联动，可在标题栏下方开关
/// - 从「打开的文档」取内容时是内存副本、只读（避免两个编辑区争同一份文本）；
///   直接从磁盘打开的文件可编辑，`⌘S` 保存当前焦点所在栏
/// - 对比中的文件被外部修改：干净时静默重载并重算，有未保存修改时先问「保留本地 / 重新加载」
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    private let store: EditorStore
    private let leftPane = ComparePaneView(side: .left)
    private let rightPane = ComparePaneView(side: .right)
    private let splitView = NSSplitView()
    private let headerView = NSView()
    private let leftPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rightPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swapButton = NSButton(frame: .zero)
    private let syncCheckbox = NSButton(frame: .zero)
    private let reloadButton = NSButton(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "选择两侧文件后开始对比")
    private let diffPrevButton = NSButton(frame: .zero)
    private let diffNextButton = NSButton(frame: .zero)
    private let hunkLabel = NSTextField(labelWithString: "— / —")

    private var leftWatcher: FileWatcher?
    private var rightWatcher: FileWatcher?
    private var lastResult: DiffResult?
    private var generation = 0
    private var debounceWork: DispatchWorkItem?
    private var isSyncingScroll = false
    private var didSetInitialSplit = false
    private var syncScrollEnabled = true
    /// 当前定位到的差异块下标；-1 = 还没跳过
    private var currentHunk = -1
    /// 差异块缓存（百万行文件上 `hunks` 要扫两遍 kinds，别在按钮回调里反复算）
    private var hunks: [DiffHunk] = []

    /// 窗口关闭后由持有者移除引用
    var onClosed: (() -> Void)?

    init(store: EditorStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "对比"
        window.minSize = NSSize(width: 900, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        refreshMenus()
        layoutContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        leftWatcher?.stop()
        rightWatcher?.stop()
    }

    // MARK: - 组装

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(headerView)

        configurePopup(leftPopup)
        configurePopup(rightPopup)

        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                   accessibilityDescription: "交换左右两侧")
        swapButton.title = ""
        swapButton.bezelStyle = .rounded
        swapButton.contentTintColor = .secondaryLabelColor
        swapButton.toolTip = "交换左右两侧"
        swapButton.target = self
        swapButton.action = #selector(swapSides(_:))
        headerView.addSubview(swapButton)

        configureNavButton(diffPrevButton, symbol: "chevron.up",
                           tip: "上一处差异（⌥⌘↑）", action: #selector(previousDifference(_:)))
        configureNavButton(diffNextButton, symbol: "chevron.down",
                           tip: "下一处差异（⌥⌘↓）", action: #selector(nextDifference(_:)))
        hunkLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hunkLabel.textColor = .tertiaryLabelColor
        hunkLabel.alignment = .center
        headerView.addSubview(hunkLabel)

        syncCheckbox.setButtonType(.switch)
        syncCheckbox.title = "同步滚动"
        syncCheckbox.state = .on
        syncCheckbox.font = NSFont.systemFont(ofSize: 11.5)
        syncCheckbox.target = self
        syncCheckbox.action = #selector(toggleSyncScroll(_:))
        headerView.addSubview(syncCheckbox)

        reloadButton.title = "重新对比"
        reloadButton.bezelStyle = .rounded
        reloadButton.font = NSFont.systemFont(ofSize: 11.5)
        reloadButton.toolTip = "从磁盘重新读取两侧并重算差异"
        reloadButton.target = self
        reloadButton.action = #selector(reloadFromDisk(_:))
        headerView.addSubview(reloadButton)

        statusLabel.font = NSFont.systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(statusLabel)

        // 分隔线
        let separator = NSBox()
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        headerView.addSubview(separator)
        separator.frame = NSRect(x: 0, y: 0, width: 2000, height: 1)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        content.addSubview(splitView)

        for pane in [leftPane, rightPane] {
            pane.onEdited = { [weak self] in self?.scheduleRecompute() }
            pane.onScrolled = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.syncScroll(from: pane)
            }
            pane.onDirtyChanged = { [weak self] in
                self?.refreshMenus()
                self?.refreshChrome()
            }
        }
    }

    private func configurePopup(_ popup: NSPopUpButton) {
        popup.font = NSFont.systemFont(ofSize: 11.5)
        popup.target = self
        popup.action = #selector(popupSelectionChanged(_:))
        headerView.addSubview(popup)
    }

    private func configureNavButton(_ button: NSButton, symbol: String,
                                    tip: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.isEnabled = false
        headerView.addSubview(button)
    }

    private func layoutContent() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        let headerHeight: CGFloat = 44
        headerView.frame = NSRect(x: 0, y: bounds.height - headerHeight,
                                  width: bounds.width, height: headerHeight)
        splitView.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                 height: max(0, bounds.height - headerHeight))
        layoutHeader(width: bounds.width)
        if !didSetInitialSplit, splitView.frame.width > 200 {
            didSetInitialSplit = true
            splitView.setPosition(splitView.frame.width / 2, ofDividerAt: 0)
        }
    }

    private func layoutHeader(width: CGFloat) {
        let controlHeight: CGFloat = 26
        let y: CGFloat = (44 - controlHeight) / 2
        var x: CGFloat = 12

        leftPopup.frame = NSRect(x: x, y: y, width: 210, height: controlHeight)
        x = leftPopup.frame.maxX + 6
        swapButton.frame = NSRect(x: x, y: y, width: 30, height: controlHeight)
        x = swapButton.frame.maxX + 6
        rightPopup.frame = NSRect(x: x, y: y, width: 210, height: controlHeight)

        let reloadWidth: CGFloat = 84
        var right = width - 12 - reloadWidth
        reloadButton.frame = NSRect(x: right, y: y, width: reloadWidth, height: controlHeight)
        right -= 10

        let syncWidth: CGFloat = 92
        right -= syncWidth
        syncCheckbox.frame = NSRect(x: right, y: y + 3, width: syncWidth, height: 20)
        right -= 8

        // 差异导航：从右往左 next → 计数 → prev
        right -= 26
        diffNextButton.frame = NSRect(x: right, y: y, width: 26, height: controlHeight)
        right -= 50
        hunkLabel.frame = NSRect(x: right, y: y + 4, width: 50, height: 18)
        right -= 26
        diffPrevButton.frame = NSRect(x: right, y: y, width: 26, height: controlHeight)
        right -= 10

        let statusX = rightPopup.frame.maxX + 12
        statusLabel.frame = NSRect(x: statusX, y: y + 4, width: max(0, right - 8 - statusX), height: 18)
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }

    // MARK: - 打开

    /// 打开（或复用）窗口并载入两侧文件；nil 表示该侧留空
    func present(left: URL?, right: URL?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        var requests: [(URL, ComparePaneView)] = []
        if let left { requests.append((left, leftPane)) }
        if let right { requests.append((right, rightPane)) }
        loadFiles(requests)
    }

    /// 批量异步读盘：12MB 级文件同步读会把窗口冻住好几秒（实测），
    /// 因此统一走 FileLoader.loadAsync，读完再在主线程灌内容
    private func loadFiles(_ requests: [(URL, ComparePaneView)]) {
        guard !requests.isEmpty else { return }
        if statusLabel.stringValue.isEmpty { statusLabel.stringValue = "读取文件…" }
        FileLoader.loadAsync(urls: requests.map { $0.0 }) { [weak self] loaded, failures in
            guard let self else { return }
            for file in loaded {
                guard let request = requests.first(where: { $0.0.path == file.url.path }) else { continue }
                self.apply(loaded: file, to: request.1)
            }
            if let failure = failures.first {
                self.presentAlert(title: "打开失败",
                                  message: "\(failure.0.lastPathComponent)：\(failure.1.localizedDescription)")
            }
            self.refreshMenus()
            self.refreshChrome()
            self.scheduleRecompute(immediate: true)
        }
    }

    private func apply(loaded: LoadedFile, to pane: ComparePaneView) {
        let tooLarge = loaded.sizeBytes > AppSettings.shared.largeFileThresholdBytes
        let writable = FileManager.default.isWritableFile(atPath: loaded.url.path)
        // 超过阈值走纯文本渲染：TextKit 全量排版百万行会卡几十秒，这里是「当 txt 读」
        pane.setContent(text: loaded.text, url: loaded.url, encoding: loaded.encoding,
                        editable: writable && !tooLarge, linked: false, plainMode: tooLarge)
        startWatching(pane)
        if tooLarge {
            AppLogger.info("对比栏以纯文本只读模式载入：\(loaded.url.lastPathComponent)（\(loaded.sizeBytes / 1024 / 1024)MB）")
        }
    }

    private func loadFile(_ url: URL, into pane: ComparePaneView) {
        loadFiles([(url, pane)])
    }

    private func load(document: EditorDocument, into pane: ComparePaneView) {
        // 取编辑区内存文本（可能含未保存修改），因此只读、不监视磁盘
        let text = store.editors[document.id]?.text ?? document.cachedText
        let large = text.utf8.count > Int(AppSettings.shared.largeFileThresholdBytes)
        pane.setContent(text: text, url: document.fileURL, encoding: document.encoding,
                        editable: false, linked: true, name: document.displayName,
                        plainMode: large)
        stopWatching(pane)
        scheduleRecompute(immediate: true)
        refreshMenus()
        refreshChrome()
    }

    // MARK: - 菜单 / 标题栏状态

    private func refreshMenus() {
        rebuildPopup(leftPopup, pane: leftPane)
        rebuildPopup(rightPopup, pane: rightPane)
    }

    private func rebuildPopup(_ popup: NSPopUpButton, pane: ComparePaneView) {
        popup.removeAllItems()
        var title = pane.displayName
        if pane.isDirty { title = "● " + title }
        if pane.isLinkedDocument { title += "（未保存副本）" }
        popup.addItem(withTitle: title.isEmpty ? "（未选择文件）" : title)
        popup.menu?.addItem(.separator())

        for document in store.documents {
            let menuItem = NSMenuItem(title: document.displayName,
                                      action: #selector(popupSelectionChanged(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = document.id.uuidString
            if pane.isLinkedDocument, pane.displayName == document.displayName {
                menuItem.state = .on
            }
            popup.menu?.addItem(menuItem)
        }
        if !store.documents.isEmpty {
            popup.menu?.addItem(.separator())
        }
        let openItem = NSMenuItem(title: "从磁盘打开…",
                                  action: #selector(popupSelectionChanged(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = "open"
        popup.menu?.addItem(openItem)
        popup.selectItem(at: 0)
    }

    private func refreshChrome() {
        let leftName = leftPane.displayName
        let rightName = rightPane.displayName
        let dirty = (leftPane.isDirty || rightPane.isDirty) ? "● " : ""
        window?.title = "\(dirty)对比 \(leftName) ↔ \(rightName)"
    }

    @objc private func popupSelectionChanged(_ item: NSMenuItem) {
        let pane = (item.menu === leftPopup.menu) ? leftPane : rightPane
        guard let value = item.representedObject as? String else { return }
        if value == "open" {
            chooseFile(for: pane)
            return
        }
        guard let id = UUID(uuidString: value),
              let document = store.documents.first(where: { $0.id == id }) else { return }
        load(document: document, into: pane)
    }

    private func chooseFile(for pane: ComparePaneView) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFile(url, into: pane)
    }

    @objc private func swapSides(_ sender: Any?) {
        let leftSnapshot = leftPane.snapshot()
        let rightSnapshot = rightPane.snapshot()
        leftPane.restore(rightSnapshot)
        rightPane.restore(leftSnapshot)
        startWatching(leftPane)
        startWatching(rightPane)
        scheduleRecompute(immediate: true)
        refreshMenus()
        refreshChrome()
    }

    @objc private func toggleSyncScroll(_ sender: Any?) {
        syncScrollEnabled = syncCheckbox.state == .on
        if syncScrollEnabled { syncScroll(from: leftPane) }
    }

    @objc private func reloadFromDisk(_ sender: Any?) {
        for pane in [leftPane, rightPane] {
            guard !pane.isLinkedDocument, let url = pane.fileURL else { continue }
            if pane.isDirty {
                let alert = NSAlert()
                alert.messageText = "「\(pane.displayName)」有未保存的修改"
                alert.informativeText = "重新对比会从磁盘重新读取，丢弃这些修改。"
                alert.addButton(withTitle: "保留本地版本")
                alert.addButton(withTitle: "重新读取")
                guard alert.runModal() == .alertSecondButtonReturn else { continue }
            }
            loadFile(url, into: pane)
        }
        scheduleRecompute(immediate: true)
    }

    // MARK: - 保存（菜单 ⌘S 经响应者链到达本窗口）

    @objc func saveDocument(_ sender: Any?) {
        let pane: ComparePaneView
        if rightPane.containsFirstResponder() {
            pane = rightPane
        } else if leftPane.containsFirstResponder() {
            pane = leftPane
        } else if leftPane.isEditable {
            pane = leftPane
        } else {
            pane = rightPane
        }
        guard pane.isEditable else {
            NSSound.beep()
            return
        }
        savePane(pane)
    }

    @discardableResult
    private func savePane(_ pane: ComparePaneView) -> Bool {
        guard pane.save() else { return false }
        // 原子写换了 inode：重挂监视，避免把自己的保存当成外部修改
        restartWatching(pane)
        refreshMenus()
        refreshChrome()
        scheduleRecompute(immediate: true)
        return true
    }

    /// 对比窗口为 key window 时，文件菜单里的「对比文件…」也要能用
    @objc func compareFiles(_ sender: Any?) {
        let main = NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
        main?.compareFiles(sender)
    }

    // MARK: - Diff

    private func scheduleRecompute(immediate: Bool = false, delay: TimeInterval = 0.5) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recompute() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : delay), execute: work)
    }

    private func recompute() {
        guard leftPane.textView != nil, rightPane.textView != nil else { return }
        generation += 1
        let token = generation
        let leftText = leftPane.text
        let rightText = rightPane.text
        statusLabel.stringValue = "对比中…"
        statusLabel.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DiffEngine.compare(left: leftText, right: rightText)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: DiffResult) {
        lastResult = result
        leftPane.applyDiff(kinds: result.leftKinds, inline: result.leftInline)
        rightPane.applyDiff(kinds: result.rightKinds, inline: result.rightInline)

        var text = result.stats.displayText
        if leftPane.isPlainMode || rightPane.isPlainMode {
            text = "大文件只读模式 · " + text
        }
        if let reason = result.degradeReasons.first {
            text += " · " + reason.displayText
        }
        statusLabel.stringValue = text
        statusLabel.textColor = result.isDegraded ? .systemOrange : .secondaryLabelColor
        // 重新对比后：块数不变（多半是同一处的编辑）就保留当前位置，否则回到未定位
        hunks = result.hunks
        if currentHunk >= hunks.count { currentHunk = -1 }
        updateHunkControls()
        AppLogger.info("对比完成：\(result.stats.displayText)，降级=\(result.degradeReasons)")
    }

    // MARK: - 差异导航

    @objc func nextDifference(_ sender: Any?) {
        stepHunk(+1)
    }

    @objc func previousDifference(_ sender: Any?) {
        stepHunk(-1)
    }

    private func stepHunk(_ delta: Int) {
        guard !hunks.isEmpty else {
            NSSound.beep()
            updateHunkControls()
            return
        }
        let index: Int
        if currentHunk < 0 || currentHunk >= hunks.count {
            index = delta > 0 ? 0 : hunks.count - 1
        } else {
            index = (currentHunk + delta + hunks.count) % hunks.count
        }
        currentHunk = index
        jump(to: hunks[index])
        updateHunkControls()
        AppLogger.info("对比导航：第 \(index + 1)/\(hunks.count) 处 左行=\(hunks[index].leftLine + 1)")
    }

    /// 跳到某处差异：两侧各自按行号定位（不复用同步滚动的行映射——
    /// 差异行在另一侧可能就是没有对应行，映射会把两侧带到不同位置）
    private func jump(to hunk: DiffHunk) {
        let context = 2
        isSyncingScroll = true
        leftPane.scroll(toLinePosition: Double(max(0, hunk.leftLine - context)))
        rightPane.scroll(toLinePosition: Double(max(0, hunk.rightLine - context)))
        isSyncingScroll = false
    }

    private func updateHunkControls() {
        let total = hunks.count
        let hasAny = total > 0
        diffPrevButton.isEnabled = hasAny
        diffNextButton.isEnabled = hasAny
        hunkLabel.textColor = hasAny ? .secondaryLabelColor : .tertiaryLabelColor
        if hasAny {
            hunkLabel.stringValue = "\(currentHunk >= 0 ? currentHunk + 1 : 0) / \(total)"
        } else {
            hunkLabel.stringValue = "— / —"
        }
    }

    /// 无头核对：导航状态一行摘要
    func navigationSummaryForTesting() -> String {
        let prev = diffPrevButton.isEnabled ? "可用" : "灰"
        let next = diffNextButton.isEnabled ? "可用" : "灰"
        let left = String(format: "%.0f", leftPane.topLinePosition)
        let right = String(format: "%.0f", rightPane.topLinePosition)
        return "计数=\(hunkLabel.stringValue) prev=\(prev) next=\(next) 总块数=\(hunks.count) 左顶行=\(left) 右顶行=\(right)"
    }

    // MARK: - 同步滚动

    private func syncScroll(from source: ComparePaneView) {
        guard syncScrollEnabled, !isSyncingScroll, let result = lastResult else { return }
        let target = (source === leftPane) ? rightPane : leftPane
        let map = (source === leftPane) ? result.leftToRightLine : result.rightToLeftLine
        guard !map.isEmpty else { return }

        let position = source.topLinePosition
        let line = Int(position.rounded(.down))
        let fraction = position - Double(line)
        let mapped = map[min(max(0, line), map.count - 1)]

        isSyncingScroll = true
        target.scroll(toLinePosition: Double(mapped) + fraction)
        isSyncingScroll = false
    }

    // MARK: - 外部修改

    private func startWatching(_ pane: ComparePaneView) {
        stopWatching(pane)
        guard !pane.isLinkedDocument, let url = pane.fileURL else { return }
        let watcher = FileWatcher(url: url)
        watcher.onChange = { [weak self, weak pane] kind in
            guard let self, let pane else { return }
            self.handleExternalChange(kind, on: pane)
        }
        watcher.start()
        if pane === leftPane { leftWatcher = watcher } else { rightWatcher = watcher }
    }

    private func stopWatching(_ pane: ComparePaneView) {
        if pane === leftPane {
            leftWatcher?.stop()
            leftWatcher = nil
        } else {
            rightWatcher?.stop()
            rightWatcher = nil
        }
    }

    private func restartWatching(_ pane: ComparePaneView) {
        guard !pane.isLinkedDocument, let url = pane.fileURL else {
            stopWatching(pane)
            return
        }
        let existing = (pane === leftPane) ? leftWatcher : rightWatcher
        if let existing {
            existing.retarget(to: url)
        } else {
            startWatching(pane)
        }
    }

    private func handleExternalChange(_ kind: FileChangeKind, on pane: ComparePaneView) {
        guard window?.isVisible == true else { return }
        if kind == .deleted {
            statusLabel.stringValue = "「\(pane.displayName)」已被外部删除或移动"
            statusLabel.textColor = .systemOrange
            return
        }
        guard let url = pane.fileURL else { return }
        if pane.isDirty {
            let alert = NSAlert()
            alert.messageText = "「\(pane.displayName)」已被外部修改"
            alert.informativeText = "当前对比栏有未保存的修改。"
            alert.addButton(withTitle: "保留本地版本")
            alert.addButton(withTitle: "重新加载磁盘内容")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        AppLogger.info("对比窗口重载外部变更：\(url.lastPathComponent)")
        loadFile(url, into: pane)
    }

    // MARK: - 关闭

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let dirtyPanes = [leftPane, rightPane].filter { $0.isDirty }
        guard !dirtyPanes.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "对比窗口有未保存的修改"
        alert.informativeText = dirtyPanes.map { "· \($0.displayName)" }.joined(separator: "\n")
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return dirtyPanes.allSatisfy { savePane($0) }
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        leftWatcher?.stop()
        rightWatcher?.stop()
        onClosed?()
    }

    // MARK: - 无头验证辅助

    /// 模拟用户编辑左侧第 N 行（1 基），验证「编辑 → 实时刷新差异」链路
    func simulateEditLeft(line lineNumber: Int, text: String) {
        leftPane.replaceLineForTesting(text, lineNumber: lineNumber)
    }

    /// 模拟用户滚动左侧到第 N 行（1 基），验证同步滚动联动
    func simulateScrollLeft(toLine line: Int) {
        leftPane.simulateUserScroll(toLine: line)
    }

    /// 当前两侧视口顶行（1 基），供无头验证断言
    func topLinesForTesting() -> (left: Int, right: Int) {
        (Int(leftPane.topLinePosition.rounded(.down)) + 1,
         Int(rightPane.topLinePosition.rounded(.down)) + 1)
    }

    // MARK: - 弹窗

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

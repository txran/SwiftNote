import AppKit
import SwiftNoteKit

/// 搜索替换条（FR-08 / 设计说明书 5.4）
///
/// 三层职责：
/// 1. 查询输入与选项开关（正则 / 大小写 / 整词）；
/// 2. 视口命中同步高亮（先渲染），全量计数后台 Task（后刷新，D-4）；
/// 3. 命中导航、单条替换、全部替换（单 undo 组）。
final class SearchPanelView: NSView, NSSearchFieldDelegate {

    // MARK: - 尺寸

    static let rowHeight: CGFloat = 30
    static let compactHeight: CGFloat = 34
    static let expandedHeight: CGFloat = 64

    var onHeightChanged: (() -> Void)?

    weak var editor: EditorContainerView? {
        didSet {
            guard editor !== oldValue else { return }
            // 旧编辑区撤掉高亮与刻度（切标签后切回来不能留着上一份的结果）
            oldValue?.clearSearchHighlight()
            oldValue?.setMatchMarkers(positions: [])
            editor?.onMarkerClick = { [weak self] ratio in self?.jumpToNearest(ratio) }
            resetForNewEditor()
        }
    }

    // MARK: - 控件

    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let caseButton = NSButton()
    private let regexButton = NSButton()
    private let wordButton = NSButton()
    private let toggleReplaceButton = NSButton()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let closeButton = NSButton()

    private(set) var showsReplaceRow = false

    // MARK: - 状态

    private var allMatches: [NSRange] = []
    private var currentIndex: Int?
    private var generation = 0
    private var searchTimer: Timer?
    private var isCounting = false
    private var lastStatusMessage: String?

    var query: SearchQuery {
        SearchQuery(term: searchField.stringValue,
                    isRegex: regexButton.state == .on,
                    isCaseSensitive: caseButton.state == .on,
                    isWholeWord: wordButton.state == .on)
    }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        searchField.placeholderString = "查找"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        addSubview(searchField)

        replaceField.placeholderString = "替换为"
        replaceField.font = .systemFont(ofSize: 12)
        replaceField.delegate = self
        replaceField.isHidden = true
        addSubview(replaceField)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
        addSubview(countLabel)

        configureIcon(prevButton, symbol: "chevron.up", tooltip: "上一个（Shift+Cmd+G）",
                      action: #selector(previousTapped))
        configureIcon(nextButton, symbol: "chevron.down", tooltip: "下一个（Cmd+G）",
                      action: #selector(nextTapped))
        configureIcon(closeButton, symbol: "xmark", tooltip: "关闭搜索（Esc）",
                      action: #selector(closeTapped))

        configureToggle(caseButton, title: "Aa", tooltip: "区分大小写", action: #selector(optionToggled))
        configureToggle(regexButton, title: ".*", tooltip: "正则表达式", action: #selector(optionToggled))
        configureToggle(wordButton, title: "W", tooltip: "全词匹配", action: #selector(optionToggled))

        toggleReplaceButton.title = "替换"
        toggleReplaceButton.isBordered = false
        toggleReplaceButton.font = .systemFont(ofSize: 11)
        toggleReplaceButton.contentTintColor = .secondaryLabelColor
        toggleReplaceButton.bezelStyle = .inline
        toggleReplaceButton.target = self
        toggleReplaceButton.action = #selector(toggleReplaceRow)
        toggleReplaceButton.toolTip = "展开替换栏（Cmd+Option+F）"
        addSubview(toggleReplaceButton)

        for button in [replaceButton, replaceAllButton] {
            button.isBordered = true
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.isHidden = true
            addSubview(button)
        }
        replaceButton.title = "替换"
        replaceButton.target = self
        replaceButton.action = #selector(replaceCurrentTapped)
        replaceAllButton.title = "全部替换"
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllTapped)

        restoreOptions()
        updateCountLabel()
    }

    private func configureIcon(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func configureToggle(_ button: NSButton, title: String, tooltip: String, action: Selector) {
        button.title = title
        button.setButtonType(.toggle)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func restoreOptions() {
        let settings = AppSettings.shared
        caseButton.state = settings.searchIsCaseSensitive ? .on : .off
        regexButton.state = settings.searchIsRegex ? .on : .off
        wordButton.state = settings.searchIsWholeWord ? .on : .off
        refreshToggleTints()
    }

    private func refreshToggleTints() {
        for button in [caseButton, regexButton, wordButton] {
            button.contentTintColor = button.state == .on ? .controlAccentColor : .secondaryLabelColor
        }
        toggleReplaceButton.contentTintColor = showsReplaceRow ? .controlAccentColor : .secondaryLabelColor
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let h: CGFloat = 22
        let y: CGFloat = (Self.rowHeight - h) / 2

        var right = bounds.width - pad
        closeButton.frame = NSRect(x: right - 18, y: y, width: 18, height: h)
        right -= 18 + 6

        toggleReplaceButton.sizeToFit()
        let toggleW = max(34, toggleReplaceButton.frame.width + 6)
        toggleReplaceButton.frame = NSRect(x: right - toggleW, y: y, width: toggleW, height: h)
        right -= toggleW + 4

        for button in [wordButton, regexButton, caseButton] {
            button.frame = NSRect(x: right - 24, y: y, width: 24, height: h)
            right -= 24
        }
        right -= 4

        nextButton.frame = NSRect(x: right - 20, y: y, width: 20, height: h)
        right -= 20
        prevButton.frame = NSRect(x: right - 20, y: y, width: 20, height: h)
        right -= 20 + 6

        let countW: CGFloat = 92
        countLabel.frame = NSRect(x: right - countW, y: y, width: countW, height: h)
        right -= countW + 6

        let fieldWidth = max(120, right - pad)
        searchField.frame = NSRect(x: pad, y: y, width: fieldWidth, height: h)

        if showsReplaceRow {
            let row2Y = Self.rowHeight + (Self.rowHeight - h) / 2
            replaceField.frame = NSRect(x: pad, y: row2Y, width: fieldWidth, height: h)
            var x = pad + fieldWidth + 8
            replaceButton.sizeToFit()
            let replaceW = max(52, replaceButton.frame.width + 12)
            replaceButton.frame = NSRect(x: x, y: row2Y, width: replaceW, height: h)
            x += replaceW + 6
            replaceAllButton.sizeToFit()
            let replaceAllW = max(70, replaceAllButton.frame.width + 12)
            replaceAllButton.frame = NSRect(x: x, y: row2Y, width: replaceAllW, height: h)
        }
    }

    var desiredHeight: CGFloat { showsReplaceRow ? Self.expandedHeight : Self.compactHeight }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - 对外入口

    /// 打开面板并把焦点移到查找框；`selection` 为编辑区当前选中文本（有则预填）
    func activate(showsReplace: Bool, selection: String? = nil) {
        if let selection,
           !selection.isEmpty,
           !selection.contains("\n"),
           selection.count <= 200 {
            searchField.stringValue = selection
        }
        setReplaceRowVisible(showsReplace)
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        runSearch(keepCurrent: false)
    }

    /// 直接设定查询词（无头截图验证 / 从「查找选中内容」带入）
    func setSearchTerm(_ term: String, replacement: String? = nil) {
        searchField.stringValue = term
        if let replacement { replaceField.stringValue = replacement }
        runSearch(keepCurrent: false)
    }

    func setReplaceRowVisible(_ visible: Bool) {
        guard visible != showsReplaceRow else { return }
        showsReplaceRow = visible
        replaceField.isHidden = !visible
        replaceButton.isHidden = !visible
        replaceAllButton.isHidden = !visible
        toggleReplaceButton.toolTip = visible ? "收起替换栏" : "展开替换栏（Cmd+Option+F）"
        refreshToggleTints()
        needsLayout = true
        onHeightChanged?()
        if visible { window?.makeFirstResponder(searchField) }
    }

    func findNext() {
        guard !allMatches.isEmpty else {
            runSearch(keepCurrent: false)
            return
        }
        let anchor: Int
        if let current = currentIndex {
            anchor = NSMaxRange(allMatches[current])
        } else {
            anchor = editor?.textView.selectedRange().location ?? 0
        }
        guard let index = SearchEngine.nextIndex(in: allMatches, from: anchor, forward: true) else { return }
        selectMatch(at: index)
    }

    func findPrevious() {
        guard !allMatches.isEmpty else {
            runSearch(keepCurrent: false)
            return
        }
        let anchor: Int
        if let current = currentIndex {
            anchor = allMatches[current].location
        } else {
            anchor = editor?.textView.selectedRange().location ?? 0
        }
        guard let index = SearchEngine.nextIndex(in: allMatches, from: anchor, forward: false) else { return }
        selectMatch(at: index)
    }

    /// 关闭面板：撤高亮、撤刻度、焦点回编辑区
    func deactivate() {
        searchTimer?.invalidate()
        generation += 1
        allMatches = []
        currentIndex = nil
        isCounting = false
        updateCountLabel()
        editor?.clearSearchHighlight()
        editor?.setMatchMarkers(positions: [])
        editor?.focusEditor()
    }

    func refreshAfterTextEdit() {
        guard window != nil, !isHidden, !query.isEmpty else { return }
        scheduleSearch(delay: 0.12)
    }

    // MARK: - 搜索执行

    private func resetForNewEditor() {
        allMatches = []
        currentIndex = nil
        generation += 1
        updateCountLabel()
        // 面板隐藏时不要为旧查询白扫全文
        if !isHidden, !query.isEmpty { runSearch(keepCurrent: false) }
    }

    private func scheduleSearch(delay: TimeInterval) {
        searchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.runSearch(keepCurrent: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        searchTimer = timer
    }

    private func runSearch(keepCurrent: Bool) {
        searchTimer?.invalidate()
        generation += 1
        let token = generation
        let query = query
        guard let editor, !query.isEmpty else {
            allMatches = []
            currentIndex = nil
            isCounting = false
            updateCountLabel()
            editor?.clearSearchHighlight()
            editor?.setMatchMarkers(positions: [])
            lastStatusMessage = nil
            return
        }

        // 1. 视口优先：同步算视口命中并立刻上色（保证键入到高亮 < 100ms）
        let text = editor.text as NSString
        let viewport = expand(editor.visibleCharacterRange, by: 2000, limit: text.length)
        var viewportMatches = SearchEngine.findAll(in: text, query: query, in: viewport)
        if viewportMatches.isEmpty {
            viewportMatches = SearchEngine.findAll(in: text, query: query,
                                                  in: NSRange(location: viewport.location, length: viewport.length))
        }
        if !keepCurrent { currentIndex = nil }
        let currentRange = currentIndex.flatMap { allMatches.indices.contains($0) ? allMatches[$0] : nil }
        editor.applySearchHighlight(matches: viewportMatches, current: currentRange)

        // 2. 全量计数：后台 Task（D-4），过期结果按 generation 丢弃
        isCounting = true
        updateCountLabel()
        let snapshot = editor.text
        Task { [weak self] in
            let matches = await SearchEngine.findAllAsync(in: snapshot, query: query)
            await MainActor.run {
                guard let self, self.generation == token else { return }
                self.allMatches = matches
                self.isCounting = false
                if matches.isEmpty {
                    self.currentIndex = nil
                } else if let current = self.currentIndex, matches.indices.contains(current) {
                    // 保留原光标位置对应的命中
                } else {
                    let anchor = self.editor?.textView.selectedRange().location ?? 0
                    self.currentIndex = SearchEngine.nextIndex(in: matches, from: anchor, forward: true)
                }
                self.editor?.setMatchMarkers(positions: SearchEngine.relativePositions(of: matches,
                                                                                       textLength: text.length))
                self.updateCountLabel()
                self.highlightCurrentViewport()
            }
        }
    }

    private func selectMatch(at index: Int) {
        guard allMatches.indices.contains(index), let editor else { return }
        currentIndex = index
        let range = allMatches[index]
        editor.revealSearchMatch(range)
        editor.setMatchMarkers(positions: SearchEngine.relativePositions(of: allMatches,
                                                                        textLength: editor.textLength),
                               currentIndex: index)
        updateCountLabel()
        highlightCurrentViewport(forceCurrent: range)
    }

    /// 高亮当前视口内的命中（当前命中用更醒目的底色）
    private func highlightCurrentViewport(forceCurrent: NSRange? = nil) {
        guard let editor, !query.isEmpty else { return }
        let text = editor.text as NSString
        let viewport = expand(editor.visibleCharacterRange, by: 2000, limit: text.length)
        let matches = SearchEngine.findAll(in: text, query: query, in: viewport)
        let current = forceCurrent ?? currentIndex.flatMap { allMatches.indices.contains($0) ? allMatches[$0] : nil }
        editor.applySearchHighlight(matches: matches, current: current)
    }

    /// 刻度点击：跳到相对位置最近的命中
    private func jumpToNearest(_ ratio: Double) {
        guard let editor, !allMatches.isEmpty else { return }
        let positions = SearchEngine.relativePositions(of: allMatches, textLength: editor.textLength)
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (index, position) in positions.enumerated() {
            let delta = abs(position - ratio)
            if delta < bestDelta {
                bestDelta = delta
                best = index
            }
        }
        selectMatch(at: best)
    }

    private func expand(_ range: NSRange, by margin: Int, limit: Int) -> NSRange {
        let start = max(0, range.location - margin)
        let end = min(limit, NSMaxRange(range) + margin)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - 计数与提示

    private func updateCountLabel() {
        if let message = lastStatusMessage {
            countLabel.stringValue = message
            countLabel.textColor = .systemOrange
            return
        }
        countLabel.textColor = .secondaryLabelColor
        if query.isEmpty {
            countLabel.stringValue = ""
        } else if isCounting {
            countLabel.stringValue = "统计中…"
        } else if allMatches.isEmpty {
            countLabel.stringValue = "无结果"
        } else if let current = currentIndex {
            countLabel.stringValue = "\(current + 1) / \(allMatches.count)"
        } else {
            countLabel.stringValue = "\(allMatches.count) 个"
        }
    }

    private func flashStatus(_ message: String) {
        lastStatusMessage = message
        updateCountLabel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.lastStatusMessage == message else { return }
            self.lastStatusMessage = nil
            self.updateCountLabel()
        }
    }

    // MARK: - 动作

    @objc private func nextTapped() { findNext() }
    @objc private func previousTapped() { findPrevious() }

    @objc private func closeTapped() {
        deactivate()
        isHidden = true
        onHeightChanged?()
    }

    @objc private func toggleReplaceRow() {
        setReplaceRowVisible(!showsReplaceRow)
    }

    @objc private func optionToggled() {
        let settings = AppSettings.shared
        settings.searchIsCaseSensitive = caseButton.state == .on
        settings.searchIsRegex = regexButton.state == .on
        settings.searchIsWholeWord = wordButton.state == .on
        refreshToggleTints()
        runSearch(keepCurrent: false)
    }

    @objc private func replaceCurrentTapped() {
        guard let editor else { return }
        guard !editor.document.isReadOnly else {
            flashStatus("只读模式")
            return
        }
        guard !query.isEmpty else { return }
        let replacement = replaceField.stringValue

        // 没有当前命中时，先按当前光标找一条再替换
        if currentIndex == nil {
            findNext()
        }
        guard let index = currentIndex, allMatches.indices.contains(index) else {
            flashStatus("无结果")
            return
        }
        let range = allMatches[index]
        guard editor.replaceSearchMatches([range], with: replacement) == 1 else {
            flashStatus("替换失败")
            return
        }
        let replaced = 1
        allMatches.removeAll()
        runSearch(keepCurrent: false)
        flashStatus("已替换 \(replaced) 处")
        editor.document.markEdited()
        NotificationCenter.default.post(name: .swiftNoteDocumentStateChanged, object: nil)
    }

    @objc func replaceAllTapped() {
        guard let editor else { return }
        guard !editor.document.isReadOnly else {
            flashStatus("只读模式")
            return
        }
        let query = query
        guard !query.isEmpty else { return }
        let replacement = replaceField.stringValue
        let snapshot = editor.text

        // 全部替换同样走后台扫描，避免大文件卡主线程
        Task { [weak self] in
            let outcome: Result<(String, Int), Error>
            do {
                outcome = .success(try SearchEngine.replaceAll(in: snapshot, query: query, with: replacement))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .failure(let error):
                    self.flashStatus("正则无效")
                    AppLogger.warn("全部替换失败：\(error.localizedDescription)")
                case .success(let (newText, count)):
                    guard count > 0 else {
                        self.flashStatus("无结果")
                        return
                    }
                    editor.replaceTextAsSingleUndo(newText)
                    NotificationCenter.default.post(name: .swiftNoteDocumentStateChanged, object: nil)
                    self.runSearch(keepCurrent: false)
                    self.flashStatus("已替换 \(count) 处")
                }
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        scheduleSearch(delay: 0.12)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === searchField { findNext() } else { replaceCurrentTapped() }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor):
            findPrevious()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeTapped()
            return true
        case #selector(NSResponder.moveDown(_:)):
            findNext()
            return true
        case #selector(NSResponder.moveUp(_:)):
            findPrevious()
            return true
        default:
            return false
        }
    }
}

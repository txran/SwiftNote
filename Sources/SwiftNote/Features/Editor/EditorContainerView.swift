import AppKit
import SwiftNoteKit

/// 单个文档的编辑区：TextKit II 文本视图 + 行号尺 + 增量高亮 + 草稿快照调度
final class EditorContainerView: NSView, NSTextViewDelegate, NSMenuDelegate, NSMenuItemValidation {
    let document: EditorDocument
    private(set) var textView: NSTextView!
    private(set) var engine: SyntaxEngine
    private let scrollView = NSScrollView()
    private var gutter: LineNumberGutterView?

    private var highlightTimer: Timer?
    private var draftTimer: Timer?
    private var validationTimer: Timer?

    /// Tab 键插入空格而非制表符（FR-04）
    var tabInsertsSpaces = true
    var indentWidth = 4

    /// 自动换行（FR-10）：关掉后容器宽度无限、横向滚动
    private(set) var wrapsLines = AppSettings.shared.wrapLines
    /// 当前行高亮带（垫在文本视图下层）
    private let currentLineBand = PassthroughView()

    /// 高亮上限：超过该体积不启用高亮（大文件保护，设计说明书 5.10）
    static let highlightSizeLimit: Int64 = 8 * 1024 * 1024

    var onTextChanged: (() -> Void)?
    var onCursorMoved: ((Int, Int) -> Void)?
    var onValidationChanged: ((String?) -> Void)?
    /// 非错误类的状态栏提示（「已格式化」这类），与校验错误区分颜色
    var onNotice: ((String) -> Void)?
    var onRequestSnapshot: (() -> Void)?
    /// 文本被编辑后通知搜索面板重算（编辑会让旧命中失效）
    var onSearchStateInvalidated: (() -> Void)?
    /// 撤销/重做把内容退回到磁盘版本（文档重新变回 Clean），交给 Store 清草稿、刷标题
    var onRevertedToClean: (() -> Void)?

    /// 程序化整篇替换期间抑制 `textDidChange`：
    /// `NSTextView.string = …` 同样会发 NSTextDidChange，若不抑制，
    /// 「外部重载 / 编码切换」会把刚恢复的 Clean 文档立刻标脏
    private var suppressTextDidChange = false

    // MARK: - 撤销栈（FR-10）

    /// 每个文档一条独立撤销栈。
    ///
    /// `NSTextView` 默认顺着响应链取到的是**窗口**的 `NSUndoManager`，而本应用是
    /// 「一个窗口 + 多个常驻标签」，于是 A 标签敲的字会进到共用的那条栈里：
    /// 切到 B 标签按 ⌘Z，改掉的是 A 的内容（实测日志：可见=未命名，
    /// 撤销后 cbm-types.json 从 `ZZZ{` 变回 `{`，而用户眼前的文档根本没变）。
    /// 容器自己回答 `undoManager` 即可按文档隔开——响应链是
    /// textView → clipView → scrollView → 本视图，容器在窗口之前。
    private let documentUndoManager: UndoManager = {
        let manager = UndoManager()
        // 分组由本类自己管（见 ensureUndoGroupOpen / closeUndoGroup）：
        // groupsByEvent 的「按事件自动分组」是 NSApplication / NSWindow 驱动的，
        // 脱离窗口的 manager 永远停在 groupingLevel = 1（实测：连续输入、保存、
        // 再输入，全程组合层都是 1），整篇编辑被并成一个 undo 组，
        // 「无限撤销」退化成「一步撤销到底」。
        // 而自己调 endUndoGrouping 去收口又会和它的内部事件状态打架
        // （实测崩在 -[NSUndoManager _prepareEventGrouping]），所以干脆关掉自动分组。
        manager.groupsByEvent = false
        manager.levelsOfUndo = 0        // 0 = 不限层数，对应 FR-10「无限撤销」
        return manager
    }()

    override var undoManager: UndoManager? { documentUndoManager }

    /// 正在进行的「输入段」：同一段连续输入共用一个 undo 组，
    /// 停顿 `undoGroupIdle` 秒、保存、切标签、挪光标都会把它收口。
    private var undoGroupTimer: Timer?
    private static let undoGroupIdle: TimeInterval = 0.4

    /// 编辑开始前开组；已在组里就只把收口定时器往后推
    private func ensureUndoGroupOpen() {
        let manager = documentUndoManager
        guard !manager.isUndoing, !manager.isRedoing else { return }
        if manager.groupingLevel == 0 { manager.beginUndoGrouping() }
        undoGroupTimer?.invalidate()
        undoGroupTimer = Timer.scheduledTimer(withTimeInterval: Self.undoGroupIdle, repeats: false) {
            [weak self] _ in self?.closeUndoGroup()
        }
    }

    /// 收口当前输入段（没有开着的组就什么也不做）
    private func closeUndoGroup() {
        undoGroupTimer?.invalidate()
        undoGroupTimer = nil
        let manager = documentUndoManager
        guard !manager.isUndoing, !manager.isRedoing else { return }
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }
    }

    // 菜单「撤销/重做」的 action 是 `undo:` / `redo:`，整条响应链里只有 NSWindow
    // 实现它，而 NSWindow 转发的是**窗口**自己的 undoManager——上面那条按文档分的
    // 栈就永远轮不到。容器必须在窗口之前接住这两个动作（实测：只换 undoManager
    // 不实现这两个方法时，窗口 target 仍为 NSWindow，⌘Z 什么也不做）。
    @objc func undo(_ sender: Any?) {
        closeUndoGroup()          // 组必须先收口，否则撤的是「正在进行的输入段」
        documentUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        closeUndoGroup()
        documentUndoManager.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(EditorContainerView.undo(_:)): return documentUndoManager.canUndo
        case #selector(EditorContainerView.redo(_:)): return documentUndoManager.canRedo
        case #selector(formatSelection(_:)):
            return !document.isReadOnly && selectedSnippetKind() != nil
        case #selector(convertSelectionToJSON(_:)):
            // 不在这里拦判型：判不出也能「在选区里定位报文」，由点击后再定
            return !document.isReadOnly && textView.selectedRange().length > 0
        case #selector(formatWholeDocument(_:)):
            return !document.isReadOnly
        default: return true
        }
    }

    // MARK: - 初始化

    init(document: EditorDocument) {
        self.document = document
        self.engine = SyntaxEngine(mode: document.syntaxMode)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var shouldHighlight: Bool {
        // 只读不代表「不值得高亮」：阈值调低后一份 1.7MB 的配置仍是只读，
        // 用户恰恰更需要看清结构。开销只跟体积挂钩
        engine.isHighlightEnabled
            && document.fileSizeBytes <= Self.highlightSizeLimit
    }

    private var shouldShowRuler: Bool {
        document.fileSizeBytes <= Self.highlightSizeLimit
    }

    /// 是否维护行索引。行号栏要靠它，与「开不开高亮」无关——
    /// 纯文本模式没有 lexer，但照样得数行（否则行号栏整栏显示 1）
    private var shouldTrackLines: Bool {
        document.fileSizeBytes <= Self.highlightSizeLimit
    }

    private func setup() {
        // 装载耗时：判断「这个体积还能不能进 TextKit」靠这个数，别靠猜
        let setupStart = CFAbsoluteTimeGetCurrent()
        // 注意：PlainTextPaneView 自己 wantsLayer=true，AppKit 会把它的祖先一路
        // 隐式层化，所以这里显式声明，别让「非层化」成为错觉（实测结论）
        wantsLayer = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        addSubview(scrollView)

        textView = EditorTextViewFactory.make(editable: !document.isReadOnly)
        textView.delegate = self
        tabInsertsSpaces = AppSettings.shared.tabInsertsSpaces
        scrollView.documentView = textView

        // 当前行高亮带铺在文本视图**上层**：文本视图在 TextKit II 下始终画自己的
        // 背景（`drawsBackground = false` 实测无效），垫在下层会被整块盖住。
        // 用的是 5% 半透明 + `hitTest` 返回 nil，既不影响阅读也不吃点击。
        currentLineBand.wantsLayer = true
        currentLineBand.isHidden = true
        scrollView.contentView.addSubview(currentLineBand, positioned: .above, relativeTo: textView)
        applyWrapMode()

        if shouldShowRuler {
            let gutter = LineNumberGutterView(textView: textView)
            gutter.lineNumberProvider = { [weak self] offset in
                guard let self else { return 1 }
                return self.engine.lineIndex(atOffset: offset) + 1
            }
            addSubview(gutter)
            self.gutter = gutter
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollViewDidScroll),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        loadContent()
        let setupMs = (CFAbsoluteTimeGetCurrent() - setupStart) * 1000
        AppLogger.info("编辑器分支：\(document.displayName) size=\(document.fileSizeBytes) 行号=\(shouldShowRuler) 高亮=\(shouldHighlight) 装载=\(String(format: "%.0f", setupMs))ms")

        // 撤销/重做不走 textDidChange，靠 undoManager 的通知补上刷新（见 handleTextMutation）
        NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidChangeText(_:)),
                                               name: .NSUndoManagerDidUndoChange, object: documentUndoManager)
        NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidChangeText(_:)),
                                               name: .NSUndoManagerDidRedoChange, object: documentUndoManager)

        matchMarkers.isHidden = true
        matchMarkers.onClick = { [weak self] ratio in self?.onMarkerClick?(ratio) }
        addSubview(matchMarkers)

        installContextMenu()
    }

    private func loadContent() {
        textView.string = document.cachedText
        resetLineTable()
        applyBaseAttributesEverywhere()
        if shouldTrackLines {
            engine.setText(textView.string as NSString)
        }
        if shouldHighlight {
            applyHighlight(range: NSRange(location: 0, length: (textView.string as NSString).length),
                           tokens: engine.spans(inLines: 0...max(0, engine.lineCount - 1)))
        }
        gutter?.updateWidth(lineCount: max(1, countLines()))
        restoreViewport()
        // TextKit II 对大文档可能把 viewport 锚到文末（实测 900KB/4 万行必现），
        // 等这一轮排版结束后再按文档位置定一次桩
        DispatchQueue.main.async { [weak self] in self?.pinViewport() }
        scheduleValidation()
        refreshCurrentLineHighlight()
    }

    private func applyBaseAttributesEverywhere() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(SyntaxTheme.baseAttributes, range: full)
        storage.endEditing()
    }

    // MARK: - 高亮

    private func applyHighlight(range: NSRange, tokens: [Token]) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let limit = NSMaxRange(range)
        storage.beginEditing()
        storage.setAttributes(SyntaxTheme.baseAttributes, range: range)
        for token in tokens where NSMaxRange(token.range) <= limit {
            storage.addAttribute(.foregroundColor,
                                 value: SyntaxTheme.color(for: token.type),
                                 range: token.range)
        }
        storage.endEditing()
    }

    private func scheduleHighlight(aroundOffset offset: Int) {
        highlightTimer?.invalidate()
        guard shouldTrackLines else { return }
        highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            self?.applyIncrementalHighlight(aroundOffset: offset)
        }
    }

    private func applyIncrementalHighlight(aroundOffset offset: Int) {
        guard shouldTrackLines else { return }
        let text = textView.string as NSString
        let lineRange = engine.applyChange(text: text, aroundOffset: offset)
        gutter?.updateWidth(lineCount: max(1, engine.lineCount))
        guard shouldHighlight, let lineRange else {
            gutter?.needsDisplay = true
            return
        }
        let start = engine.rawRange(lineRange.lowerBound).location
        let end = NSMaxRange(engine.rawRange(lineRange.upperBound))
        guard end >= start else { return }
        applyHighlight(range: NSRange(location: start, length: end - start),
                       tokens: engine.spans(inLines: lineRange))
        gutter?.needsDisplay = true
    }

    // MARK: - 草稿快照

    private func scheduleDraft() {
        draftTimer?.invalidate()
        let delay = AppSettings.shared.draftSnapshotDelaySec
        draftTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.syncToDocument()
            self.onRequestSnapshot?()
        }
    }

    // MARK: - JSON 校验（FR-05，编辑停止 0.5s 后）

    private func scheduleValidation() {
        validationTimer?.invalidate()
        guard document.syntaxMode == .json, !document.isReadOnly else {
            onValidationChanged?(nil)
            return
        }
        validationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            switch JSONService.validate(self.textView.string) {
            case .success:
                self.onValidationChanged?(nil)
            case .failure(let error):
                self.onValidationChanged?("JSON 错误 · \(error)")
            }
        }
    }

    // MARK: - NSView

    private var didPinOnce = false

    override func layout() {
        super.layout()
        guard textView != nil else { return }
        let gutterWidth = gutter?.contentWidth ?? 0
        gutter?.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0,
                                  width: max(0, bounds.width - gutterWidth), height: bounds.height)
        let width = max(scrollView.contentSize.width, 1)
        if wrapsLines {
            if textView.frame.width != width {
                // 高度交给 TextKit II 自己掌握：手工推 height 会让 viewport 锚定错位
                var frame = textView.frame
                frame.size.width = width
                textView.frame = frame
            }
            textView.textContainer?.containerSize = NSSize(width: width,
                                                          height: CGFloat.greatestFiniteMagnitude)
        } else {
            // 不折行：容器宽度无限，文本视图自己撑到最长行宽（sizeToFit 走 TextKit II 的用量）
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                          height: CGFloat.greatestFiniteMagnitude)
            textView.sizeToFit()
            if textView.frame.width < width {
                var frame = textView.frame
                frame.size.width = width
                textView.frame = frame
            }
        }

        if !didPinOnce, bounds.width > 1, bounds.height > 1 {
            didPinOnce = true
            pinViewport()
        }

        if !matchMarkers.isHidden {
            matchMarkers.frame = NSRect(x: bounds.width - MatchMarkersView.width - 1, y: 0,
                                        width: MatchMarkersView.width, height: scrollView.frame.height > 0
                                            ? scrollView.frame.height : bounds.height)
        } else {
            matchMarkers.frame = .zero
        }
    }

    @objc private func scrollViewDidScroll() {
        gutter?.needsDisplay = true
        refreshCurrentLineHighlight()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoGroupTimer?.invalidate()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        handleTextMutation(fromUndo: false)
    }

    /// 撤销/重做**不会**触发 `textDidChange`（实测：3 次输入 3 次回调，撤销 0 次）。
    /// NSTextView 的撤销是直接替换 textStorage，绕过了 `didChangeText`。
    /// 不接这两个通知的话，撤销之后高亮、行号栏、行列号、脏标记、搜索命中全是旧的。
    /// `NSUndoManagerDidUndoChange` 是在文本改完之后才发（实测 handler 里读到的已是新文本）。
    @objc private func undoManagerDidChangeText(_ note: Notification) {
        handleTextMutation(fromUndo: true)
    }

    private func handleTextMutation(fromUndo: Bool) {
        guard !suppressTextDidChange else { return }
        resetLineTable()          // 文本变了，行起点全部作废
        guard !document.isReadOnly else { return }
        document.markEdited()

        // 撤销/重做退回磁盘内容 → 不再算「已修改」（标题圆点、关闭提示都据此）。
        // 只在撤销/重做时算指纹：逐键比较 1MB 文本会拖慢输入。
        if fromUndo, document.isDirty, document.matchesSavedText(textView.string) {
            document.markSaved()
            onRevertedToClean?()
        }

        onTextChanged?()
        scheduleHighlight(aroundOffset: textView.selectedRange().location)
        scheduleDraft()
        scheduleValidation()
        onSearchStateInvalidated?()
    }

    /// 编辑前先撤掉搜索渲染属性：文本一旦变更，之前持有的 NSTextRange 会失效
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        clearSearchHighlight()
        // 撤销栈按「输入段」分组：每次编辑前确保有组开着，空闲后由定时器收口
        ensureUndoGroupOpen()
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)), tabInsertsSpaces {
            textView.insertText(String(repeating: " ", count: indentWidth),
                                replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        publishCursorPosition()
        refreshCurrentLineHighlight()
    }

    /// 切标签 / 重新挂载后主动播报一次行列号。
    /// 只依赖 selection 通知的话，光标位置没变就不触发，
    /// 状态栏会一直挂着上一个标签的行列号（切到 1 行的文件还显示「行 37」）
    func reportCursorPosition() {
        publishCursorPosition()
    }

    private func publishCursorPosition() {
        // 超过高亮上限的文档没有行号栏、又是只读的，行列号对用户没有意义；
        // 而行表要扫全文（200MB 约 1.4s，sample 实测），这里直接跳过。
        guard document.fileSizeBytes <= Self.highlightSizeLimit else {
            onCursorMoved?(0, 0)
            return
        }
        let offset = textView.selectedRange().location
        let text = textView.string as NSString
        let clamped = min(offset, max(0, text.length))
        if engine.textLength == text.length {
            let line = engine.lineIndex(atOffset: clamped)
            let lineStart = engine.rawRange(line).location
            onCursorMoved?(line + 1, clamped - lineStart + 1)
        } else {
            let (line, column) = lineAndColumn(at: clamped, in: text)
            onCursorMoved?(line, column)
        }
    }

    // MARK: - 行列号

    /// 行起点表（UTF-16 偏移）与已扫描到的位置。
    ///
    /// 旧实现每次光标移动都从文档头 `while` + `range(of:)` 数换行：
    /// 200MB 日志上单次就扫 1.4s（sample 实测 138/718 帧落在 rangeOfString），
    /// 点一下光标就卡一次。这里按需把行起点记下来，之后二分查；
    /// 文本一旦变更整表失效（编辑后旧偏移全部作废）。
    private var lineStarts: [Int] = [0]
    private var scannedUpTo = 0

    private func resetLineTable() {
        lineStarts = [0]
        scannedUpTo = 0
    }

    private func lineAndColumn(at offset: Int, in text: NSString) -> (line: Int, column: Int) {
        while scannedUpTo < offset {
            let found = text.range(of: "\n", options: [],
                                   range: NSRange(location: scannedUpTo,
                                                  length: text.length - scannedUpTo))
            guard found.location != NSNotFound else {
                scannedUpTo = text.length
                break
            }
            lineStarts.append(found.location + 1)
            scannedUpTo = found.location + 1
        }
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return (lo + 1, offset - lineStarts[lo] + 1)
    }

    // MARK: - 对外

    var text: String { textView.string }

    /// 把编辑区状态回写到文档（保存 / 切标签 / 快照前调用）
    func syncToDocument() {
        document.cachedText = textView.string
        document.scrollPosition = scrollView.contentView.bounds.origin.y
        document.cursorOffset = textView.selectedRange().location
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    /// 从文档重载（重新加载 / 放弃外部修改）
    func reloadFromDocument() {
        clearSearchHighlight()
        suppressTextDidChange = true
        textView.string = document.cachedText
        suppressTextDidChange = false
        resetLineTable()
        invalidateUndoHistory()
        applyBaseAttributesEverywhere()
        if shouldTrackLines {
            engine.setText(textView.string as NSString)
        }
        if shouldHighlight {
            applyHighlight(range: NSRange(location: 0, length: (textView.string as NSString).length),
                           tokens: engine.spans(inLines: 0...max(0, engine.lineCount - 1)))
        }
        gutter?.updateWidth(lineCount: max(1, engine.lineCount))
        gutter?.needsDisplay = true
        restoreViewport()
        refreshCurrentLineHighlight()
    }

    func setEditable(_ editable: Bool) {
        textView.isEditable = editable
    }

    /// 整段替换（编码切换 / 外部重载），不走撤销栈
    func replaceText(_ newText: String) {
        clearSearchHighlight()
        suppressTextDidChange = true
        textView.string = newText
        suppressTextDidChange = false
        resetLineTable()
        invalidateUndoHistory()
        document.cachedText = newText
        applyBaseAttributesEverywhere()
        engine.setText(textView.string as NSString)
        if shouldHighlight {
            applyHighlight(range: NSRange(location: 0, length: (textView.string as NSString).length),
                           tokens: engine.spans(inLines: 0...max(0, engine.lineCount - 1)))
        }
        gutter?.updateWidth(lineCount: max(1, engine.lineCount))
        gutter?.needsDisplay = true
    }

    /// 格式化替换：单 undo 组（FR-05 GWT：Cmd+Z 一步回退）
    func replaceTextAsSingleUndo(_ newText: String) {
        closeUndoGroup()
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        textView.insertText(newText, replacementRange: full)
        undo?.endUndoGrouping()
        document.markEdited()
    }

    /// 收口当前输入段，让「保存前」与「保存后」的输入各自成步。
    ///
    /// 不切的话，⌘Z 会把「保存之后刚敲的那几个字」和保存前的一起撤掉
    /// （FR-10 GWT：保存动作不消耗撤销步骤）。
    func breakUndoCoalescing() {
        closeUndoGroup()
    }

    /// 整篇替换会让栈里每个范围都失效（旧偏移指向已不存在的位置），必须清栈
    private func invalidateUndoHistory() {
        closeUndoGroup()
        documentUndoManager.removeAllActions()
    }

    func changeSyntaxMode(_ mode: SyntaxMode) {
        clearSearchHighlight()
        document.syntaxMode = mode
        engine.setMode(mode)
        applyBaseAttributesEverywhere()
        engine.setText(textView.string as NSString)
        if shouldHighlight {
            applyHighlight(range: NSRange(location: 0, length: (textView.string as NSString).length),
                           tokens: engine.spans(inLines: 0...max(0, engine.lineCount - 1)))
        }
        gutter?.updateWidth(lineCount: max(1, engine.lineCount))
        scheduleValidation()
    }

    // MARK: - 右键菜单：格式化选中片段
    //
    // 报文配置的日常是「从抓包日志里抠一段 JSON/XML 贴进来」，
    // 一段压成一行的报文肉眼没法读。选中 → 右键 → 层级化，
    // 是这条路最短的入口（比先另存成 .json 再格式化顺手得多）。

    private weak var formatSelectionItem: NSMenuItem?
    private weak var convertToJSONItem: NSMenuItem?
    private var contextMenuInstalled = false

    private func installContextMenu() {
        guard !contextMenuInstalled else { return }
        contextMenuInstalled = true

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "撤销", action: #selector(EditorContainerView.undo(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重做", action: #selector(EditorContainerView.redo(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        // 标准编辑动作交给响应链（target = nil），textView 自己实现
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let selection = NSMenuItem(title: "格式化选中片段", action: #selector(formatSelection(_:)),
                                   keyEquivalent: "")
        selection.target = self
        menu.addItem(selection)
        formatSelectionItem = selection

        // XML 报文 ↔ JSON 配置对照：选中报文直接转成 JSON 贴到配置里
        let toJSON = NSMenuItem(title: "转换为 JSON", action: #selector(convertSelectionToJSON(_:)),
                                keyEquivalent: "")
        toJSON.target = self
        menu.addItem(toJSON)
        convertToJSONItem = toJSON

        let whole = NSMenuItem(title: "格式化整篇报文", action: #selector(formatWholeDocument(_:)),
                               keyEquivalent: "")
        whole.target = self
        menu.addItem(whole)

        textView.menu = menu
    }

    /// 选中内容的首字符决定类型；只取前 64 个 UTF-16 单元，避免为了判类型拷贝整段
    private func selectedSnippetKind() -> SnippetFormatter.Kind? {
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let length = min(64, range.length)
        guard range.location + length <= (textView.string as NSString).length else { return nil }
        let head = (textView.string as NSString).substring(with: NSRange(location: range.location, length: length))
        return SnippetFormatter.detect(head)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === textView.menu else { return }
        // 只刷标题：可用性统一交给 validateMenuItem，避免两套判断打架
        let kind = selectedSnippetKind()
        if let kind {
            formatSelectionItem?.title = "格式化选中片段（\(kind.displayName)）"
        } else {
            formatSelectionItem?.title = "格式化选中片段"
        }
        switch kind {
        case .xml:
            convertToJSONItem?.title = "转换为 JSON（XML 报文 → JSON）"
        case .json:
            convertToJSONItem?.title = "转换为 JSON（已是 JSON，仅重排）"
        case nil:
            // 判不出类型不代表不能用：点击时会在选区里找第一段完整报文
            convertToJSONItem?.title = "转换为 JSON（在选区里定位报文）"
        }
    }

    /// 用 `replacement` 换掉 range，并保持选中（格式化后还是同一段，方便再按一次）
    private func replaceSelection(_ range: NSRange, with replacement: String) {
        ensureUndoGroupOpen()
        textView.insertText(replacement, replacementRange: range)
        closeUndoGroup()
        textView.setSelectedRange(NSRange(location: range.location,
                                          length: (replacement as NSString).length))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    @objc func formatSelection(_ sender: Any?) {
        guard !document.isReadOnly else { return }
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return }
        let snippet = (textView.string as NSString).substring(with: range)
        guard let kind = SnippetFormatter.detect(snippet) else {
            presentFormatFailure("选中的内容看起来不是 JSON 或 XML（应以 `{`、`[` 或 `<` 开头）")
            return
        }
        do {
            let formatted = try SnippetFormatter.format(snippet, kind: kind)
            replaceSelection(range, with: formatted)
            onNotice?("已格式化选中的 \(kind.displayName) 片段")
        } catch {
            presentFormatFailure(error.localizedDescription)
        }
    }

    /// 选中 → JSON。XML 报文走结构转换，JSON 走重排；纯文本文件里也能用
    /// （.txt 没有语法高亮，但报文对照的需求不分文件后缀）
    ///
    /// 判型放在点击之后，而不是菜单开合时：菜单里只按 64 字符猜标题（成本恒定），
    /// 真正的定位/解析在这里做一次。这样「选区里混着日志前缀」也能救回来——
    /// 整段转不动就退一步，在选区内找第一段结构完整的报文，只替换那一段。
    @objc func convertSelectionToJSON(_ sender: Any?) {
        guard !document.isReadOnly else { return }
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else {
            presentFormatFailure("请先选中一段 XML 或 JSON 报文")
            return
        }
        let selection = (textView.string as NSString).substring(with: range)

        var lastError: Error?
        // ① 整段就是报文（最常见）：失败保留错误，等 ② 再试一次
        if let kind = SnippetFormatter.detect(selection) {
            do {
                let converted = try convertTextToJSON(selection, kind: kind)
                replaceSelection(range, with: converted)
                onNotice?(kind == .xml
                          ? "已把选中的 XML 报文转换为 JSON（文本按字符串保留）"
                          : "已把选中的 JSON 重排为层级格式")
                return
            } catch {
                lastError = error
            }
        }
        // ② 选区内定位报文：前缀（时间戳、日志级别）与尾巴都原样保留
        if let match = SnippetExtractor.locate(in: selection) {
            do {
                let converted = try convertTextToJSON(match.snippet, kind: match.kind)
                let target = NSRange(location: range.location + match.location, length: match.length)
                replaceSelection(target, with: converted)
                onNotice?(match.kind == .xml
                          ? "已把第 \(match.location + 1) 个字符起的 XML 报文转换为 JSON（前后内容保留）"
                          : "已把第 \(match.location + 1) 个字符起的 JSON 重排（前后内容保留）")
                return
            } catch {
                lastError = error
            }
        }
        presentFormatFailure(lastError?.localizedDescription
            ?? "选中的内容里没有找到结构完整的 XML 或 JSON 报文（应以 `<`、`{` 或 `[` 出现）")
    }

    private func convertTextToJSON(_ text: String, kind: SnippetFormatter.Kind) throws -> String {
        switch kind {
        case .json: return try JSONService.format(text)
        case .xml: return try XMLToJSON.convert(text)
        }
    }

    @objc func formatWholeDocument(_ sender: Any?) {
        guard !document.isReadOnly else { return }
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 文档语法模式优先（用户可能已经手动指定），否则按内容嗅探
        let kind: SnippetFormatter.Kind?
        switch document.syntaxMode {
        case .json: kind = .json
        case .xml: kind = .xml
        default: kind = SnippetFormatter.detect(text)
        }
        do {
            let formatted = try SnippetFormatter.format(text, kind: kind)
            guard formatted != LineEnding.normalized(text) else {
                onNotice?("已经是层级格式，无需调整")
                return
            }
            let cursor = textView.selectedRange().location
            replaceTextAsSingleUndo(formatted)
            textView.setSelectedRange(NSRange(location: min(cursor, (formatted as NSString).length), length: 0))
            onNotice?("已格式化整篇报文")
        } catch {
            presentFormatFailure(error.localizedDescription)
        }
    }

    private func presentFormatFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "格式化失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - 无头验证接口

    /// 滚动条核对：风格、可见性、几何（对比栏/面板同款）
    func scrollerDiagnostics() -> String {
        let v = scrollView.verticalScroller
        let style = (v?.scrollerStyle == .legacy) ? "legacy" : "overlay"
        let visible = v.map { !$0.isHidden && $0.alphaValue > 0.01 } ?? false
        return "风格=\(style) 可见=\(visible) vFrame=\(v.map { "\($0.frame)" } ?? "nil")"
            + " 内容区=\(scrollView.contentView.frame)"
    }

    /// 设置选区（超出范围自动裁剪）
    func selectRange(_ location: Int, _ length: Int) {
        let maxLength = textLength
        let loc = min(max(0, location), maxLength)
        let len = min(max(0, length), maxLength - loc)
        textView.setSelectedRange(NSRange(location: loc, length: len))
    }

    /// 只读下的可选中性核对：能不能选中、能不能复制、是不是第一响应者
    func selectionDiagnostics() -> String {        let editable = textView.isEditable
        let selectable = textView.isSelectable
        let accepts = textView.acceptsFirstResponder
        let responder = textView.window?.firstResponder === textView
        let original = textView.selectedRange()
        let probeLen = min(20, (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: 0, length: probeLen))
        let probed = textView.selectedRange()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        textView.copy(nil)
        let copied = pasteboard.string(forType: .string) ?? "nil"
        textView.setSelectedRange(original)

        return "isEditable=\(editable) isSelectable=\(selectable) acceptsFirstResponder=\(accepts)"
            + " 第一响应=\(responder) 程序选中=\(probed.location)+\(probed.length)"
            + " 复制=「\(copied.replacingOccurrences(of: "\n", with: "⏎").prefix(24))」"
    }

    /// 当前选中的文本（无头核对用）：换行显示成 ⏎，方便单行看日志
    func selectedTextPreview(_ limit: Int = 200) -> String {
        let range = textView.selectedRange()
        guard range.length > 0 else { return "（无选区）" }
        let text = (textView.string as NSString).substring(with: range)
        let oneLine = text.replacingOccurrences(of: "\n", with: "⏎")
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit)) + "…"
    }

    /// 右键菜单各分项的「标题 + 是否可用」，供无头核对
    func contextMenuSummary() -> String {
        guard let menu = textView.menu else { return "（没有右键菜单）" }
        menuNeedsUpdate(menu)   // 和真正右键时一样先刷一次标题
        let items: [String] = menu.items.filter { !$0.isSeparatorItem }.compactMap { item in
            guard let action = item.action else { return nil }
            var enabled = item.isEnabled
            if let target = item.target as? NSMenuItemValidation {
                enabled = target.validateMenuItem(item)
            }
            return "\(item.title)\(enabled ? "" : "(灰)")"
        }
        return items.joined(separator: " | ")
    }

    // MARK: - 自动换行 / 当前行高亮（FR-10）

    /// 设置变更后重挂显示参数（不重启、不重开文档）
    func applyDisplaySettings() {
        setWrapsLines(AppSettings.shared.wrapLines)
    }

    func setWrapsLines(_ wrap: Bool) {
        wrapsLines = wrap
        applyWrapMode()
    }

    private func applyWrapMode() {
        guard textView != nil else { return }
        scrollView.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.textContainer?.widthTracksTextView = wrapsLines
        needsLayout = true
        layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        gutter?.needsDisplay = true
        refreshCurrentLineHighlight()
    }

    /// 无头核对用：当前行带的位置与可见性（切标签前后对比）
    func currentLineBandSummary() -> String {
        "frame=\(currentLineBand.frame) 隐藏=\(currentLineBand.isHidden)"
            + " 在树=\(currentLineBand.superview != nil) 光标=\(textView.selectedRange().location)"
            + " 视口=\(scrollView.contentView.bounds)"
    }

    /// 当前行高亮：按光标所在的排版片段画一条底色带
    func refreshCurrentLineHighlight() {
        let debug = ProcessInfo.processInfo.environment["SWIFTNOTE_CURRENT_LINE_DEBUG"] != nil
        func skip(_ why: String) {
            if debug { AppLogger.info("当前行带：跳过（\(why)）") }
        }
        guard textView != nil,
              AppSettings.shared.highlightCurrentLine,
              document.fileSizeBytes <= Self.highlightSizeLimit else {
            skip("视图/开关/体积")
            currentLineBand.isHidden = true
            return
        }
        let rawOffset = textView.selectedRange().location
        // 文末光标（offset == 长度）落在任何片段之外，退一个字才能取到所在行
        let offset = min(rawOffset, max(0, textLength - 1))
        guard rawOffset != NSNotFound,
              let layout = textView.textLayoutManager,
              let content = textView.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset) else {
            skip("取不到位置 offset=\(rawOffset)")
            currentLineBand.isHidden = true
            return
        }
        // 视口外的位置还没排版，`textLayoutFragment(for:)` 会返回 nil。
        // 用枚举 + `.ensuresLayout` 逼它只排到当前片段（不要全篇排版）
        var fragment: NSTextLayoutFragment?
        layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { candidate in
            fragment = candidate
            return false
        }
        guard let fragment else {
            skip("取不到片段 offset=\(offset)")
            currentLineBand.isHidden = true
            return
        }
        // 带子固定在视口内（横向滚动时不跟着跑），纵向跟着文本走
        let visible = scrollView.contentView.bounds
        let lineFrame = fragment.layoutFragmentFrame
        currentLineBand.frame = NSRect(x: visible.minX,
                                       y: lineFrame.minY + textView.textContainerInset.height,
                                       width: visible.width,
                                       height: max(1, lineFrame.height))
        currentLineBand.isHidden = false
        // 不用 dynamic 色：这里只为一个 6% 的色带取色，dynamic 色一旦在没有
        // appearance 上下文的时机解析，拿到的可能就是白（画在白底上等于没画）。
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint = isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.06)
        currentLineBand.layer?.backgroundColor = tint.cgColor
        if ProcessInfo.processInfo.environment["SWIFTNOTE_CURRENT_LINE_DEBUG"] != nil {
            AppLogger.info("当前行带：frame=\(currentLineBand.frame) 视口=\(visible) 片段=\(lineFrame) 色=\(tint) 隐藏=\(currentLineBand.isHidden) 在视图树=\(currentLineBand.superview != nil)")
        }
    }

    // MARK: - 搜索高亮（FR-08 / 设计 5.4）
    //
    // 用 NSTextLayoutManager 的渲染属性着色，不写 textStorage：
    // 一是避免污染语法高亮与撤销栈，二是文本一改就能整体撤掉。

    private var searchRenderedRanges: [NSTextRange] = []

    /// 滚动条命中刻度（FR-08 视口外命中的可视化）
    let matchMarkers = MatchMarkersView()
    /// 刻度被点击：回传 0~1 的相对位置，由搜索面板换算成命中索引
    var onMarkerClick: ((Double) -> Void)?

    var textLength: Int { (textView.string as NSString).length }

    /// 更新刻度；`positions` 为空时隐藏
    func setMatchMarkers(positions: [Double], currentIndex: Int? = nil) {
        matchMarkers.positions = positions
        matchMarkers.currentIndex = currentIndex
        matchMarkers.isHidden = positions.isEmpty
        matchMarkers.needsDisplay = true
        needsLayout = true
    }

    /// 当前视口覆盖的字符区间（TextKit II 视口布局范围）
    var visibleCharacterRange: NSRange {
        let full = NSRange(location: 0, length: textLength)
        guard let content = textView.textContentStorage,
              let layout = textView.textLayoutManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return full }
        let documentStart = content.documentRange.location
        let start = content.offset(from: documentStart, to: viewport.location)
        let end = content.offset(from: documentStart, to: viewport.endLocation)
        guard end > start else { return full }
        return NSRange(location: max(0, start), length: max(0, end - start))
    }

    func applySearchHighlight(matches: [NSRange], current: NSRange?) {
        clearSearchHighlight()
        guard let layout = textView.textLayoutManager else { return }
        for range in matches {
            guard range.length > 0, let textRange = makeTextRange(range) else { continue }
            let isCurrent = current.map { NSEqualRanges($0, range) } ?? false
            layout.setRenderingAttributes(
                [.backgroundColor: isCurrent ? SyntaxTheme.searchCurrent : SyntaxTheme.searchMatch],
                for: textRange)
            searchRenderedRanges.append(textRange)
        }
    }

    func clearSearchHighlight() {
        guard let layout = textView.textLayoutManager else {
            searchRenderedRanges.removeAll()
            return
        }
        for textRange in searchRenderedRanges {
            layout.removeRenderingAttribute(.backgroundColor, for: textRange)
        }
        searchRenderedRanges.removeAll()
    }

    /// 跳转到命中：滚动入视口 + 选中 + 系统查找指示气泡
    func revealSearchMatch(_ range: NSRange, select: Bool = true) {
        guard range.location != NSNotFound, NSMaxRange(range) <= textLength else { return }
        clearSearchHighlight()
        textView.scrollRangeToVisible(range)
        if select {
            textView.setSelectedRange(range)
            textView.showFindIndicator(for: range)
        }
    }

    /// 逐条替换（单 undo 组）
    @discardableResult
    func replaceSearchMatches(_ ranges: [NSRange], with replacement: String) -> Int {
        guard !document.isReadOnly, !ranges.isEmpty else { return 0 }
        let length = textLength
        let valid = ranges.filter { range in
            range.location != NSNotFound && range.length > 0 && NSMaxRange(range) <= length
        }
        guard !valid.isEmpty else { return 0 }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        for range in valid.sorted(by: { $0.location > $1.location }) {
            textView.insertText(replacement, replacementRange: range)
        }
        undo?.endUndoGrouping()
        document.markEdited()
        return valid.count
    }

    private func makeTextRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textView.textContentStorage else { return nil }
        let documentStart = content.documentRange.location
        guard let start = content.location(documentStart, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func countLines() -> Int {

        let text = textView.string
        guard !text.isEmpty else { return 1 }
        var count = 1
        for scalar in text.unicodeScalars where scalar == "\n" { count += 1 }
        return count
    }

    private func restoreViewport() {
        let length = (textView.string as NSString).length
        // 必须无条件设，不能写成 `cursorOffset > 0` 才设：
        // `textView.string = ...` 之后 AppKit 把插入点留在**文末**，
        // 光标本在第 0 位的文件（新建/刚从会话恢复）会被当成「没存过光标」跳过，
        // 结果切到该标签时插入点停在末尾 → 当前行高亮带画到文末（屏幕外），
        // 看起来就是「高亮没跟着切换」。
        let target = min(max(0, document.cursorOffset), length)
        textView.setSelectedRange(NSRange(location: target, length: 0))
        pinViewport()
    }

    /// 把视图钉回 `document.scrollPosition`（含 0），并让 TextKit 重排视口
    private func pinViewport() {
        guard textView != nil else { return }
        // 内容是在首帧之后异步换进来的：不先跑一次布局，textViewportLayoutController
        // 的 viewportRange 会停在 {0,0}，行号枚不到任何片段（表现为整栏空白）
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.scrollPosition)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        gutter?.needsDisplay = true
    }
}

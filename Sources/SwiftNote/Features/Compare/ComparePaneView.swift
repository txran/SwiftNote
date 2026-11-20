import AppKit
import SwiftNoteKit

/// 双屏对比的其中一栏（设计说明书 5.5）
///
/// 取舍：对比视图**不做自动换行**。同步滚动按「行号 → 行号」映射，
/// 一旦某侧长行折行，像素高度就不再与行号线性对应，两栏必然错位；
/// 关闭折行后 1 行 = 1 行高，同步滚动是精确的（长行走横向滚动条，
/// 与 Beyond Compare / FileMerge 的行为一致）。
final class ComparePaneView: NSView, NSTextViewDelegate {
    enum Side {
        case left
        case right
        var name: String { self == .left ? "左" : "右" }
    }

    let side: Side
    private(set) var textView: NSTextView!
    private let scrollView = NSScrollView()
    private var gutter: LineNumberGutterView?
    /// 大文件模式的只读纯文本面板（不进 TextKit）
    private var plainView: PlainTextPaneView?
    private(set) var isPlainMode = false

    private(set) var fileURL: URL?
    private(set) var encoding: FileEncoding = .utf8
    private(set) var isEditable = false
    private(set) var isDirty = false
    /// 内容来自已打开文档的内存副本（可能含未保存修改）→ 只读，且不做磁盘监视
    private(set) var isLinkedDocument = false
    private(set) var displayName = "（未选择文件）"

    /// 行首字符偏移（0 基行号 → UTF-16 偏移）
    private var lineStarts: [Int] = [0]

    private var decoratedRanges: [NSRange] = []
    private var isApplyingDecoration = false
    private var isProgrammaticScroll = false

    var onEdited: (() -> Void)?
    var onScrolled: (() -> Void)?
    var onDirtyChanged: (() -> Void)?

    // MARK: - 初始化

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        addSubview(scrollView)

        textView = EditorTextViewFactory.make(editable: false)
        textView.delegate = self
        // 对比栏不折行：保证「行号 ↔ 像素高度」线性，同步滚动才准
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        // 宽度取足够大的有限值（10 万字符）：既保证长行不折行，
        // 也避免「无穷大宽度」让 TextKit II 在宽度查询上退化成全文档排版
        textView.textContainer?.containerSize = NSSize(width: 100_000,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        let gutter = LineNumberGutterView(textView: textView)
        gutter.lineNumberProvider = { [weak self] offset in
            self?.lineNumber(atOffset: offset) ?? 1
        }
        addSubview(gutter)
        self.gutter = gutter

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        guard textView != nil else { return }
        if let plainView {
            plainView.frame = bounds
            return
        }
        let gutterWidth = gutter?.contentWidth ?? 0
        gutter?.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0,
                                  width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }

    @objc private func scrollViewDidScroll() {
        gutter?.needsDisplay = true
        guard !isProgrammaticScroll else { return }
        onScrolled?()
    }

    // MARK: - 内容

    func setContent(text: String, url: URL?, encoding: FileEncoding,
                    editable: Bool, linked: Bool, name: String? = nil,
                    plainMode: Bool = false) {
        fileURL = url
        self.encoding = encoding
        isEditable = editable
        isLinkedDocument = linked
        displayName = name ?? (url?.lastPathComponent ?? "（未命名）")
        isDirty = false

        if plainMode {
            switchToPlainMode(text: text)
            return
        }
        teardownPlainMode()
        clearDecoration()
        textView.string = text
        textView.isEditable = editable
        rebuildLineIndex()
        applyBaseAttributes()
        gutter?.updateWidth(lineCount: lineStarts.count)
        gutter?.needsDisplay = true
        // 回顶走原始 clip 偏移：`scroll(toLinePosition:)` 要读 textView.frame.height 来夹取，
        // 而 12MB / 16 万行的文本视图一读 frame 就会触发一次全量排版（实测 6s+）
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - 大文件模式（纯文本、只读、不排版）

    private func switchToPlainMode(text: String) {
        clearDecoration()
        isEditable = false
        isPlainMode = true
        scrollView.isHidden = true
        gutter?.isHidden = true
        let view = plainView ?? PlainTextPaneView()
        if plainView == nil {
            view.onScrolled = { [weak self] in self?.onScrolled?() }
            addSubview(view)
            plainView = view
        }
        view.frame = bounds
        view.setContent(text: text)
        needsLayout = true
    }

    private func teardownPlainMode() {
        guard isPlainMode || plainView != nil else { return }
        isPlainMode = false
        plainView?.removeFromSuperview()
        plainView = nil
        scrollView.isHidden = false
        gutter?.isHidden = false
    }

    var text: String {
        if isPlainMode { return plainView?.text ?? "" }
        return textView.string
    }

    var lineCount: Int {
        isPlainMode ? (plainView?.lineCount ?? 0) : lineStarts.count
    }

    private func applyBaseAttributes() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(SyntaxTheme.baseAttributes, range: full)
        storage.endEditing()
    }

    private func rebuildLineIndex() {
        let ns = textView.string as NSString
        var starts = [0]
        starts.reserveCapacity(max(1, ns.length / 40))
        var index = 0
        while index < ns.length {
            let found = ns.range(of: "\n", options: [],
                                 range: NSRange(location: index, length: ns.length - index))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            index = found.location + 1
        }
        lineStarts = starts
    }

    /// 字符偏移 → 1 基行号（二分查找行首表）
    private func lineNumber(atOffset offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    // MARK: - 差异装饰

    /// 行级底色 + 行内深色片段（写 textStorage 属性；对比栏不跑语法高亮，不会互相覆盖）
    func applyDiff(kinds: [DiffLineKind], inline: [Int: [NSRange]]) {
        if isPlainMode {
            plainView?.applyDiff(kinds: kinds, inline: inline)
            return
        }
        guard let storage = textView.textStorage else { return }
        rebuildLineIndex()
        clearDecoration()
        guard !kinds.isEmpty else { return }

        isApplyingDecoration = true
        storage.beginEditing()
        for (lineIndex, kind) in kinds.enumerated() where kind.isDifferent {
            guard let range = lineRange(lineIndex), range.length > 0,
                  NSMaxRange(range) <= storage.length else { continue }
            if let color = SyntaxTheme.diffColor(for: kind) {
                storage.addAttribute(.backgroundColor, value: color, range: range)
                decoratedRanges.append(range)
            }
        }
        for (lineIndex, spans) in inline {
            guard let line = lineRange(lineIndex) else { continue }
            for span in spans {
                guard span.location >= 0, span.length > 0, span.location < line.length else { continue }
                let length = min(span.length, line.length - span.location)
                guard length > 0 else { continue }
                let target = NSRange(location: line.location + span.location, length: length)
                guard NSMaxRange(target) <= storage.length else { continue }
                storage.addAttribute(.backgroundColor, value: SyntaxTheme.diffInline, range: target)
                decoratedRanges.append(target)
            }
        }
        storage.endEditing()
        isApplyingDecoration = false
    }

    func clearDecoration() {
        if isPlainMode {
            plainView?.clearDecoration()
            return
        }
        guard let storage = textView.textStorage, !decoratedRanges.isEmpty else {
            decoratedRanges.removeAll()
            return
        }
        isApplyingDecoration = true
        storage.beginEditing()
        for range in decoratedRanges where NSMaxRange(range) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        storage.endEditing()
        isApplyingDecoration = false
        decoratedRanges.removeAll()
    }

    /// 含行尾换行的整行范围（让底色连成一条，不出现断点）
    private func lineRange(_ lineIndex: Int) -> NSRange? {
        guard lineIndex >= 0, lineIndex < lineStarts.count else { return nil }
        let start = lineStarts[lineIndex]
        let end = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] : (textView.string as NSString).length
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - 编辑

    func textDidChange(_ notification: Notification) {
        guard !isApplyingDecoration else { return }
        guard isEditable else { return }
        isDirty = true
        clearDecoration()          // 旧差异带立刻失效，等新一轮 diff 重贴
        rebuildLineIndex()
        gutter?.updateWidth(lineCount: lineStarts.count)
        gutter?.needsDisplay = true
        onDirtyChanged?()
        onEdited?()
    }

    // MARK: - 同步滚动

    /// 行高必须从 TextKit II 取：一旦碰 `textView.layoutManager`（TextKit 1 接口），
    /// AppKit 会把整个文本视图降级到兼容模式，`textLayoutManager` 直接变 nil，
    /// 行号栏再也拿不到布局片段（实测：行号整栏空白）。
    private static let metricsLayoutManager = NSLayoutManager()

    var lineHeight: CGFloat {
        if isPlainMode { return plainView?.lineHeight ?? 16 }
        let font = textView.font ?? SyntaxTheme.font
        if let layout = textView.textLayoutManager,
           let fragment = layout.textLayoutFragment(for: layout.documentRange.location) {
            let height = fragment.layoutFragmentFrame.height
            if height > 0 { return height }
        }
        let measured = Self.metricsLayoutManager.defaultLineHeight(for: font)
        return measured > 0 ? measured : 16
    }

    /// 视口顶部位置（行号 + 行内比例），用于跨栏映射
    var topLinePosition: Double {
        if isPlainMode { return plainView?.topLinePosition ?? 0 }
        let y = scrollView.contentView.bounds.origin.y - textView.textContainerOrigin.y
        return max(0, Double(y / max(lineHeight, 1)))
    }

    func scroll(toLinePosition position: Double) {
        if isPlainMode {
            plainView?.scroll(toLinePosition: position)
            return
        }
        let y = CGFloat(max(0, position)) * lineHeight + textView.textContainerOrigin.y
        let visibleHeight = scrollView.contentView.bounds.height
        let maxY = max(0, textView.frame.height - visibleHeight)
        let clamped = min(max(0, y), maxY)
        guard abs(clamped - scrollView.contentView.bounds.origin.y) > 0.5 else { return }
        isProgrammaticScroll = true
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isProgrammaticScroll = false
        gutter?.needsDisplay = true
    }

    // MARK: - 保存 / 快照

    @discardableResult
    func save() -> Bool {
        // 大文件模式是只读的（FR-12），不参与保存
        guard !isPlainMode, isEditable, let url = fileURL else { return false }
        do {
            try AtomicSaver.save(text: textView.string, to: url, encoding: encoding)
            isDirty = false
            onDirtyChanged?()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }
    }

    struct Snapshot {
        var text: String
        var url: URL?
        var encoding: FileEncoding
        var editable: Bool
        var linked: Bool
        var name: String
        var dirty: Bool
        var plain: Bool
    }

    func snapshot() -> Snapshot {
        Snapshot(text: text, url: fileURL, encoding: encoding,
                 editable: isEditable, linked: isLinkedDocument,
                 name: displayName, dirty: isDirty, plain: isPlainMode)
    }

    /// 交换两侧内容时复用：直接灌入另一侧的快照
    func restore(_ snapshot: Snapshot) {
        setContent(text: snapshot.text, url: snapshot.url, encoding: snapshot.encoding,
                   editable: snapshot.editable, linked: snapshot.linked,
                   name: snapshot.name, plainMode: snapshot.plain)
        isDirty = snapshot.dirty
        onDirtyChanged?()
    }

    func focusEditor() {
        if isPlainMode {
            plainView?.focusCanvas()
            return
        }
        window?.makeFirstResponder(textView)
    }

    func containsFirstResponder() -> Bool {
        if isPlainMode { return plainView?.containsFirstResponder() ?? false }
        guard let responder = window?.firstResponder else { return false }
        return responder === textView
    }

    /// 无头验证辅助：模拟用户滚动到第 N 行（1 基），走正常通知路径以验证联动
    func simulateUserScroll(toLine line: Int) {
        if isPlainMode {
            plainView?.simulateUserScroll(toLine: line)
            return
        }
        let y = CGFloat(max(0, line - 1)) * lineHeight + textView.textContainerOrigin.y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        gutter?.needsDisplay = true
    }

    /// 无头验证辅助：替换第 N 行（1 基）内容，走正常 insertText 路径，
    /// 以便触发 textDidChange → 实时重算链路
    func replaceLineForTesting(_ newLine: String, lineNumber: Int) {
        guard !isPlainMode, isEditable else { return }
        guard let range = lineRange(lineNumber - 1) else { return }
        var length = range.length
        if length > 0 {
            let ns = textView.string as NSString
            if ns.character(at: range.location + length - 1) == 10 { length -= 1 }
        }
        textView.insertText(newLine, replacementRange: NSRange(location: range.location, length: length))
    }
}

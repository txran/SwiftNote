import AppKit
import SwiftNoteKit

/// 纯文本只读面板（大文件模式）
///
/// 刻意**不进 TextKit**：`NSTextView` 会把整篇文本全量排版一次，
/// 百万行日志要几十秒且吃上 GB 内存。这里当成 `less` 用——
/// 固定行高、只画屏幕上那几十行，打开耗时与内存都不随文件增长。
///
/// 布局要点（两个踩过的坑）：
/// 1. 不能让「画布」自己撑成千万 pt 高。layer-backed 的 view 一旦 bounds
///    大到无法分配 backing store，`draw` 照常执行但结果被静默丢弃
///    （表现为整栏空白、无任何报错）。因此拆成 `spacer`（只有尺寸，
///    给 NSScrollView 提供滚动范围）+ `canvas`（永远一屏，盖在上面按偏移重绘）。
/// 2. 行号画在同一个 canvas 里，不另开一个固定 gutter 视图：
///    独立 gutter 的 draw 会被调用但结果上不了屏（同层合成问题），
///    而 canvas 已验证可正常绘制。行号带在 canvas 内按 x 固定，不参与横向滚动。
/// 3. canvas 必须铺在 scrollView 内部、并排在 clipView/scroller 之下，
///    clipView 也要换成不吃事件的子类——否则系统滚动条被画布整条盖掉，
///    而点击又会全被 clipView 吃掉（D-47）。
///
/// 代价（已记入设计说明书）：只读、无光标编辑、不做语法高亮。
///
/// 折行（v2.9）：面板不能进 TextKit，折行只能自己做——
/// 按可用宽度把逻辑行切成若干「视觉段」，每段占一个行高。
/// 滚动范围与位置用**平均段数**换算（不预扫全文，200MB 也只抽样 200 行），
/// 绘制与命中都按真实切段，所以内容连续、点选准确；只有滚动条的绝对位置是近似的
/// （大文件本来也不靠滚动条精确定位）。详见设计说明书 ADR D-46。
final class PlainTextPaneView: NSView {
    var onScrolled: (() -> Void)?
    /// 选区变化（状态栏行列号跟着走）
    var onSelectionChanged: (() -> Void)?

    /// 面板内的文本位置：逻辑行 + 行内 UTF-16 偏移
    struct TextPoint: Equatable {
        var row: Int
        var offset: Int
    }

    private let scrollView = NSScrollView()
    /// 只用于撑出滚动范围，不绘制任何内容
    private let spacer = FlippedSpacerView()
    private let canvas = PlainTextCanvasView()

    private var index: LineIndex?
    private var kinds: [DiffLineKind] = []
    private var inlineRanges: [Int: [NSRange]] = [:]
    private(set) var selectedLine: Int?
    /// 拖选产生的范围选区（anchor→head，未排序）；为 nil 或起止相同时表示「只有光标所在行」
    private var selection: (anchor: TextPoint, head: TextPoint)?

    let textInset: CGFloat = 6
    private(set) lazy var lineHeight: CGFloat = {
        let measured = Self.metricsLayoutManager.defaultLineHeight(for: SyntaxTheme.font)
        return ceil(measured) + 1
    }()
    private static let metricsLayoutManager = NSLayoutManager()

    var text: String { index?.text ?? "" }
    var lineCount: Int { index?.count ?? 0 }

    // MARK: - 折行状态

    private(set) var wrapsLines = false
    /// 一行平均占几条视觉行。只用于「滚动范围 / 位置 ↔ 逻辑行」的换算；
    /// 绘制与命中一律按真实切段，所以估算偏差不会让内容错位，只影响滚动条刻度
    private var wrapSegmentsEstimate: CGFloat = 1
    /// 折行可用宽度（正文区，不含冻结行号带）
    private var wrapUsableWidth: CGFloat {
        max(40, scrollView.contentView.bounds.width - gutterWidth - textInset * 2)
    }
    /// 一个逻辑行占的滚动高度：折行时按平均段数放大，否则就是一行
    var rowStride: CGFloat {
        wrapsLines ? lineHeight * max(1, wrapSegmentsEstimate) : lineHeight
    }

    var verticalOffset: CGFloat { scrollView.contentView.bounds.origin.y }
    var horizontalOffset: CGFloat { scrollView.contentView.bounds.origin.x }
    var visibleHeight: CGFloat { scrollView.contentView.bounds.height }

    /// 行号带宽度（随位数变化，6 位数 ≈ 60pt）
    private(set) lazy var gutterWidth: CGFloat = 44
    private var knownContentWidth: CGFloat = 0
    /// 折行时用来发现「视口宽变了，段数要重算」
    private var lastViewportWidth: CGFloat = 0

    // MARK: - 初始化

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        // NSView 默认不裁剪子视图：canvas 一旦画到 bounds 之外，会盖住标签栏/状态栏。
        // 这里显式开图层并裁剪（TextKit 侧也有同样要求，见设计说明书 D-24）。
        wantsLayer = true
        layer?.masksToBounds = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // 背景由画布自己画：画布铺在 clipView 下面（见下），clipView 一旦画背景
        // 就会把自己的底色盖在画布上，整栏变成纯色块
        scrollView.drawsBackground = false
        // 画布在 clipView 之下，鼠标事件会先落到 clipView；它只负责滚动，
        // 不该吃事件（否则点击/拖选永远到不了画布）
        scrollView.contentView = PassthroughClipView()
        addSubview(scrollView)
        scrollView.documentView = spacer

        canvas.pane = self
        // 画布必须挂在 scrollView 内部、且排在 clipView 与 scroller 之下（见 D-47）。
        // 原来挂在 pane 上（层级高于整个 scrollView），而宽度取自内容区 frame，
        // 布局时 tile 还没把滚动条宽度让出去 → 15pt 的滚动条被画布整条压住：
        // isHidden=false、alpha=1，屏幕上一个像素都没有
        scrollView.addSubview(canvas, positioned: .below, relativeTo: nil)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // 画布盖住内容区，坐标直接用内容区 frame。它在 clipView 与 scroller 之下，
        // 所以系统滚动条能正常画在正文之上、也能被拖动（D-47）。
        // 注意 tile 之前取到的 frame 会比内容区宽十几 pt，多出的部分正好落在
        // 滚动条槽下面，被槽遮住，不影响观感
        canvas.frame = scrollView.contentView.frame
        // NSScrollView 在 tile 时可能调整子视图顺序，每次布局把画布压回滚动条之下
        placeCanvasBelowClipView()

        let width = scrollView.contentView.bounds.width
        if wrapsLines, abs(width - lastViewportWidth) > 1 {
            // 视口宽变了 → 可用宽度变了 → 段数全变。按顶行锚点重排，别让视口跳走
            lastViewportWidth = width
            let anchor = topLinePosition
            wrapSegmentsEstimate = estimateWrapSegments()
            updateSpacerSize()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(max(0, anchor)) * rowStride))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            canvas.needsDisplay = true
            return
        }
        lastViewportWidth = width
        updateSpacerSize()
    }

    @objc private func viewportChanged() {
        canvas.needsDisplay = true
        onScrolled?()
    }

    /// 画布必须待在 clipView（以及压在它上面的系统滚动条）之**下**：
    /// 系统滚动条是 scrollView 的内部视图，画布只要盖在它上面就会把它整条遮掉。
    /// NSScrollView 在 tile 时可能重排子视图，所以每次布局校验一次；
    /// 已经在下层就不动，避免反复重排子视图
    private func placeCanvasBelowClipView() {
        let subviews = scrollView.subviews
        guard let canvasIndex = subviews.firstIndex(of: canvas),
              let clipIndex = subviews.firstIndex(of: scrollView.contentView),
              canvasIndex > clipIndex else { return }
        scrollView.addSubview(canvas, positioned: .below, relativeTo: scrollView.contentView)
    }

    // MARK: - 内容

    func setContent(text: String) {
        setContent(index: LineIndex(text: text))
    }

    /// 接受已建好的索引：主编辑器打开 200MB 时，建索引要 1~2 秒，
    /// 必须在后台做，不能压在主线程（对比窗口沿用上面的 `setContent(text:)`）
    func setContent(index: LineIndex) {
        self.index = index
        kinds = []
        inlineRanges = [:]
        selectedLine = nil
        selection = nil
        gutterWidth = Self.gutterWidth(forLineCount: index.count)
        knownContentWidth = estimatedContentWidth
        if wrapsLines { wrapSegmentsEstimate = estimateWrapSegments() }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateSpacerSize()
        canvas.needsDisplay = true
    }

    func applyDiff(kinds: [DiffLineKind], inline: [Int: [NSRange]]) {
        self.kinds = kinds
        self.inlineRanges = inline
        canvas.needsDisplay = true
    }

    func clearDecoration() {
        kinds = []
        inlineRanges = [:]
        canvas.needsDisplay = true
    }

    // MARK: - 供 canvas 读取

    func line(_ row: Int) -> Substring? {
        guard let index, row >= 0, row < index.count else { return nil }
        return index.line(row)
    }

    func kind(at row: Int) -> DiffLineKind {
        guard row >= 0, row < kinds.count else { return .equal }
        return kinds[row]
    }

    func inlineSpans(at row: Int) -> [NSRange]? {
        inlineRanges[row]
    }

    private static func gutterWidth(forLineCount count: Int) -> CGFloat {
        let charWidth = ("0" as NSString).size(withAttributes: SyntaxTheme.baseAttributes).width
        let digits = max(2, String(max(1, count)).count)
        return CGFloat(digits) * charWidth + 14
    }

    // MARK: - 折行

    /// 开/关折行。切换时按逻辑行位置保持视口不跳（滚动单位从「一行」变成「平均 N 行」）
    func applyWrap(_ enabled: Bool) {
        guard enabled != wrapsLines else { return }
        let anchorRow = topLinePosition
        wrapsLines = enabled
        scrollView.hasHorizontalScroller = !enabled
        if enabled {
            wrapSegmentsEstimate = estimateWrapSegments()
            scrollView.contentView.scroll(to: NSPoint(x: 0,
                                                      y: CGFloat(max(0, anchorRow)) * rowStride))
        } else {
            wrapSegmentsEstimate = 1
            scrollView.contentView.scroll(to: NSPoint(x: horizontalOffset,
                                                      y: CGFloat(max(0, anchorRow)) * rowStride))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateSpacerSize()
        canvas.needsDisplay = true
    }

    /// 抽样估平均段数：全量测量 15 万行要 1.2s（中文 5s），只有滚动刻度需要它，抽样足够
    private func estimateWrapSegments() -> CGFloat {
        guard let index, index.count > 0 else { return 1 }
        let usable = wrapUsableWidth
        let step = max(1, index.count / 200)
        var total = 0
        var samples = 0
        var row = 0
        while row < index.count, samples < 200 {
            let width = (index.line(row) as NSString)
                .size(withAttributes: SyntaxTheme.baseAttributes).width
            total += max(1, Int(ceil(width / usable)))
            samples += 1
            row += step
        }
        guard samples > 0 else { return 1 }
        return max(1, CGFloat(total) / CGFloat(samples))
    }

    /// 把一行切成若干视觉段，返回每段起始 utf16 偏移（末尾是行长度）。
    /// 只在可见行上调用（每段一次二分测量），不要拿去扫全文
    func wrapSlices(forRow row: Int) -> [Int] {
        guard let index, row >= 0, row < index.count else { return [0] }
        let text = index.line(row) as NSString
        guard text.length > 0 else { return [0] }
        let usable = wrapUsableWidth
        let attrs = SyntaxTheme.baseAttributes
        guard text.size(withAttributes: attrs).width > usable else { return [0, text.length] }

        var slices: [Int] = [0]
        var start = 0
        while start < text.length {
            let remaining = NSRange(location: start, length: text.length - start)
            if text.substring(with: remaining).size(withAttributes: attrs).width <= usable {
                slices.append(text.length)
                break
            }
            // 二分找「放得下的最长前缀」
            var low = start + 1
            var high = text.length
            while low < high {
                let mid = (low + high + 1) / 2
                let width = text.substring(with: NSRange(location: start, length: mid - start))
                    .size(withAttributes: attrs).width
                if width <= usable { low = mid } else { high = mid - 1 }
            }
            if low <= start { low = start + 1 }   // 单字符就超宽（超长无空格串）也要前进
            slices.append(low)
            start = low
        }
        if slices.last != text.length { slices.append(text.length) }
        return slices
    }

    /// 折行时视口顶部的逻辑行号（可能带小数，代表行内已滚过的比例）
    var wrappedTopRowPosition: Double {
        Double(verticalOffset / max(rowStride, 1))
    }

    // MARK: - 尺寸

    private func updateSpacerSize() {
        guard scrollView.contentView.bounds.width > 0 else { return }
        // 内容区宽度不含行号带（行号带是冻结列，不参与横向滚动）
        let viewportContentWidth = max(0, scrollView.contentView.bounds.width)
        // 折行时正文永远不超过视口宽，不需要横向滚动
        let width = wrapsLines ? viewportContentWidth
                               : max(viewportContentWidth, gutterWidth + knownContentWidth)
        let height = max(CGFloat(lineCount) * rowStride, scrollView.contentView.bounds.height)
        let target = NSSize(width: width, height: height)
        guard abs(spacer.frame.width - target.width) > 1
                || abs(spacer.frame.height - target.height) > 1 else { return }
        spacer.setFrameSize(target)
    }

    /// 千万行文件不可能全扫，日志/配置行宽高度一致，抽样足够；
    /// 绘制时若发现更长的可见行还会再扩（只增不减）
    private var estimatedContentWidth: CGFloat {
        guard let index, index.count > 0 else { return 0 }
        let charWidth = ("0" as NSString).size(withAttributes: SyntaxTheme.baseAttributes).width
        var maxUnits = 0
        let step = max(1, index.count / 2000)
        var row = 0
        while row < index.count {
            let units = index.line(row).utf16.count
            if units > maxUnits { maxUnits = units }
            row += step
        }
        return CGFloat(maxUnits) * charWidth + textInset * 2 + 8
    }

    func growContentWidthIfNeeded(to width: CGFloat) {
        guard width > knownContentWidth + 1 else { return }
        knownContentWidth = width
        DispatchQueue.main.async { [weak self] in self?.updateSpacerSize() }
    }

    // MARK: - 同步滚动

    var topLinePosition: Double {
        Double(verticalOffset / max(rowStride, 1))
    }

    func scroll(toLinePosition position: Double) {
        let y = CGFloat(max(0, position)) * rowStride
        let maxY = max(0, spacer.frame.height - visibleHeight)
        let clamped = min(max(0, y), maxY)
        guard abs(clamped - verticalOffset) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: horizontalOffset, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.needsDisplay = true
    }

    func focusCanvas() {
        window?.makeFirstResponder(canvas)
    }

    func containsFirstResponder() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === canvas
    }

    /// 无头验证辅助：模拟用户滚动到第 N 行（1 基）
    func simulateUserScroll(toLine line: Int) {
        scroll(toLinePosition: Double(max(0, line - 1)))
    }

    /// 无头截图用：让系统滚动条亮一会儿。
    /// overlay 风格默认「滚动时显示、随后淡出」，程序化滚动不会自动 flash
    func flashScrollers() {
        scrollView.flashScrollers()
    }

    /// 无头验证辅助：当前视口顶行（1 基）
    var topLineForTesting: Int { Int(topLinePosition.rounded(.down)) + 1 }

    // MARK: - 选区（只读面板也要能选中、复制）

    /// 归一化后的选区（start 在前）；起止相同视为「没有范围选区」
    func selectionRange() -> (start: TextPoint, end: TextPoint)? {
        guard let selection else { return nil }
        let a = selection.anchor
        let b = selection.head
        let ordered = (a.row, a.offset) <= (b.row, b.offset) ? (a, b) : (b, a)
        guard ordered.0 != ordered.1 else { return nil }
        return (ordered.0, ordered.1)
    }

    /// 选区文本。没有范围选区时回退到光标所在整行——
    /// 大文件面板原来的「点一行按 ⌘C 复制整行」行为要保住
    func selectedText() -> String? {
        guard let index else { return nil }
        guard let range = selectionRange() else {
            guard let row = selectedLine, row < index.count else { return nil }
            return String(index.line(row))
        }
        var parts: [String] = []
        // 同一行内选一段（折行后拖选半行很常见）：直接截取，别按「首行到尾」拼两遍
        if range.start.row == range.end.row {
            let text = index.line(range.start.row) as NSString
            let from = min(max(0, range.start.offset), text.length)
            let to = min(max(0, range.end.offset), text.length)
            guard to > from else { return nil }
            return text.substring(with: NSRange(location: from, length: to - from))
        }
        let firstLine = index.line(range.start.row)
        if let start = utf16Index(in: firstLine, offset: range.start.offset) {
            parts.append(String(firstLine[start...]))
        }
        if range.end.row > range.start.row + 1 {
            for row in (range.start.row + 1)..<range.end.row {
                parts.append(String(index.line(row)))
            }
        }
        let lastLine = index.line(range.end.row)
        if let end = utf16Index(in: lastLine, offset: range.end.offset) {
            parts.append(String(lastLine[..<end]))
        }
        return parts.joined(separator: "\n")
    }

    /// 状态栏行列号（1 基）；没有选区也没有光标行时返回 nil
    var caretPosition: (line: Int, column: Int)? {
        if let head = selection?.head { return (head.row + 1, head.offset + 1) }
        if let row = selectedLine { return (row + 1, 1) }
        return nil
    }

    func setSelection(anchor: TextPoint, head: TextPoint) {
        selection = (anchor, head)
        selectedLine = head.row
        canvas.needsDisplay = true
        onSelectionChanged?()
    }

    /// 拖动时保持 anchor 不动，只挪 head
    func extendSelection(to point: TextPoint) {
        guard let anchor = selection?.anchor else {
            setSelection(anchor: point, head: point)
            return
        }
        setSelection(anchor: anchor, head: point)
    }

    func clearSelection() {
        selection = nil
        selectedLine = nil
        canvas.needsDisplay = true
        onSelectionChanged?()
    }

    /// 行内偏移的像素宽度（从行首算起），画选区与命中测试共用
    func offsetWidth(inRow row: Int, offset: Int) -> CGFloat {
        guard let index, row >= 0, row < index.count else { return 0 }
        let text = index.line(row) as NSString
        let clamped = min(max(0, offset), text.length)
        guard clamped > 0 else { return 0 }
        return text.substring(to: clamped).size(withAttributes: SyntaxTheme.baseAttributes).width
    }

    /// canvas 坐标 → 文本位置
    func textPoint(atCanvasPoint point: NSPoint) -> TextPoint? {
        guard let index, index.count > 0 else { return nil }
        if wrapsLines { return wrappedTextPoint(at: point, index: index) }
        let rawRow = Int(floor((point.y + verticalOffset) / lineHeight))
        let row = min(max(0, rawRow), index.count - 1)
        let text = index.line(row) as NSString
        let x = point.x + horizontalOffset - gutterWidth - textInset
        return TextPoint(row: row, offset: column(in: text, atX: x))
    }

    /// 折行状态下的命中：从视口顶行往下累加真实段高，找落在哪一行第几段。
    /// 起点与累加方式必须和绘制完全一致（都从 `floor(offsetY/stride)*stride` 起算），
    /// 否则点哪儿选哪儿会整体偏移
    private func wrappedTextPoint(at point: NSPoint, index: LineIndex) -> TextPoint? {
        let lh = lineHeight
        var row = min(max(0, Int(floor(verticalOffset / max(rowStride, 1)))), index.count - 1)
        var y = CGFloat(row) * rowStride - verticalOffset
        var steps = 0
        while row < index.count {
            let slices = wrapSlices(forRow: row)
            let bandHeight = CGFloat(max(1, slices.count - 1)) * lh
            if point.y < y + bandHeight || row == index.count - 1 {
                let within = max(0, min(point.y - y, bandHeight - 1))
                let seg = min(max(0, Int(floor(within / lh))), max(0, slices.count - 2))
                let text = index.line(row) as NSString
                let lower = slices[seg]
                let upper = slices[seg + 1]
                let x = point.x - gutterWidth - textInset
                return TextPoint(row: row, offset: column(in: text, atX: x, within: lower..<upper))
            }
            y += bandHeight
            row += 1
            steps += 1
            if steps > 5000 { break }   // 防御：估算严重偏差时不要死循环
        }
        return nil
    }

    /// 等宽字体下中英宽度不同，命中列要靠二分前缀宽度，不能拿单字宽度除
    private func column(in text: NSString, atX x: CGFloat) -> Int {
        column(in: text, atX: x, within: 0..<text.length)
    }

    /// 折行的每一段都从行首重新对齐绘制，所以命中只在本段范围内二分
    private func column(in text: NSString, atX x: CGFloat, within range: Range<Int>) -> Int {
        guard x > 0 else { return range.lowerBound }
        guard range.count > 0 else { return range.lowerBound }
        let slice = text.substring(with: NSRange(location: range.lowerBound, length: range.count))
        if x >= slice.size(withAttributes: SyntaxTheme.baseAttributes).width {
            return range.upperBound
        }
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let mid = (low + high + 1) / 2
            let width = text.substring(with: NSRange(location: range.lowerBound,
                                                     length: mid - range.lowerBound))
                .size(withAttributes: SyntaxTheme.baseAttributes).width
            if width <= x { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func utf16Index(in line: Substring, offset: Int) -> String.Index? {
        let clamped = min(max(0, offset), line.utf16.count)
        return String.Index(utf16Offset: clamped, in: line)
    }

    /// 拖动到视口上下边缘时按行滚动（折行时「一行」= 平均段高，滚得动才跟得上）
    func autoScroll(byLines delta: CGFloat) {
        let maxY = max(0, spacer.frame.height - visibleHeight)
        let target = min(max(0, verticalOffset + delta * rowStride), maxY)
        guard abs(target - verticalOffset) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: horizontalOffset, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let index, index.count > 0 else { return }
        let lastRow = index.count - 1
        setSelection(anchor: TextPoint(row: 0, offset: 0),
                     head: TextPoint(row: lastRow, offset: index.line(lastRow).utf16.count))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return selectedText() != nil
        case #selector(selectAll(_:)): return lineCount > 0
        default: return true
        }
    }

    /// 无头核对用：选区与行列
    func selectionSummary() -> String {
        let range = selectionRange()
        let span = range.map { "\($0.start.row):\($0.start.offset) → \($0.end.row):\($0.end.offset)" } ?? "无范围选区"
        let head = caretPosition.map { "行\($0.line)列\($0.column)" } ?? "无光标"
        return "\(span) · \(head) · 选中 \(selectedText()?.utf16.count ?? 0) 单元"
    }

    /// 无头核对用：绘制宽度 → 命中列 的往返一致性
    /// （拖选靠 `textPoint(atCanvasPoint:)`，画靠 `offsetWidth`，两者必须互逆，否则选出来会偏字）
    func hitTestSummary() -> String {
        guard let index, index.count > 0 else { return "无内容" }
        var parts: [String] = []
        // 以视口顶行为基准：滚动后再测才有意义（canvas 坐标里 y=0 是视口顶）
        let base = wrapsLines ? min(max(0, Int(floor(verticalOffset / max(rowStride, 1)))),
                                    max(0, index.count - 1)) : 0
        for delta in [0, 2] {
            let row = base + delta
            guard row < index.count else { continue }
            let length = index.line(row).utf16.count
            for offset in [0, 10, min(40, length), min(200, length)] where offset <= length {
                var x = offsetWidth(inRow: row, offset: offset) + gutterWidth + textInset
                var y = CGFloat(row) * lineHeight + lineHeight / 2 - verticalOffset
                if wrapsLines {
                    // 折行后：先找 offset 落在第几段，段内从行首重新对齐
                    let slices = wrapSlices(forRow: row)
                    var seg = 0
                    for k in 0..<max(1, slices.count - 1) where offset >= slices[k] { seg = k }
                    let lower = slices[seg]
                    x = offsetWidth(inRow: row, offset: offset)
                        - offsetWidth(inRow: row, offset: lower)
                        + gutterWidth + textInset
                    y = visualTop(forRow: row) + CGFloat(seg) * lineHeight + lineHeight / 2
                }
                let hit = textPoint(atCanvasPoint: NSPoint(x: x, y: y))
                let result = hit.map { "\($0.row + 1):\($0.offset)" } ?? "nil"
                let expected = "\(row + 1):\(offset)"
                parts.append("\(expected)→x\(Int(x))→\(result)\(result == expected ? "✓" : "✗")")
            }
        }
        return parts.joined(separator: " ")
    }

    /// 某逻辑行第一段的顶边（canvas 坐标，已减去视口偏移）。只给核对/定位用，
    /// 从视口顶行往下累加真实段高，与绘制顺序一致
    func visualTop(forRow target: Int) -> CGFloat {
        guard wrapsLines else { return CGFloat(target) * lineHeight - verticalOffset }
        var row = min(max(0, Int(floor(verticalOffset / max(rowStride, 1)))), max(0, target))
        var y = CGFloat(row) * rowStride - verticalOffset
        while row < target {
            y += CGFloat(max(1, wrapSlices(forRow: row).count - 1)) * lineHeight
            row += 1
        }
        return y
    }

    /// 无头核对用：按行/列模拟一次拖选（0 基），并走一遍 copy
    func simulateDragSelection(startRow: Int, startColumn: Int,
                               endRow: Int, endColumn: Int) -> String {
        setSelection(anchor: TextPoint(row: startRow, offset: startColumn),
                     head: TextPoint(row: endRow, offset: endColumn))
        copy(nil)
        let pasted = NSPasteboard.general.string(forType: .string) ?? "nil"
        let oneLine = pasted.replacingOccurrences(of: "\n", with: "⏎")
        let preview = oneLine.count <= 120 ? oneLine : String(oneLine.prefix(120)) + "…"
        return "\(selectionSummary()) · 剪贴板=「\(preview)」"
    }

    func select(line row: Int?) {
        guard let row else { clearSelection(); return }
        setSelection(anchor: TextPoint(row: row, offset: 0), head: TextPoint(row: row, offset: 0))
    }

    /// 无头核对用：滚动条层级与几何。
    /// 画布一旦排到 scroller 之上，滚动条就被整条盖住（只读大文件曾踩过）
    func scrollerDiagnostics() -> String {
        let names = scrollView.subviews.map { view -> String in
            let name: String
            if view === canvas { name = "canvas" }
            else if view === scrollView.contentView { name = "clipView" }
            else if let v = scrollView.verticalScroller, view === v { name = "vScroller" }
            else if let h = scrollView.horizontalScroller, view === h { name = "hScroller" }
            else { name = String(describing: type(of: view)) }
            return "\(name)\(view.frame)"
        }
        let v = scrollView.verticalScroller
        let style = (v?.scrollerStyle == .legacy) ? "legacy" : "overlay"
        let visible = v.map { !$0.isHidden && $0.alphaValue > 0.01 } ?? false
        // 命中核对：走窗口级 hitTest（与真实事件派发同一入口），
        // 期望落到画布上——不落到画布，点击选中就全废了
        let windowPoint = canvas.convert(NSPoint(x: 200, y: 60), to: nil)
        let hit = window?.contentView?.hitTest(windowPoint)
        let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"
        return "顺序=\(names.joined(separator: "‹"))"
            + " 风格=\(style) 可见=\(visible)"
            + " vFrame=\(v.map { "\($0.frame)" } ?? "nil")"
            + " canvas=\(canvas.frame) 内容区=\(scrollView.contentView.frame)"
            + " 命中=\(hitName)(期望 PlainTextCanvasView)"
    }

    func forwardScroll(to event: NSEvent) {
        scrollView.scrollWheel(with: event)
        // 事件是从画布转进来的，AppKit 不认为「鼠标正压在滚动区域内」，
        // overlay 风格下补一次 flash，保证滚动时右侧那条滚动条真的出现
        if scrollView.verticalScroller?.scrollerStyle == .overlay,
           (scrollView.verticalScroller?.alphaValue ?? 0) < 0.99 {
            scrollView.flashScrollers()
        }
    }

    /// 无头验证辅助：把构造好的滚轮事件交给画布（走真实转发路径）
    func simulateScrollWheel(_ event: NSEvent) {
        canvas.scrollWheel(with: event)
    }

    func row(atViewPoint point: NSPoint) -> Int? {
        if wrapsLines {
            let canvasPoint = NSPoint(x: point.x - gutterWidth - textInset, y: point.y)
            return textPoint(atCanvasPoint: canvasPoint)?.row
        }
        let row = Int(floor((point.y + verticalOffset) / lineHeight))
        guard row >= 0, row < lineCount else { return nil }
        return row
    }
}

// MARK: - 只有尺寸的空视图

private final class FlippedSpacerView: NSView {
    override var isFlipped: Bool { true }
    /// 空的、绝不绘制：唯一职责是给 NSScrollView 提供内容大小
    override func draw(_ dirtyRect: NSRect) {}
}

// MARK: - 不吃事件的 clipView

/// 画布铺在 clipView 下面（为了让系统滚动条压在正文之上），
/// 于是鼠标事件会先被 clipView 接住。clipView 只负责滚动，
/// 这里让它整体透传，点击/拖选才会落到画布上。
/// 注意：滚轮由画布自己转发给 scrollView（见 `PlainTextCanvasView.scrollWheel`）。
private final class PassthroughClipView: NSClipView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 画布（永远一屏，含冻结行号带）

private final class PlainTextCanvasView: NSView {
    weak var pane: PlainTextPaneView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // dynamic NSColor（`NSColor(name:)` 那套）必须在明确的 appearance 下解析：
        // 直接 setFill 时当前 appearance 为空，解析失败会静默回退成无色，
        // 表现为「代码执行了、像素没变」。这里统一套一层。
        guard let appearance = window?.effectiveAppearance
                ?? NSAppearance(named: .aqua) else {
            drawContent(dirtyRect)
            return
        }
        appearance.performAsCurrentDrawingAppearance {
            drawContent(dirtyRect)
        }
    }

    private func drawContent(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let pane, pane.lineCount > 0 else { return }

        let lineHeight = pane.lineHeight
        let offsetY = pane.verticalOffset
        let offsetX = pane.horizontalOffset
        let gutter = pane.gutterWidth
        let wrapped = pane.wrapsLines
        let stride = pane.rowStride

        // 顶行与命中用同一个公式：先按「平均行宽」定位到行，再从该行的真实顶边往下累加
        let firstRow = max(0, Int(floor(offsetY / max(stride, 1))))
        var row = firstRow
        var top = CGFloat(firstRow) * stride - offsetY

        var widest: CGFloat = 0
        // 行号要等背景带盖完再画，先把每行的顶边记住
        var gutterTops: [(row: Int, top: CGFloat)] = []
        // 有范围选区时按精确区间上色；只有光标行时退化成整行淡色（点一下选整行的老行为）
        let selectedRange = pane.selectionRange()

        while row < pane.lineCount {
            if top >= bounds.height { break }
            let rowLine = pane.line(row)
            let length = rowLine?.utf16.count ?? 0
            // 未折行时整行就是一段；折行时按可用宽度真实切段（只算可见行）
            let slices = wrapped ? pane.wrapSlices(forRow: row) : [0, length]
            let segCount = max(1, slices.count - 1)
            let bandHeight = CGFloat(segCount) * lineHeight

            let band = NSRect(x: gutter, y: top, width: bounds.width - gutter, height: bandHeight)
            // 差异底色与选中底色是两层，不能写成 else if（否则选中一行就看不到它是差异行）
            if let color = SyntaxTheme.diffColor(for: pane.kind(at: row)) {
                color.setFill()
                band.fill()
            }
            if let selectedRange, row >= selectedRange.start.row, row <= selectedRange.end.row {
                let startOffset = row == selectedRange.start.row
                    ? min(selectedRange.start.offset, length) : 0
                let endOffset = row == selectedRange.end.row
                    ? min(selectedRange.end.offset, length) : length
                if endOffset > startOffset {
                    let color = NSColor.selectedTextBackgroundColor
                    color.setFill()
                    for seg in 0..<segCount {
                        let lower = slices[seg]
                        let upper = slices[seg + 1]
                        let from = max(lower, startOffset)
                        let to = min(upper, endOffset)
                        guard to > from else { continue }
                        // 每段从行首重新对齐，所以宽度要减掉段起点
                        let base = wrapped ? pane.offsetWidth(inRow: row, offset: lower) : 0
                        let x1 = pane.offsetWidth(inRow: row, offset: from) - base
                        let x2 = pane.offsetWidth(inRow: row, offset: to) - base
                        NSRect(x: gutter + pane.textInset - (wrapped ? 0 : offsetX) + x1,
                               y: top + CGFloat(seg) * lineHeight,
                               width: max(1, x2 - x1), height: lineHeight).fill()
                        if ProcessInfo.processInfo.environment["SWIFTNOTE_PLAIN_DRAW_DEBUG"] != nil {
                            AppLogger.info("PLAIN DRAW 行\(row) 段\(seg) x=\(gutter + pane.textInset + x1)"
                                + " 宽=\(max(1, x2 - x1)) 段范围=\(lower)..<\(upper)"
                                + " keyWindow=\(window?.isKeyWindow ?? false)")
                        }
                    }
                }
            } else if row == pane.selectedLine {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
                band.fill()
            }

            if let rowLine, !rowLine.isEmpty {
                let ns = rowLine as NSString
                for seg in 0..<segCount {
                    let lower = slices[seg]
                    let upper = slices[seg + 1]
                    guard upper > lower else { continue }
                    let piece = ns.substring(with: NSRange(location: lower, length: upper - lower))
                    let attributed = NSMutableAttributedString(string: piece,
                                                               attributes: SyntaxTheme.baseAttributes)
                    if let spans = pane.inlineSpans(at: row), !spans.isEmpty {
                        let pieceLength = attributed.length
                        for span in spans where span.length > 0 {
                            // 差异行内高亮是全行坐标，要裁到本段并换算成段内偏移
                            let from = max(lower, span.location)
                            let to = min(upper, NSMaxRange(span))
                            guard to > from else { continue }
                            let local = NSRange(location: from - lower, length: to - from)
                            guard NSMaxRange(local) <= pieceLength else { continue }
                            attributed.addAttribute(.backgroundColor,
                                                    value: SyntaxTheme.diffInline, range: local)
                        }
                    }
                    let size = attributed.size()
                    if !wrapped, size.width > widest { widest = size.width }
                    // draw(at:) 单行绘制：折行后的每段就是一次单行绘制；
                    // 未折行时超宽部分溢出到右侧由视口裁掉，横向滚动时整体平移
                    attributed.draw(at: NSPoint(x: gutter + pane.textInset - (wrapped ? 0 : offsetX),
                                                y: top + CGFloat(seg) * lineHeight
                                                    + max(0, (lineHeight - size.height) / 2)))
                }
            }

            gutterTops.append((row, top))
            top += bandHeight
            row += 1
        }

        // 行号带背景与分隔线画在正文之后，保证压在滚动内容上面
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: gutter, height: bounds.height).fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setFill()
        NSRect(x: gutter - 1, y: 0, width: 1, height: bounds.height).fill()

        // 行号带重画（刚才被背景盖住）；折行时行号只标在逻辑行的第一段
        for entry in gutterTops {
            if ProcessInfo.processInfo.environment["SWIFTNOTE_PLAIN_DRAW_DEBUG"] != nil, entry.row < 3 {
                AppLogger.info("PLAIN GUTTER 行\(entry.row + 1) top=\(entry.top)"
                    + " lineHeight=\(lineHeight) offsetY=\(offsetY) bounds=\(bounds)")
            }
            let numberText = "\(entry.row + 1)" as NSString
            let numberAttrs: [NSAttributedString.Key: Any] = entry.row == pane.selectedLine
                ? [.font: SyntaxTheme.font, .foregroundColor: NSColor.labelColor]
                : [.font: SyntaxTheme.font, .foregroundColor: NSColor.tertiaryLabelColor]
            let numberSize = numberText.size(withAttributes: numberAttrs)
            numberText.draw(at: NSPoint(x: max(1, gutter - numberSize.width - 7),
                                        y: entry.top + max(0, (lineHeight - numberSize.height) / 2)),
                            withAttributes: numberAttrs)
        }

        // 折行时正文不超出视口，不需要横向滚动
        if !wrapped, widest + pane.textInset * 2 + 8 + offsetX > bounds.width - gutter + 1 {
            pane.growContentWidthIfNeeded(to: widest + pane.textInset * 2 + 8 + offsetX)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let pane else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let target = pane.textPoint(atCanvasPoint: point) else {
            pane.clearSelection()
            return
        }
        if event.modifierFlags.contains(.shift), let range = pane.selectionRange() {
            // Shift 点击：从原选区起点扩到点击处
            pane.setSelection(anchor: range.start, head: target)
        } else {
            pane.setSelection(anchor: target, head: target)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pane else { return }
        var point = convert(event.locationInWindow, from: nil)
        // 拖出视口时自动滚动，否则选了半屏就选不动了
        if point.y < 0 {
            pane.autoScroll(byLines: -1)
        } else if point.y > bounds.height - 1 {
            pane.autoScroll(byLines: 1)
        }
        point.y = min(max(0, point.y), max(0, bounds.height - 1))
        guard let target = pane.textPoint(atCanvasPoint: point) else { return }
        pane.extendSelection(to: target)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pane else { return nil }
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(PlainTextPaneView.copy(_:)),
                                  keyEquivalent: "c")
        copyItem.target = pane
        menu.addItem(copyItem)
        let selectAllItem = NSMenuItem(title: "全选", action: #selector(PlainTextPaneView.selectAll(_:)),
                                       keyEquivalent: "a")
        selectAllItem.target = pane
        menu.addItem(selectAllItem)
        return menu
    }

    /// canvas 盖在 scrollView 上，滚轮事件必须手动转发
    override func scrollWheel(with event: NSEvent) {
        pane?.forwardScroll(to: event)
    }
}

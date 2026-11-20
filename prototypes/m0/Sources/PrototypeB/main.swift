// PrototypeB — M0 原型 B：多行标签自绘控件验证（RK-02）
// 配套 docs/M0-技术预研任务书.md 第四节实测项 B-1 ~ B-6
// 运行：swift run --package-path prototypes/m0 --disable-sandbox PrototypeB
//
// v2 改进（借鉴 SwiftDown 项目 TabBarLayout / TabBarView 的做法）：
//   1. 变量宽度标签：按文件名实测宽度自适应（min 160 / max 240）
//   2. flow 分行算法（等价 SwiftUI Layout 的 TabFlowLayout）
//   3. easeOut 隐式动画曲线（对齐 SwiftUI 默认手感）
//   4. hover 高亮 + 活跃标签 macOS 原生观感
// v2.1 布局修复：isFlipped 自上而下坐标系 + 自绘裁剪行（不用 NSScrollView）
// v3 新增两个可调项（回答「只能三行吗 / 能不能等比压缩」）：
//   5. 行数上限可调 1~6（默认 3，对应 PRD FR-02；其余值用于验证「更多行」的代价）
//   6. 拥挤时等比压缩开关：所有标签按同一比例缩到刚好放进上限行数，缩到最小宽度
//      仍放不下才折叠到最后一行横向滚动 + 溢出计数
//
// 验证点：B-1 换行布局 / B-2 跨行拖拽 / B-3 增删切换 / B-4 行高动画 / B-5 100+ / B-6 窗口缩放

import AppKit

@inline(__always) func monoFont(_ size: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

// MARK: - 偏好设置（对应设计说明书 4.4，正式版从设置窗口读写）

/// 原型用独立 UserDefaults 域模拟正式版偏好设置：改完即存，重启保持
enum AppSettings {
    private static let store = UserDefaults(suiteName: "cn.swiftnote.prototype") ?? .standard
    private static let maxTabRowsKey = "maxTabRows"

    /// 标签行数上限：默认 5，范围 1~6
    static var maxTabRows: Int {
        get {
            let raw = store.object(forKey: maxTabRowsKey) as? Int ?? 5
            return min(max(raw, 1), TabBarContainerView.rowLimitMax)
        }
        set {
            store.set(min(max(newValue, 1), TabBarContainerView.rowLimitMax), forKey: maxTabRowsKey)
        }
    }
}

// MARK: - 数据模型

struct TabModel {
    let id: Int
    var name: String
    var kind: Kind
    var isDirty: Bool

    enum Kind {
        case json, xml, properties
        var color: NSColor {
            switch self {
            case .json: return NSColor.systemYellow
            case .xml: return NSColor.systemGreen
            case .properties: return NSColor.systemPurple
            }
        }
        var ext: String {
            switch self {
            case .json: return "json"
            case .xml: return "xml"
            case .properties: return "properties"
            }
        }
    }
}

/// 生成 a.json / b.xml / ... / aa.json / ab.xml（任务书口径：30 个假标签，短名 → 走 160 最小宽度）
func makeTabs(_ count: Int, dirtyEvery: Int = 4) -> [TabModel] {
    var result: [TabModel] = []
    let kinds: [TabModel.Kind] = [.json, .xml, .properties]
    for i in 0..<count {
        var n = i, name = ""
        repeat { name = String(Character(UnicodeScalar(97 + n % 26)!)) + name; n = n / 26 - 1 } while n >= 0
        let kind = kinds[i % kinds.count]
        result.append(TabModel(id: i, name: "\(name).\(kind.ext)", kind: kind, isDirty: i % dirtyEvery == 0))
    }
    return result
}

// MARK: - 单个标签视图（变量宽度 + hover）

final class TabView: NSView {
    let modelID: Int
    var isActive = false { didSet { needsDisplay = true } }
    var isDirty = false { didSet { needsDisplay = true } }
    var iconColor: NSColor = .systemYellow { didSet { needsDisplay = true } }
    var isHovered = false { didSet { needsDisplay = true } }
    weak var bar: TabBarContainerView?

    /// 按文件名实测宽度：min 160（PRD 口径）/ max 240，避免长名挤爆、短名浪费
    private(set) var preferredWidth: CGFloat = 160

    private let nameLabel = NSTextField(labelWithString: "")
    private let closeBtn = NSButton()
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(model: TabModel) {
        self.modelID = model.id
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 28))

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        closeBtn.title = "✕"
        closeBtn.isBordered = false
        closeBtn.font = .systemFont(ofSize: 10, weight: .bold)
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.target = self
        closeBtn.action = #selector(closeClicked)
        addSubview(closeBtn)

        configure(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ m: TabModel) {
        nameLabel.stringValue = m.name
        isDirty = m.isDirty
        iconColor = m.kind.color
        // 文本实测宽度 → 标签宽度（借鉴 SwiftDown 的自适应区间，此处按 PRD 口径调为 160/240）
        let textW = (m.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        preferredWidth = min(max(ceil(textW) + 65, 160), 240)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let w = newSize.width
        nameLabel.frame = NSRect(x: 28, y: 7, width: max(0, w - 54), height: 16)
        closeBtn.frame = NSRect(x: w - 22, y: 7, width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    @objc private func closeClicked() { bar?.closeTab(id: modelID) }

    override func mouseDown(with event: NSEvent) { bar?.beginDrag(of: self, initial: event) }

    /// macOS 原生观感（对齐 SwiftDown TabItemView）：活跃=文本底色+描边，hover=浅灰，非活跃=透明
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isActive {
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.8
            path.stroke()
        } else if isHovered {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
            path.fill()
        }

        // 类型图标
        iconColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 10, y: 9, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()

        // 脏标记 ●（放在关闭按钮左侧）
        if isDirty {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 36, y: 11, width: 6, height: 6)).fill()
        }
    }
}

// MARK: - 多行标签容器（核心验证对象）

/// 从上到下坐标系的小容器（行内文档视图用，保证内容贴顶而不是贴底）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 一行标签的裁剪容器：自己裁剪 + 自己处理滚轮。
/// 不用 NSScrollView —— 系统滚动条（含浮层样式绘制的滚动条）会压在 28pt 高的标签上，
/// 传统样式更会直接吃掉 15pt 行高，把整行压成一条缝。
final class ClipRow: NSView {
    override var isFlipped: Bool { true }
    weak var bar: TabBarContainerView?

    let doc = FlippedView()
    var rowIndex = 0
    var scrollX: CGFloat = 0
    var maxScrollX: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        bar?.scrollRow(rowIndex, by: -dx)
    }
}

final class TabBarContainerView: NSView {
    // 口径（PRD FR-02）
    static let tabH: CGFloat = 28
    static let gap: CGFloat = 4
    static let padX: CGFloat = 8
    static let padTop: CGFloat = 6
    static let padBottom: CGFloat = 6
    static let rowLimitMax = 6

    /// 关键修复：容器统一用「从上到下」坐标系。
    /// 用 frame.height 反推行 y 会让行在容器高度更新前就按旧高度算好，整组行错位。
    override var isFlipped: Bool { true }

    var onHeightChange: ((CGFloat, Bool) -> Void)?
    /// (标签数, 行数, 首行标签数, 当前实际最大标签宽, 最后一行隐藏数)
    var onStats: ((Int, Int, Int, CGFloat, Int) -> Void)?

    // MARK: 可调项（原型验证用）

    /// 行数上限：取自偏好设置 maxTabRows（默认 5，范围 1~6）
    var rowLimit = AppSettings.maxTabRows { didSet { layoutTabs(animated: true) } }
    /// 拥挤时等比压缩：把所有标签按同一比例缩小，尽量塞进 rowLimit 行
    var autoShrink = true { didSet { layoutTabs(animated: true) } }
    /// 压缩下限：低于这个宽度标签名就认不出来了，据此决定「缩」还是「换行/滚动」
    var minTabWidth: CGFloat = 112

    private(set) var tabs: [TabModel] = []
    private var tabViews: [TabView] = []
    private var activeID: Int?

    /// 预分配 6 行容器（未用到的隐藏），避免动态增删视图时的层序问题
    private var rowViews: [ClipRow] = []
    private let badge = NSTextField(labelWithString: "")

    /// 布局产物：索引 → 容器坐标框架；每行的成员索引
    private var cache: [Int: NSRect] = [:]
    private var rowIndices: [[Int]] = [[]]

    var desiredHeight: CGFloat {
        let n = CGFloat(max(1, rowIndices.count))
        return Self.padTop + n * Self.tabH + (n - 1) * Self.gap + Self.padBottom
    }

    private var lastReportedHeight: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for i in 0..<Self.rowLimitMax {
            let r = ClipRow()
            r.bar = self
            r.rowIndex = i
            r.wantsLayer = true
            r.layer?.masksToBounds = true
            r.doc.frame = NSRect(x: 0, y: 0, width: 100, height: Self.tabH)
            r.addSubview(r.doc)
            r.isHidden = true
            addSubview(r)
            rowViews.append(r)
        }

        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .systemRed
        badge.alignment = .center
        badge.isHidden = true
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        badge.layer?.cornerRadius = 6
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 某一行横向滚动（滚轮 / 触控板横向滑动）
    func scrollRow(_ r: Int, by dx: CGFloat) {
        guard rowViews.indices.contains(r), rowViews[r].maxScrollX > 0 else { return }
        let row = rowViews[r]
        let next = min(max(row.scrollX + dx, 0), row.maxScrollX)
        guard abs(next - row.scrollX) > 0.01 else { return }
        row.scrollX = next
        row.doc.frame.origin.x = -next
        updateBadge()
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    // MARK: 对外接口

    func setTabs(_ newTabs: [TabModel], animated: Bool) {
        let existing = Dictionary(uniqueKeysWithValues: tabViews.map { ($0.modelID, $0) })
        var views: [TabView] = []
        for m in newTabs {
            if let v = existing[m.id] { v.configure(m); views.append(v) }
            else {
                let v = TabView(model: m)
                v.bar = self
                views.append(v)
            }
        }
        let keep = Set(views.map { $0.modelID })
        for v in tabViews where !keep.contains(v.modelID) { v.removeFromSuperview() }
        if let a = activeID, !newTabs.contains(where: { $0.id == a }) { activeID = newTabs.first?.id }
        tabs = newTabs
        tabViews = views
        layoutTabs(animated: animated)
    }

    func closeTab(id: Int) {
        var next = tabs
        guard let idx = next.firstIndex(where: { $0.id == id }) else { return }
        next.remove(at: idx)
        setTabs(next, animated: true)
    }

    // MARK: 布局

    /// 行 y 只由行号决定（自上而下），与容器当前高度无关 → 不再出现行错位
    private func rowY(_ r: Int) -> CGFloat {
        Self.padTop + CGFloat(r) * (Self.tabH + Self.gap)
    }

    /// 统一动画入口（对齐 SwiftUI 隐式动画手感：easeOut 0.2s）
    private func animate(_ body: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            body()
        }
    }

    /// flow 分行：按给定宽度装箱，放不下就换行（等价 SwiftDown TabFlowLayout）
    private func flowRows(_ widths: [CGFloat], availW: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = Self.padX
        for (i, tw) in widths.enumerated() {
            if !rows[rows.count - 1].isEmpty, x + tw + Self.padX > availW + 0.5 {
                rows.append([])
                x = Self.padX
            }
            rows[rows.count - 1].append(i)
            x += tw + Self.gap
        }
        return rows
    }

    func layoutTabs(animated: Bool, skip: NSView? = nil) {
        let w = frame.width
        guard w > 10 else { return }   // 首次布局宽度还为 0，等窗口给到真实宽度再算行

        let limit = max(1, min(rowLimit, Self.rowLimitMax))

        // 1) 先按首选宽度分行（不压缩的理想状态）
        var widths = tabViews.map { $0.preferredWidth }
        var rows = flowRows(widths, availW: w)

        // 2) 超过行数上限且允许压缩：二分找「最大缩放系数」，使行数落回上限内
        //    —— 这就是「等比例压缩」：所有标签乘同一个 k，长名字标签缩得多、短名字缩得少
        if autoShrink && rows.count > limit {
            var lo: CGFloat = 0.30, hi: CGFloat = 1
            for _ in 0..<14 {
                let mid = (lo + hi) / 2
                let ws = widths.map { max(minTabWidth, $0 * mid) }
                if flowRows(ws, availW: w).count <= limit { lo = mid } else { hi = mid }
            }
            let scale = lo
            widths = widths.map { max(minTabWidth, $0 * scale) }
            rows = flowRows(widths, availW: w)
        }

        // 3) 缩到下限仍超上限：折叠到最后一行，行内横向滚动 + 溢出计数（FR-02 口径）
        if rows.count > limit {
            let head = Array(rows.prefix(limit - 1))
            let tail = rows[(limit - 1)...].flatMap { $0 }
            rows = head + [tail]
        }
        rowIndices = rows

        // 4) 行容器与文档视图
        var contentW: [CGFloat] = []
        for (r, idxs) in rows.enumerated() {
            var cx = Self.padX
            for i in idxs { cx += widths[i] + Self.gap }
            contentW.append(cx - Self.gap + Self.padX)
        }

        for (r, row) in rowViews.enumerated() {
            let used = r < rows.count
            row.isHidden = !used
            guard used else { continue }
            row.frame = NSRect(x: 0, y: rowY(r), width: w, height: Self.tabH)
            let docW = max(contentW[r], w)
            row.maxScrollX = max(0, docW - w)
            row.scrollX = min(row.scrollX, row.maxScrollX)
            row.doc.frame = NSRect(x: -row.scrollX, y: 0, width: docW, height: Self.tabH)
        }

        // 5) 逐行算框架 + 缓存
        var newCache: [Int: NSRect] = [:]
        for (r, idxs) in rows.enumerated() {
            var cx = Self.padX
            for i in idxs {
                newCache[i] = NSRect(x: cx, y: rowY(r), width: widths[i], height: Self.tabH)
                cx += widths[i] + Self.gap
            }
        }
        cache = newCache

        // 6) 归位
        let place = {
            for (r, idxs) in rows.enumerated() {
                let parent = self.rowViews[r].doc
                for i in idxs {
                    let v = self.tabViews[i]
                    if v === skip { continue }
                    if v.superview !== parent { parent.addSubview(v) }
                    guard let c = self.cache[i] else { continue }
                    let f = NSRect(x: c.minX, y: 0, width: c.width, height: Self.tabH)
                    if animated && v.window != nil { v.animator().frame = f } else { v.frame = f }
                }
            }
        }
        if animated { animate { place() } } else { place() }

        updateBadge()

        // 7) 高度变化（B-4：跨行边界的平滑过渡）
        let h = desiredHeight
        if abs(h - lastReportedHeight) > 0.5 {
            let useAnim = animated && window != nil
            lastReportedHeight = h
            onHeightChange?(h, useAnim)
        }

        let hiddenInLast = hiddenCountInLastRow()
        onStats?(tabs.count, rows.count, rows.first?.count ?? 0, widths.max() ?? 0, hiddenInLast)
    }

    /// 供父视图在窗口尺寸变化时先重算行、再取高度（避免用上一帧的行数算高度）
    func reflow() { layoutTabs(animated: false) }

    /// 最后一行滚出可视区的标签数
    private func hiddenCountInLastRow() -> Int {
        guard let last = rowIndices.last, !last.isEmpty else { return 0 }
        let r = rowIndices.count - 1
        let sx = rowViews[r].scrollX
        let visible = last.filter { i in
            guard let f = cache[i] else { return false }
            let x0 = f.minX - sx
            return x0 + f.width > 1 && x0 < frame.width - 1
        }.count
        return last.count - visible
    }

    /// 溢出徽标：最后一行当前滚出可视区的标签数
    private func updateBadge() {
        let hidden = hiddenCountInLastRow()
        guard hidden > 0 else { badge.isHidden = true; return }
        badge.stringValue = "+\(hidden)"
        badge.sizeToFit()
        let bw = max(30, badge.fittingSize.width + 14)
        let r = rowIndices.count - 1
        badge.frame = NSRect(x: frame.width - bw - 8, y: rowY(r) + 5, width: bw, height: Self.tabH - 10)
        badge.isHidden = false
    }

    // MARK: 拖拽排序（B-2：跨行 + 变宽标签精确插入位）

    func beginDrag(of tab: TabView, initial event: NSEvent) {
        guard let fromIdx = tabViews.firstIndex(of: tab) else { return }
        guard tab.superview !== self else { return }

        let frameInSelf = convert(tab.frame, from: tab.superview!)
        addSubview(tab, positioned: .above, relativeTo: nil)
        tab.frame = frameInSelf
        tab.isActive = true
        if let a = activeID, let av = tabViews.first(where: { $0.modelID == a }), av !== tab { av.isActive = false }
        activeID = tab.modelID

        var currentIdx = fromIdx
        var dragging = true
        while dragging {
            guard let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let p = convert(e.locationInWindow, from: nil)
            switch e.type {
            case .leftMouseDragged:
                let tw = tab.frame.width
                tab.frame.origin = NSPoint(
                    x: min(max(p.x - tw / 2, 0), max(0, frame.width - tw)),
                    y: min(max(p.y - Self.tabH / 2, 0), max(0, frame.height - Self.tabH)))
                if let target = insertionIndex(at: p), target != currentIdx {
                    moveTab(currentIdx, to: target)
                    currentIdx = target
                    layoutTabs(animated: true, skip: tab)
                }
            case .leftMouseUp:
                dragging = false
            default: break
            }
        }
        layoutTabs(animated: true)
    }

    private func moveTab(_ from: Int, to: Int) {
        guard from != to else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        let v = tabViews.remove(at: from)
        tabViews.insert(v, at: to)
    }

    /// 容器坐标点 → 插入索引（0...count）：按目标行内各标签中线判定，支持变宽 + 行滚动偏移
    private func insertionIndex(at p: NSPoint) -> Int? {
        guard p.y >= 0, p.y <= frame.height, !rowIndices.isEmpty else { return nil }
        let rowsUsed = rowIndices.count

        // 命中行（行带含 gap 容差）
        var row = rowsUsed - 1
        for r in 0..<rowsUsed {
            let top = rowY(r)
            if p.y >= top - Self.gap / 2 && p.y <= top + Self.tabH + Self.gap / 2 { row = r; break }
        }
        let idxs = rowIndices[row]
        guard !idxs.isEmpty else { return tabs.count }

        let px = p.x + rowViews[row].scrollX   // 换算回该行文档坐标

        for i in idxs {
            if let f = cache[i], px < f.midX { return i }
        }
        return (idxs.last ?? 0) + 1
    }
}

// MARK: - 根视图（标签区高度动画）

final class RootView: NSView {
    let bar = TabBarContainerView(frame: .zero)
    let placeholder = NSTextField(labelWithString: "编辑区占位（原型 B 仅验证标签条）")
    let controls = NSView()
    let statsLabel = NSTextField(labelWithString: "")
    private let controlH: CGFloat = 76

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholder.alignment = .center
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 20, weight: .light)
        addSubview(placeholder)

        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        addSubview(controls)

        bar.onHeightChange = { [weak self] h, animated in self?.reframe(h, animated: animated) }
        bar.onStats = { [weak self] count, rows, firstRow, maxW, hidden in
            guard let self else { return }
            var s = "标签 \(count) 个 · \(rows) 行 · 首行 \(firstRow) 个 · 标签宽 \(Int(maxW.rounded()))pt"
            if maxW < 160 { s += "（已压缩 \(Int((maxW / 160 * 100).rounded()))%）" }
            if hidden > 0 { s += " · 末行隐藏 \(hidden)" }
            self.statsLabel.stringValue = s
        }
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        bar.reflow()                       // 先按新宽度重算行，再取高度
        reframe(bar.desiredHeight, animated: false)
    }

    private func reframe(_ barH: CGFloat, animated: Bool) {
        let w = bounds.width
        let editorTop = bounds.height - barH
        let barFrame = NSRect(x: 0, y: editorTop, width: w, height: barH)
        let phFrame = NSRect(x: 0, y: controlH, width: w, height: max(0, editorTop - controlH))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                bar.animator().frame = barFrame
                placeholder.animator().frame = phFrame
            }
        } else {
            bar.frame = barFrame
            placeholder.frame = phFrame
        }
        controls.frame = NSRect(x: 0, y: 0, width: w, height: controlH)
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var root: RootView!
    var nextID = 100
    var rowSeg: NSSegmentedControl!
    var shrinkBox: NSButton!
    var hintLabel: NSTextField!

    func applicationDidFinishLaunching(_ note: Notification) {
        let content = RootView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        root = content

        func btn(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.font = .systemFont(ofSize: 12, weight: .medium)
            content.controls.addSubview(b)
            return b
        }
        var x: CGFloat = 12
        for (t, a) in [("+1 标签", #selector(addOne)),
                       ("+90 标签 (B-5)", #selector(add90)),
                       ("重置 30 (B-1)", #selector(reset30)),
                       ("长文件名×3", #selector(addLongNames)),
                       ("随机脏标记", #selector(toggleDirty))] {
            let b = btn(t, a)
            b.frame = NSRect(x: x, y: 44, width: 112, height: 26)
            x += 118
        }
        root.statsLabel.font = monoFont(11)
        root.statsLabel.frame = NSRect(x: x + 8, y: 48, width: 520, height: 18)
        content.controls.addSubview(root.statsLabel)

        // 第二排：行数上限（设置项）+ 等比压缩
        let capLabel = NSTextField(labelWithString: "行数上限（设置）")
        capLabel.font = .systemFont(ofSize: 12)
        capLabel.frame = NSRect(x: 12, y: 10, width: 100, height: 18)
        content.controls.addSubview(capLabel)

        let seg = NSSegmentedControl(labels: ["1", "2", "3", "4", "5", "6"],
                                     trackingMode: .selectOne, target: self, action: #selector(rowLimitChanged))
        seg.frame = NSRect(x: 116, y: 6, width: 210, height: 24)
        seg.selectedSegment = AppSettings.maxTabRows - 1
        seg.font = .systemFont(ofSize: 12)
        content.controls.addSubview(seg)
        rowSeg = seg

        let cb = NSButton(checkboxWithTitle: "拥挤时等比压缩", target: self, action: #selector(shrinkToggled))
        cb.frame = NSRect(x: 340, y: 6, width: 160, height: 24)
        cb.state = .on
        cb.font = .systemFont(ofSize: 12)
        content.controls.addSubview(cb)
        shrinkBox = cb

        let hint = NSTextField(labelWithString: "")
        hint.font = monoFont(11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 510, y: 10, width: 660, height: 18)
        content.controls.addSubview(hint)
        hintLabel = hint
        refreshHint()

        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1200, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "原型 B — 多行标签自绘 v3（M0 / RK-02）"
        window.minSize = NSSize(width: 600, height: 400)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 启动参数（便于批量截图对比不同策略）：
        //   --rows N（1~6）  --shrink 0|1  --tabs N
        applyLaunchArgs(rowSeg: rowSeg, shrinkBox: shrinkBox)
        refreshHint()

        root.bar.setTabs(makeTabs(launchTabCount), animated: false)   // B-1 场景
    }

    private var launchTabCount = 30

    private func applyLaunchArgs(rowSeg: NSSegmentedControl, shrinkBox: NSButton) {
        let a = CommandLine.arguments
        func intValue(_ key: String) -> Int? {
            guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
            return Int(a[i + 1])
        }
        if let rows = intValue("--rows") {
            let v = min(max(rows, 1), TabBarContainerView.rowLimitMax)
            root.bar.rowLimit = v
            rowSeg.selectedSegment = v - 1
        }
        if let s = intValue("--shrink") {
            root.bar.autoShrink = (s != 0)
            shrinkBox.state = s != 0 ? .on : .off
        }
        if let n = intValue("--tabs"), n > 0 { launchTabCount = n }
    }

    /// 提示当前策略的空间代价（行数 × 32pt 吃掉的编辑区高度）
    private func refreshHint() {
        let rows = CGFloat(root.bar.rowLimit)
        let fullH = 6 + rows * 28 + max(0, rows - 1) * 4 + 6
        let pct = Int((fullH / 600 * 100).rounded())
        hintLabel.stringValue = "maxTabRows = \(Int(rows))（设置项，改动即存）→ 满行时标签区 \(Int(fullH))pt，占 600pt 窗口 \(pct)%；压缩下限 \(Int(root.bar.minTabWidth))pt"
    }

    @objc private func rowLimitChanged() {
        let rows = rowSeg.selectedSegment + 1
        root.bar.rowLimit = rows
        AppSettings.maxTabRows = rows      // 落偏好设置，重启保持（正式版走设置窗口）
        refreshHint()
    }

    @objc private func shrinkToggled() {
        root.bar.autoShrink = shrinkBox.state == .on
        refreshHint()
    }

    @objc private func addOne() {
        var t = root.bar.tabs
        let kinds: [TabModel.Kind] = [.json, .xml, .properties]
        let k = kinds[nextID % 3]
        t.append(TabModel(id: nextID, name: "new\(nextID).\(k.ext)", kind: k, isDirty: nextID % 2 == 0))
        nextID += 1
        root.bar.setTabs(t, animated: true)
    }

    @objc private func add90() {
        var t = root.bar.tabs
        t.append(contentsOf: makeTabs(90, dirtyEvery: 3).map { m in
            TabModel(id: m.id + nextID, name: m.name, kind: m.kind, isDirty: m.isDirty)
        })
        nextID += 90
        root.bar.setTabs(t, animated: true)
    }

    @objc private func reset30() {
        nextID = 100
        root.bar.setTabs(makeTabs(30), animated: true)
    }

    /// 验证变量宽度：长文件名应撑到 240 上限，短名保持 160
    @objc private func addLongNames() {
        var t = root.bar.tabs
        let names: [(String, TabModel.Kind)] = [
            ("cbm-message-parser-v2.json", .json),
            ("gateway-timeout.properties", .properties),
            ("host-mapping-table.xml", .xml),
        ]
        for (n, k) in names {
            t.append(TabModel(id: nextID, name: n, kind: k, isDirty: false))
            nextID += 1
        }
        root.bar.setTabs(t, animated: true)
    }

    @objc private func toggleDirty() {
        var t = root.bar.tabs
        for i in t.indices where Bool.random() { t[i].isDirty.toggle() }
        root.bar.setTabs(t, animated: false)
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

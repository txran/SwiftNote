import AppKit
import SwiftNoteKit

struct TabBarItem: Equatable {
    let id: UUID
    var title: String
    var isDirty: Bool
    var isReadOnly: Bool
    /// 外部修改冲突（FR-11）：保留本地版本后置位，保存时清除
    var hasConflict: Bool = false
    /// 磁盘路径（未命名文档为 nil），右键菜单「复制路径 / 在访达中显示」用它
    var path: String? = nil
}

/// 从上到下坐标系的容器（行布局依赖行号，不依赖高度）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 多行标签栏（FR-02，正式版）：flow 换行 → 超出上限的行折叠到末行横向滚动 + 溢出计数
final class TabBarView: NSView {
    static let tabHeight: CGFloat = 28
    static let rowGap: CGFloat = 4
    static let padX: CGFloat = 8
    static let padTop: CGFloat = 6

    /// 右上角「＋」按钮：直径
    private static let newTabButtonSize: CGFloat = 26
    /// 按钮占掉的横向空间（按钮 + 右侧留白 + 与最后一个标签的间隙），reflow 时从可用宽度里扣掉
    private static let newTabButtonArea: CGFloat = 26 + 8 + 8

    var items: [TabBarItem] = [] {
        didSet { layoutNewTabButton() }
    }
    var activeIndex: Int = -1

    var maxTabRows: Int = 5 {
        didSet { if maxTabRows != oldValue { reflow(animated: true) } }
    }
    var minTabWidth: CGFloat = 160
    var maxTabWidth: CGFloat = 240

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// 右上角「＋」：新建文件（与 ⌘N 同一条路径）
    var onNewTab: (() -> Void)?
    /// 拖拽排序完成后回传当前标签顺序（store 据此重排文档）
    var onOrderChanged: (([UUID]) -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?

    private let newTabButton = NewTabButton()

    private var itemViews: [TabItemView] = []
    private var positions: [CGRect] = []
    private var rowCount: Int = 1
    private var lastRowClip: ClipRowView?
    private var overflowBadge = NSTextField(labelWithString: "")
    private(set) var overflowCount: Int = 0

    // 拖拽态
    private var dragIndex: Int = -1
    private var dragStartPoint: NSPoint = .zero
    private var isDragging = false

    override var isFlipped: Bool { true }

    var desiredHeight: CGFloat {
        Self.padTop + CGFloat(max(1, rowCount)) * (Self.tabHeight + Self.rowGap)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        overflowBadge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        overflowBadge.textColor = .secondaryLabelColor
        overflowBadge.alignment = .center
        overflowBadge.wantsLayer = true
        overflowBadge.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92).cgColor
        overflowBadge.layer?.cornerRadius = 8
        overflowBadge.isHidden = true
        addSubview(overflowBadge)

        newTabButton.onClick = { [weak self] in self?.onNewTab?() }
        addSubview(newTabButton)

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: AppSettings.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func settingsChanged(_ note: Notification) {
        let keys = note.userInfo?[AppSettings.changedKeysKey] as? [String] ?? []
        if keys.contains(AppSettings.Key.maxTabRows) {
            maxTabRows = AppSettings.shared.maxTabRows
        }
        if keys.contains(AppSettings.Key.minTabWidth) {
            minTabWidth = AppSettings.shared.minTabWidth
            reflow(animated: true)
        }
    }

    // MARK: - 数据入口

    func setItems(_ newItems: [TabBarItem], activeIndex: Int) {
        let identityChanged = newItems.map(\.id) != items.map(\.id)
        self.items = newItems
        self.activeIndex = activeIndex
        if identityChanged || itemViews.count != newItems.count {
            rebuildItemViews()
        } else {
            for (i, view) in itemViews.enumerated() where i < newItems.count {
                view.configure(item: newItems[i], active: i == activeIndex)
            }
        }
        reflow(animated: identityChanged)
    }

    /// 无头核对：某个标签的右键菜单长什么样（含置灰状态）
    func contextMenuSummary(at index: Int) -> String {
        guard itemViews.indices.contains(index) else { return "（无此标签）" }
        return itemViews[index].makeContextMenu().items
            .map { $0.isSeparatorItem ? "—" : "\($0.title)\($0.isEnabled ? "" : "（灰）")" }
            .joined(separator: " | ")
    }

    /// 无头核对：按名字触发某个标签的右键动作
    func triggerContextAction(_ name: String, at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].triggerContextAction(name)
    }

    private func rebuildItemViews() {
        for view in itemViews { view.removeFromSuperview() }
        itemViews = items.enumerated().map { index, item in
            let view = TabItemView(index: index, item: item, active: index == activeIndex)
            view.bar = self
            return view
        }
        // 先全部挂到 bar 上；reflow 时再决定是否移入末行裁剪容器
        for view in itemViews { addSubview(view) }
    }

    // MARK: - 布局

    private func preferredWidth(for item: TabBarItem) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let textWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        var width = textWidth + 20 + 18 + 16   // 左右内边距 + 关闭按钮 + 脏标记
        if item.isReadOnly { width += 12 }
        return min(maxTabWidth, max(minTabWidth, width))
    }

    func reflow(animated: Bool) {
        guard !itemViews.isEmpty else {
            rowCount = 1
            positions = []
            layoutNewTabButton()
            notifyHeight()
            needsDisplay = true
            return
        }
        // 右上角要留给「＋」，标签可用宽度先扣掉它（否则最后一个标签会被按钮压住）
        let available = max(200, bounds.width - Self.padX * 2 - Self.newTabButtonArea)
        let widths = items.map { preferredWidth(for: $0) }

        // 1) flow 换行（借鉴 SwiftDown TabFlowLayout：按实际宽度装箱）
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !rows[rows.count - 1].isEmpty, x + w > available {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(i)
            x += w + Self.rowGap
        }

        // 2) 超过行数上限：多余行折叠进末行（横向滚动 + 溢出计数）
        let limit = max(1, maxTabRows)
        if rows.count > limit {
            var merged = Array(rows.prefix(limit - 1))
            merged.append(rows.dropFirst(limit - 1).flatMap { $0 })
            rows = merged
        }
        rowCount = max(1, rows.count)

        // 2.5) 两端对齐（Xcode 形态）：行内剩余宽度摊给标签，上限仍是 maxTabWidth。
        // 末行要横向滚动，不能拉宽，否则溢出徽标永远出不来。
        var rowWidths = widths
        let lastRow = rows.count - 1
        for (row, indices) in rows.enumerated() where row < lastRow {
            var remaining = available
                - indices.reduce(CGFloat(0)) { $0 + widths[$1] }
                - CGFloat(indices.count - 1) * Self.rowGap
            while remaining > 0.5 {
                let share = remaining / CGFloat(indices.count)
                var progressed = false
                for i in indices {
                    let room = maxTabWidth - rowWidths[i]
                    guard room > 0.5 else { continue }
                    let add = min(room, share)
                    rowWidths[i] += add
                    remaining -= add
                    progressed = true
                }
                if !progressed { break }
            }
        }

        // 3) 位置计算（行 y 只由行号决定，与容器高度解耦）
        var newPositions = [CGRect](repeating: .zero, count: items.count)
        var lastRowItems: [Int] = []
        var lastRowContentWidth: CGFloat = 0

        for (row, indices) in rows.enumerated() {
            var cx: CGFloat = 0
            let y = Self.padTop + CGFloat(row) * (Self.tabHeight + Self.rowGap)
            for i in indices {
                let rect = CGRect(x: Self.padX + cx, y: y, width: rowWidths[i], height: Self.tabHeight)
                newPositions[i] = rect
                cx += rowWidths[i] + Self.rowGap
                if row == rows.count - 1 {
                    lastRowItems.append(i)
                    lastRowContentWidth = rect.maxX
                }
            }
        }
        positions = newPositions

        // 4) 挂载：除末行外直接挂在 bar；末行放入裁剪滚动容器
        let lastRowY = Self.padTop + CGFloat(rows.count - 1) * (Self.tabHeight + Self.rowGap)
        let clip: ClipRowView
        if let existing = lastRowClip {
            clip = existing
        } else {
            clip = ClipRowView(frame: NSRect(x: Self.padX, y: lastRowY,
                                             width: bounds.width - Self.padX * 2,
                                             height: Self.tabHeight))
            clip.onScrolled = { [weak self] in self?.updateOverflowBadge() }
            addSubview(clip)
            lastRowClip = clip
        }
        clip.frame = NSRect(x: Self.padX, y: lastRowY,
                            width: max(0, bounds.width - Self.padX * 2), height: Self.tabHeight)
        clip.content.frame.size = NSSize(width: max(lastRowContentWidth - Self.padX, clip.bounds.width),
                                         height: Self.tabHeight)

        let lastRowSet = Set(lastRowItems)
        for (i, view) in itemViews.enumerated() {
            let target: NSView = lastRowSet.contains(i) ? clip.content : self
            if view.superview !== target {
                target.addSubview(view)
            }
            var rect = newPositions[i]
            if lastRowSet.contains(i) {
                // 末行标签挂在裁剪容器的局部坐标里：x 去掉左内边距，y 归零（行偏移由容器负责）
                rect.origin = NSPoint(x: rect.minX - Self.padX, y: 0)
            }
            if isDragging, i == dragIndex {
                view.alphaValue = 0.92
                view.frame = rect.offsetBy(dx: dragTranslation.width, dy: 0)
            } else {
                view.alphaValue = 1
                view.frame = rect
            }
            view.index = i
            view.configure(item: items[i], active: i == activeIndex)
        }
        clip.content.frame.size.width = max(lastRowContentWidth - Self.padX, clip.bounds.width)

        if let clipSuper = lastRowClip?.superview {
            addSubview(overflowBadge, positioned: .above, relativeTo: clipSuper)
        }
        clampLastRowScroll()
        ensureActiveVisible()
        updateOverflowBadge()
        layoutNewTabButton()
        notifyHeight()

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for view in itemViews { view.animator().frame = view.frame }
            }
        }
        needsDisplay = true
    }

    private func notifyHeight() {
        onHeightChanged?(desiredHeight)
    }

    /// 固定在右上角第一行、垂直居中；跟着窗口宽度走
    private func layoutNewTabButton() {
        let size = Self.newTabButtonSize
        let x = max(Self.padX, bounds.width - Self.padX - size)
        let y = Self.padTop + (Self.tabHeight - size) / 2
        newTabButton.frame = NSRect(x: x, y: y, width: size, height: size)
        // reflow 会把溢出徽标提到最上层，按钮要重新压回去
        if overflowBadge.superview === self {
            addSubview(newTabButton, positioned: .above, relativeTo: overflowBadge)
        }
    }

    /// 无头核对用
    func newTabButtonSummary() -> String {
        "frame=\(NSStringFromRect(newTabButton.frame)) 隐藏=\(newTabButton.isHidden)"
    }

    func simulateNewTabClick() {
        newTabButton.onClick?()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        reflow(animated: false)
    }

    // MARK: - 溢出徽标

    private func updateOverflowBadge() {
        guard let clip = lastRowClip else {
            overflowCount = 0
            overflowBadge.isHidden = true
            return
        }
        let visible = clip.visibleContentRange
        var hidden = 0
        for (i, rect) in positions.enumerated() where itemViews.count > i {
            guard itemViews[i].superview === clip.content else { continue }
            let contentMinX = rect.minX - Self.padX
            let contentMaxX = rect.maxX - Self.padX
            if contentMaxX > visible.maxX + 1 || contentMinX < visible.minX - 1 {
                hidden += 1
            }
        }
        overflowCount = hidden
        if hidden == 0 {
            overflowBadge.isHidden = true
        } else {
            overflowBadge.stringValue = "+\(hidden)"
            overflowBadge.sizeToFit()
            let w = overflowBadge.frame.width + 12
            let y = Self.padTop + CGFloat(max(1, rowCount) - 1) * (Self.tabHeight + Self.rowGap)
            overflowBadge.frame = NSRect(x: bounds.width - w - 4,
                                         y: y + (Self.tabHeight - 17) / 2,
                                         width: w, height: 17)
            overflowBadge.isHidden = false
        }
    }

    /// 活跃标签若在末行被滚出视野，自动滚入（切标签/新增标签时保持可见）
    private func ensureActiveVisible() {
        guard let clip = lastRowClip, activeIndex >= 0,
              itemViews.indices.contains(activeIndex),
              itemViews[activeIndex].superview === clip.content else { return }
        let rect = positions[activeIndex]
        let localMinX = rect.minX - Self.padX
        let localMaxX = rect.maxX - Self.padX
        if localMinX < clip.offset {
            clip.setOffset(localMinX)
        } else if localMaxX > clip.offset + clip.bounds.width {
            clip.setOffset(localMaxX - clip.bounds.width)
        }
    }

    private func clampLastRowScroll() {
        guard let clip = lastRowClip else { return }
        clip.clampOffset()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - 拖拽

    fileprivate func beginInteraction(index: Int, point: NSPoint, event: NSEvent) {
        guard index >= 0, index < itemViews.count else { return }
        dragIndex = index
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    private var dragTranslation: CGSize = .zero

    fileprivate func continueInteraction(event: NSEvent) {
        guard dragIndex >= 0, dragIndex < itemViews.count else { return }
        let current = convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard hypot(current.x - dragStartPoint.x, current.y - dragStartPoint.y) > 4 else { return }
            isDragging = true
        }
        dragTranslation = CGSize(width: current.x - dragStartPoint.x, height: 0)

        // 目标位置：命中哪个标签就插到它前面/后面
        if let target = itemIndex(at: current), target != dragIndex {
            var destination = target
            if current.x > positions[target].midX { destination = target + 1 }
            if destination > dragIndex { destination -= 1 }
            if destination != dragIndex {
                let movedItem = items.remove(at: dragIndex)
                items.insert(movedItem, at: destination)
                let view = itemViews.remove(at: dragIndex)
                itemViews.insert(view, at: destination)
                dragIndex = destination
                onOrderChanged?(items.map(\.id))
                reflow(animated: false)
            }
        } else if dragIndex < itemViews.count {
            var rect = positions[dragIndex]
            if itemViews[dragIndex].superview === lastRowClip?.content {
                rect.origin = NSPoint(x: rect.minX - Self.padX - (lastRowClip?.offset ?? 0), y: 0)
            }
            itemViews[dragIndex].frame = rect.offsetBy(dx: dragTranslation.width, dy: 0)
        }
    }

    fileprivate func endInteraction() {
        if !isDragging, dragIndex >= 0, dragIndex < items.count {
            onSelect?(dragIndex)
        }
        isDragging = false
        dragIndex = -1
        dragTranslation = .zero
        reflow(animated: true)
    }

    private func itemIndex(at point: NSPoint) -> Int? {
        for (i, rect) in positions.enumerated() {
            var r = rect
            if itemViews.count > i, itemViews[i].superview === lastRowClip?.content {
                r.origin.x -= (lastRowClip?.offset ?? 0)
            }
            if r.contains(point) { return i }
        }
        return nil
    }

    /// 无头验证用：合成一个真正的中键事件并派发给指定标签
    @discardableResult
    func simulateMiddleClick(index: Int) -> Bool {
        guard itemViews.indices.contains(index),
              let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                               mouseCursorPosition: .zero, mouseButton: .center),
              let event = NSEvent(cgEvent: cg),
              event.buttonNumber == 2 else { return false }
        itemViews[index].otherMouseDown(with: event)
        return true
    }
}

// MARK: - 末行裁剪滚动容器

/// 自绘裁剪容器：不用 NSScrollView（滚动条会吃掉 28pt 行高，M0 实测结论）
final class ClipRowView: NSView {
    let content = FlippedView()
    private(set) var offset: CGFloat = 0
    var onScrolled: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var visibleContentRange: CGRect {
        CGRect(x: offset, y: 0, width: bounds.width, height: bounds.height)
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let delta = abs(dx) > 0.01 ? dx : dy
        guard abs(delta) > 0.01 else { return }
        offset = min(max(0, offset - delta), maxOffset)
        applyOffset()
    }

    func setOffset(_ newOffset: CGFloat) {
        offset = min(max(0, newOffset), maxOffset)
        applyOffset()
    }

    func clampOffset() {
        offset = min(max(0, offset), maxOffset)
        applyOffset()
    }

    private var maxOffset: CGFloat {
        max(0, content.frame.width - bounds.width)
    }

    private func applyOffset() {
        content.frame.origin = NSPoint(x: -offset, y: 0)
        onScrolled?()
    }
}

// MARK: - 单个标签

final class TabItemView: NSView {
    fileprivate weak var bar: TabBarView?
    var index: Int
    private var item: TabBarItem
    private var isActive: Bool
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(index: Int, item: TabBarItem, active: Bool) {
        self.index = index
        self.item = item
        self.isActive = active
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: TabBarItem, active: Bool) {
        self.item = item
        self.isActive = active
        if item.hasConflict {
            toolTip = "磁盘上的文件已被外部修改，当前显示的是本地版本（保存将覆盖磁盘）"
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.width - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isActive {
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            // 活跃标签底部强调色：与 inset 过的描边底边对齐，别顶满外框（视觉「悬空」）
            NSColor.controlAccentColor.setFill()
            NSRect(x: 6, y: 0.5, width: bounds.width - 12, height: 2).fill()
        } else if isHovering {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5).setFill()
            path.fill()
        } else {
            // 0.35 在 17 个标签时几乎与底同色、糊成一片；0.55 起才有块面感
            NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
            path.fill()
            NSColor.quaternaryLabelColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        // 标题
        var titleX: CGFloat = 10
        if item.isDirty {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: titleX, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
            titleX += 9
        }
        if item.isReadOnly {
            drawSymbol("lock.fill", at: NSPoint(x: titleX, y: bounds.midY - 5.5),
                       size: 11, color: .secondaryLabelColor)
            titleX += 13
        }
        if item.hasConflict {
            // 磁盘上有另一份版本，标题前给个提示（tooltip 里说清原因）
            drawSymbol("exclamationmark.triangle.fill",
                       at: NSPoint(x: titleX, y: bounds.midY - 5.5),
                       size: 11, color: .systemOrange)
            titleX += 13
        }

        let titleWidth = bounds.width - titleX - 24
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: isActive ? .medium : .regular),
            .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: item.title, attributes: attributes)
            .draw(in: NSRect(x: titleX, y: (bounds.height - 15) / 2, width: max(0, titleWidth), height: 15))

        // 关闭按钮（hover 或活跃时显示）
        if isHovering || isActive {
            let r = closeRect
            if isHovering {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            let cross = NSBezierPath()
            let inset: CGFloat = 5
            cross.move(to: NSPoint(x: r.minX + inset, y: r.minY + inset))
            cross.line(to: NSPoint(x: r.maxX - inset, y: r.maxY - inset))
            cross.move(to: NSPoint(x: r.maxX - inset, y: r.minY + inset))
            cross.line(to: NSPoint(x: r.minX + inset, y: r.maxY - inset))
            cross.lineWidth = 1.2
            (isActive ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            cross.stroke()
        }
    }

    /// 自绘路径里用 SF Symbol：`NSImage.draw` 不会给模板图上色，得自己 sourceAtop 染一遍
    private func drawSymbol(_ name: String, at origin: NSPoint, size: CGFloat, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .medium)) else { return }
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let frame = NSRect(x: origin.x + (size - configured.size.width) / 2,
                           y: origin.y + (size - configured.size.height) / 2,
                           width: configured.size.width,
                           height: configured.size.height)
        tinted.draw(in: frame)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point), isHovering || isActive {
            bar?.onClose?(index)
            return
        }
        bar?.beginInteraction(index: index, point: point, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        bar?.continueInteraction(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        bar?.endInteraction()
    }

    /// 鼠标中键点击标签 = 关闭该标签（Notepad++/Chrome 习惯）
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        bar?.onClose?(index)
    }

    // MARK: - 右键菜单（复制路径 / 在访达中显示）

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu()
    }

    /// 抽成独立方法：`menu(for:)` 需要真实事件，无头核对时直接调这里
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let path = item.path
        let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false

        let copy = NSMenuItem(title: "复制文件路径", action: #selector(copyFilePath), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = path != nil
        menu.addItem(copy)

        let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealInFinder), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = exists
        menu.addItem(reveal)

        if path == nil {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "未保存的文档没有路径", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else if !exists {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "文件已不在磁盘上", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    /// 供无头验证按名字触发，避免依赖鼠标事件
    func triggerContextAction(_ name: String) {
        switch name {
        case "copy": copyFilePath()
        case "reveal": revealInFinder()
        default: break
        }
    }

    @objc private func copyFilePath() {
        guard let path = item.path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    @objc private func revealInFinder() {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// 右上角的「＋」：自绘而不是 NSButton ——
/// 本机只有 CLT，模板图靠 `contentTintColor` 上色在无边框按钮上不稳（同类坑见 ADR「自绘 SF Symbols」），
/// 两条线画出来的加号在每个外观下都确定。
final class NewTabButton: NSView {
    var onClick: (() -> Void)?

    private var isHovering = false
    private var isPressed = false
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isPressed = false
        needsDisplay = true
        guard bounds.contains(point) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // hover / 按下时的圆角底：深色外观下 `quaternaryLabelColor` 是白色低透明度，两套外观都对
        if isHovering || isPressed {
            NSColor.quaternaryLabelColor
                .withAlphaComponent(isPressed ? 0.9 : 0.6)
                .setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
        }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 5
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: center.x - arm, y: center.y))
        path.line(to: NSPoint(x: center.x + arm, y: center.y))
        path.move(to: NSPoint(x: center.x, y: center.y - arm))
        path.line(to: NSPoint(x: center.x, y: center.y + arm))
        (isHovering ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
        path.stroke()
    }
}

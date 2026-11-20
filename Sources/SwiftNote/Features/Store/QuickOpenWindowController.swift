import AppKit
import SwiftNoteKit

/// 快速打开面板（FR-11：最近文件 ≥20 条 + ⌘⇧O）
///
/// 交互照抄 Spotlight / Raycast 那一套，因为用户在编辑器里按 ⌘⇧O 就是想要
/// 「键盘敲几个字、回车打开」：搜索框常驻焦点，↑↓ 换行、↩ 打开、⎋ 关闭，
/// 双击也能打开。面板是主窗口的子窗口，不抢 Dock 的窗口列表。
final class QuickOpenWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {

    private let panel: QuickOpenPanel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择    ↩ 打开    ⎋ 关闭")
    private let countLabel = NSTextField(labelWithString: "")

    private var items: [QuickOpenItem] = []
    private var filtered: [QuickOpenItem] = []
    /// 上一次的选中行：只为把「旧行 + 新行」两格的选中态刷一遍，避免整表 reload 递归
    private var lastSelectedRow = -1

    /// 回车/双击打开某条候选（由主窗口接管：已打开则激活标签，不存在则提示）
    var onOpen: ((QuickOpenItem) -> Void)?

    private static let panelWidth: CGFloat = 580
    private static let rowHeight: CGFloat = 44
    /// 搜索区（12 + 26 + 10）+ 表格与 footer 的固定留白
    private static let chromeHeight: CGFloat = 88
    private static let maxVisibleRows = 8

    /// 高度随命中数收缩（1~8 行），命中 1 条时不再中间一大片空白
    private static func panelSize(rows: Int) -> NSSize {
        let visible = max(1, min(rows, maxVisibleRows))
        return NSSize(width: panelWidth, height: chromeHeight + CGFloat(visible) * rowHeight)
    }

    init() {
        panel = QuickOpenPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize(rows: 7)),
                               styleMask: [.titled, .fullSizeContentView],
                               backing: .buffered,
                               defer: false)
        super.init(window: panel)
        configureWindow()
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 组装

    private func configureWindow() {
        panel.title = "快速打开"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }
    }

    private func buildContent() {
        // 不用 NSVisualEffectView：`.behindWindow` 材质在这个「直接起二进制、应用未激活」
        // 的进程里拿不到背景层，面板会变成纯透传（背后的日志文字一条条透出来）。
        // 实心卡片在本应用里也更统一——主窗口、设置窗都是不透明表面。
        let content = QuickOpenContentView()
        panel.contentView = content

        searchField.placeholderString = "搜索最近文件（输入文件名片段，空格分词）"
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(queryChanged)
        content.addSubview(searchField)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        // 选中底色自己画（圆角、内缩），系统高亮在这种整行卡片布局里太宽
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        content.addSubview(scrollView)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        content.addSubview(hintLabel)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        content.addSubview(countLabel)

        content.searchView = searchField
        content.scrollView = scrollView
        content.hintView = hintLabel
        content.countView = countLabel
    }

    // MARK: - 呈现 / 关闭

    /// 弹出面板；`parent` 存在时贴成它的子窗口（跟着主窗口一起收起）
    func present(over parent: NSWindow?, openPaths: [String], recentPaths: [String]) {
        rebuild(openPaths: openPaths, recentPaths: recentPaths)
        searchField.stringValue = ""
        applyFilter()
        let size = Self.panelSize(rows: filtered.count)
        if let parent {
            position(over: parent, size: size)
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
            }
        }
        if parent == nil { panel.setContentSize(size) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if ProcessInfo.processInfo.environment["SWIFTNOTE_QUICK_OPEN"] != nil {
            AppLogger.info("QUICKOPEN 窗口 alpha=\(panel.alphaValue) opaque=\(panel.isOpaque) "
                           + "bg=\(panel.backgroundColor.alphaComponent) layerBacked=\(panel.contentView?.layer != nil) "
                           + "frame=\(panel.frame) visible=\(panel.isVisible) key=\(panel.isKeyWindow)")
        }
    }

    func dismiss() {
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// 面板是 key window 时，菜单的响应者链走到的是**面板**，不是主窗口；
    /// 不在这里接一下，⌘⇧O 再按一次不会有任何反应（菜单项还会变灰）
    @objc func quickOpenRecent(_ sender: Any?) {
        dismiss()
    }

    /// 无头验证用：把候选与过滤结果打出来
    var debugSummary: String {
        let head = filtered.prefix(8).map {
            "\($0.name)\($0.isOpen ? "[开]" : "")\($0.exists ? "" : "[缺失]")"
        }
        return "items=\(items.count) filtered=\(filtered.count) selected=\(tableView.selectedRow) \(head.joined(separator: " | "))"
    }

    private func position(over parent: NSWindow, size: NSSize) {
        let parentFrame = parent.frame
        var origin = NSPoint(x: parentFrame.midX - size.width / 2,
                             y: parentFrame.maxY - size.height - 110)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 16), visible.maxX - size.width - 16)
            origin.y = min(max(origin.y, visible.minY + 16), visible.maxY - size.height - 16)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// 输入过滤后结果数变了：顶边不动、向下收缩/变高
    private func adjustPanelHeight() {
        guard panel.isVisible else { return }
        let target = Self.panelSize(rows: filtered.count)
        var frame = panel.frame
        guard abs(frame.height - target.height) > 0.5 else { return }
        frame.origin.y = frame.maxY - target.height
        frame.size = target
        panel.setFrame(frame, display: true, animate: true)
        if ProcessInfo.processInfo.environment["SWIFTNOTE_QUICK_OPEN"] != nil {
            AppLogger.info("QUICKOPEN 自适应：命中 \(filtered.count) 条 → 高 \(target.height)")
        }
    }

    // MARK: - 数据

    private func rebuild(openPaths: [String], recentPaths: [String]) {
        items = QuickOpen.items(openPaths: openPaths, recentPaths: recentPaths) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// 供无头调试：直接设置查询词
    func setQuery(_ text: String) {
        searchField.stringValue = text
        applyFilter()
    }

    private func applyFilter() {
        filtered = QuickOpen.filter(items, query: searchField.stringValue)
        lastSelectedRow = -1
        tableView.reloadData()
        adjustPanelHeight()
        if filtered.isEmpty {
            countLabel.stringValue = "无匹配"
            countLabel.textColor = .systemOrange
        } else {
            countLabel.stringValue = "\(filtered.count) 项"
            countLabel.textColor = .tertiaryLabelColor
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    @objc private func queryChanged() {
        applyFilter()
    }

    // MARK: - 键盘

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        guard next != current else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func openSelected() {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let item = filtered[row]
        guard item.exists else {
            countLabel.stringValue = "文件已不存在：\(item.name)"
            countLabel.textColor = .systemOrange
            NSSound.beep()
            return
        }
        let handler = onOpen
        dismiss()
        handler?(item)
    }

    /// 无头验证：等价于按 ↩（走的是同一条 openSelected 路径）
    func performOpenForTesting() {
        openSelected()
    }

    func currentSelectionName() -> String {
        guard filtered.indices.contains(tableView.selectedRow) else { return "（无）" }
        return filtered[tableView.selectedRow].name
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            openSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: - 窗口委托

    /// 点到别处就收起（Spotlight 同理）；无头运行时不因应用未激活而自杀
    func windowDidResignKey(_ notification: Notification) {
        guard NSApp.isActive else { return }
        dismiss()
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let item = filtered[row]
        let identifier = NSUserInterfaceItemIdentifier("QuickOpenRow")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? QuickOpenRowView
            ?? QuickOpenRowView()
        rowView.identifier = identifier
        rowView.configure(with: item)
        // reloadData 会重建单元格，选中态要按表格当前行重新刷
        rowView.setSelected(row == tableView.selectedRow)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        for index in [lastSelectedRow, row] where index >= 0 {
            let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            (view as? QuickOpenRowView)?.setSelected(index == row)
        }
        lastSelectedRow = row
    }
}

// MARK: - 面板

/// 面板本身负责 ⎋（焦点在表格上时也能关）
private final class QuickOpenPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - 内容容器

/// 手工布局（项目不用 Auto Layout）：搜索框贴顶、表格吃中间、提示行贴底
private final class QuickOpenContentView: NSView {
    weak var searchView: NSView?
    weak var scrollView: NSView?
    weak var hintView: NSView?
    weak var countView: NSView?

    override var isFlipped: Bool { true }

    /// 直接画底色，不走 layer：这一层是窗口的「卡片」，必须稳定不透明
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }


    override func layout() {
        super.layout()
        let margin: CGFloat = 14
        let footerHeight: CGFloat = 20

        hintView?.frame = NSRect(x: margin + 2, y: bounds.height - margin - footerHeight,
                                 width: 240, height: footerHeight)
        countView?.frame = NSRect(x: bounds.width - margin - 202, y: bounds.height - margin - footerHeight,
                                  width: 200, height: footerHeight)
        guard let searchView else { return }
        searchView.frame = NSRect(x: margin, y: 12, width: bounds.width - margin * 2, height: 26)
        scrollView?.frame = NSRect(x: 0, y: searchView.frame.maxY + 10,
                                   width: bounds.width,
                                   height: (hintView?.frame.minY ?? bounds.height) - 6 - (searchView.frame.maxY + 10))
    }
}

// MARK: - 行

/// 一行 = 图标 + 文件名 + 目录，右侧挂状态徽标
private final class QuickOpenRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    private var selected = false
    private var badgeColor: NSColor = .secondaryLabelColor
    private var titleColor: NSColor = .labelColor
    /// 文件已不存在：整行压暗
    private var dimmed = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.usesSingleLineMode = true
        addSubview(titleLabel)

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.cell?.usesSingleLineMode = true
        addSubview(pathLabel)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.alignment = .center
        // 选中行是纯色系统蓝，白字直接压上去读不出来；给个半透明胶囊底兜住
        badgeLabel.wantsLayer = true
        addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: QuickOpenItem) {
        let icon = NSWorkspace.shared.icon(forFile: item.path)
        icon.size = NSSize(width: 16, height: 16)
        iconView.image = icon
        dimmed = !item.exists
        iconView.alphaValue = dimmed ? 0.45 : 1.0

        titleLabel.stringValue = item.name
        pathLabel.stringValue = item.directory
        titleColor = item.exists ? .labelColor : .tertiaryLabelColor

        if !item.exists {
            badgeLabel.stringValue = "不存在"
            badgeColor = .systemOrange
        } else if item.isOpen {
            badgeLabel.stringValue = "已打开"
            badgeColor = .controlAccentColor
        } else {
            badgeLabel.stringValue = ""
            badgeColor = .secondaryLabelColor
        }

        if item.isOpen && item.exists {
            titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        } else {
            titleLabel.font = .systemFont(ofSize: 13)
        }
        applyColors()
        needsLayout = true
    }

    func setSelected(_ isSelected: Bool) {
        guard selected != isSelected else { return }
        selected = isSelected
        needsDisplay = true
        applyColors()
    }

    /// 徽标胶囊底：选中行用白色 18%，普通行用自身色的 12%
    private func updateBadgeBackground() {
        guard !badgeLabel.stringValue.isEmpty else {
            badgeLabel.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        let fill = selected ? NSColor.white.withAlphaComponent(0.18)
                            : badgeColor.withAlphaComponent(0.12)
        badgeLabel.layer?.backgroundColor = fill.cgColor
    }

    private func applyColors() {
        if selected {
            titleLabel.textColor = .white
            pathLabel.textColor = NSColor.white.withAlphaComponent(0.72)
            badgeLabel.textColor = badgeLabel.stringValue.isEmpty ? .clear : .white
            iconView.alphaValue = 1.0
        } else {
            titleLabel.textColor = titleColor
            pathLabel.textColor = .secondaryLabelColor
            badgeLabel.textColor = badgeLabel.stringValue.isEmpty ? .clear : badgeColor
            iconView.alphaValue = dimmed ? 0.45 : 1.0
        }
        updateBadgeBackground()
    }

    private var badgeWidth: CGFloat {
        guard !badgeLabel.stringValue.isEmpty else { return 0 }
        let size = (badgeLabel.stringValue as NSString)
            .size(withAttributes: [.font: badgeLabel.font as Any])
        return ceil(size.width) + 12
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 22
        let iconSide: CGFloat = 16
        iconView.frame = NSRect(x: inset, y: (bounds.height - iconSide) / 2,
                                width: iconSide, height: iconSide)
        let textLeft = iconView.frame.maxX + 10
        let badgeW = badgeWidth
        let textRight = bounds.width - inset - (badgeW > 0 ? badgeW + 10 : 0)
        titleLabel.frame = NSRect(x: textLeft, y: 7, width: max(40, textRight - textLeft), height: 17)
        pathLabel.frame = NSRect(x: textLeft, y: 25, width: max(40, textRight - textLeft), height: 15)
        if badgeW > 0 {
            badgeLabel.frame = NSRect(x: bounds.width - inset - badgeW, y: 15, width: badgeW, height: 14)
            badgeLabel.layer?.cornerRadius = 7
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        let rect = bounds.insetBy(dx: 10, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }
}

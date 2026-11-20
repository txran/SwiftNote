import AppKit
import SwiftNoteKit

/// 偏好设置窗口（设计说明书 4.4）：把 AppSettings 的设置项做出 UI 入口
///
/// 全部即时生效——写入 AppSettings 后广播 `didChangeNotification`，
/// 主窗口收到后重排标签栏 / 更新编辑区策略，菜单则整体重建（键位是拷贝进 NSMenuItem 的）。
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    enum Pane: Int {
        case general = 0
        case shortcuts = 1
    }

    // 通用页控件
    private let maxRowsValue = NSTextField(labelWithString: "")
    private let maxRowsStepper = NSStepper()
    private let minWidthValue = NSTextField(labelWithString: "")
    private let minWidthSlider = NSSlider()
    private let tabSpacesCheckbox = NSButton()
    private let thresholdValue = NSTextField(labelWithString: "")
    private let thresholdStepper = NSStepper()
    private let thresholdHint = NSTextField(labelWithString: "")

    /// 阈值可调范围：与 AppSettings.largeFileThresholdMB 共用同一份定义
    private static let thresholdRange = AppSettings.largeFileThresholdRange
    private let draftValue = NSTextField(labelWithString: "")
    private let draftSlider = NSSlider()

    // 页签与容器
    private let paneSelector = NSSegmentedControl()
    private let generalPane = NSView()
    private let shortcutPane = NSView()
    private let shortcutScroll = NSScrollView()
    private let shortcutContent = ShortcutListContainer()
    private let shortcutHint = NSTextField(labelWithString: "")
    private var recorders: [ShortcutAction: ShortcutRecorderButton] = [:]

    private static let width: CGFloat = 470
    private static let height: CGFloat = 430
    private static let labelWidth: CGFloat = 150
    private static let valueWidth: CGFloat = 76
    private static let controlLeft: CGFloat = 180
    private static let paneBottom: CGFloat = 46
    private static let paneTop: CGFloat = 52

    private static var paneHeight: CGFloat { height - paneBottom - paneTop }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
        syncFromSettings()
        NotificationCenter.default.addObserver(self, selector: #selector(syncFromSettings),
                                               name: AppSettings.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 组装

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        paneSelector.segmentCount = 2
        paneSelector.setLabel("通用", forSegment: 0)
        paneSelector.setLabel("快捷键", forSegment: 1)
        paneSelector.trackingMode = .selectOne
        paneSelector.selectedSegment = Pane.general.rawValue
        paneSelector.target = self
        paneSelector.action = #selector(paneChanged)
        paneSelector.frame = NSRect(x: (Self.width - 180) / 2, y: Self.height - 38, width: 180, height: 24)
        content.addSubview(paneSelector)

        let paneRect = NSRect(x: 0, y: Self.paneBottom, width: Self.width, height: Self.paneHeight)
        generalPane.frame = paneRect
        shortcutPane.frame = paneRect
        content.addSubview(generalPane)
        content.addSubview(shortcutPane)
        shortcutPane.isHidden = true

        buildGeneralPane()
        buildShortcutPane()

        let resetButton = NSButton(title: "恢复默认值", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: 20, y: 14, width: 104, height: 26)
        content.addSubview(resetButton)

        let doneButton = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: Self.width - 20 - 80, y: 14, width: 80, height: 26)
        content.addSubview(doneButton)
    }

    // MARK: - 通用页

    private func buildGeneralPane() {
        let content = generalPane
        content.wantsLayer = true

        maxRowsStepper.controlSize = .small
        maxRowsStepper.minValue = 1
        maxRowsStepper.maxValue = 6
        maxRowsStepper.increment = 1
        maxRowsStepper.valueWraps = false
        maxRowsStepper.target = self
        maxRowsStepper.action = #selector(maxRowsChanged)

        minWidthSlider.minValue = 120
        minWidthSlider.maxValue = 220
        minWidthSlider.isContinuous = true
        minWidthSlider.target = self
        minWidthSlider.action = #selector(minWidthChanged)

        tabSpacesCheckbox.setButtonType(.switch)
        tabSpacesCheckbox.title = "按 Tab 插入空格（宽度 4）"
        tabSpacesCheckbox.font = .systemFont(ofSize: 12)
        tabSpacesCheckbox.target = self
        tabSpacesCheckbox.action = #selector(tabSpacesChanged)

        thresholdStepper.controlSize = .small
        thresholdStepper.minValue = Double(Self.thresholdRange.lowerBound)
        thresholdStepper.maxValue = Double(Self.thresholdRange.upperBound)
        thresholdStepper.increment = 5
        thresholdStepper.valueWraps = false
        thresholdStepper.target = self
        thresholdStepper.action = #selector(thresholdChanged)

        // 阈值做成可直接输入：从 10MB 调到 200MB 靠步进要点 38 下
        thresholdValue.isEditable = true
        thresholdValue.isBordered = true
        thresholdValue.drawsBackground = true
        thresholdValue.backgroundColor = .textBackgroundColor
        thresholdValue.textColor = .labelColor
        thresholdValue.focusRingType = .exterior
        thresholdValue.alignment = .right
        thresholdValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        thresholdValue.target = self
        thresholdValue.action = #selector(thresholdFieldChanged)
        thresholdValue.delegate = self

        thresholdHint.font = .systemFont(ofSize: 11)
        thresholdHint.textColor = .tertiaryLabelColor
        thresholdHint.lineBreakMode = .byTruncatingTail

        draftSlider.minValue = 0.5
        draftSlider.maxValue = 10
        draftSlider.isContinuous = true
        draftSlider.target = self
        draftSlider.action = #selector(draftDelayChanged)

        for label in [maxRowsValue, minWidthValue, draftValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            content.addSubview(label)
        }
        // 阈值是唯一一个可编辑的数值框，样式在上面对单独设过，这里只需要挂进视图树
        content.addSubview(thresholdValue)

        var y = Self.paneHeight - 12

        placeSection("标签栏", in: content, y: &y)
        place("最大行数（1~6）", control: maxRowsStepper, value: maxRowsValue, in: content, y: &y, spacing: 32)
        place("标签最小宽度", control: minWidthSlider, value: minWidthValue, in: content, y: &y, spacing: 36)

        placeSection("编辑", in: content, y: &y)
        tabSpacesCheckbox.frame = NSRect(x: 18, y: y - 2, width: 260, height: 20)
        content.addSubview(tabSpacesCheckbox)
        y -= 32

        placeSection("大文件与会话", in: content, y: &y)
        place("只读阈值（MB）", control: thresholdStepper, value: thresholdValue, in: content, y: &y, spacing: 20)
        thresholdHint.frame = NSRect(x: 20, y: y + 4, width: Self.width - 40, height: 15)
        content.addSubview(thresholdHint)
        y -= 32
        place("草稿快照延迟", control: draftSlider, value: draftValue, in: content, y: &y, spacing: 32)

        let hint = NSTextField(labelWithString: "修改后立即生效，无需重启。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 20, y: y, width: Self.width - 40, height: 16)
        content.addSubview(hint)
    }

    private func placeSection(_ title: String, in content: NSView, y: inout CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: y, width: 200, height: 16)
        content.addSubview(label)
        y -= 26
    }

    private func place(_ title: String, control: NSView, value: NSTextField,
                       in content: NSView, y: inout CGFloat, spacing: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 20, y: y, width: Self.labelWidth, height: 18)
        content.addSubview(label)

        value.frame = NSRect(x: Self.width - 20 - Self.valueWidth, y: y, width: Self.valueWidth, height: 18)

        // NSStepper 会在给定宽度里居中绘制箭头，必须给它的自然宽度
        let isStepper = control is NSStepper
        let controlWidth = isStepper
            ? 19
            : Self.width - 20 - Self.valueWidth - 10 - Self.controlLeft
        control.frame = NSRect(x: Self.controlLeft, y: y - (isStepper ? 1 : 3),
                               width: controlWidth, height: isStepper ? 22 : 24)
        content.addSubview(control)

        y -= spacing
    }

    // MARK: - 快捷键页

    private func buildShortcutPane() {
        shortcutPane.wantsLayer = true

        shortcutHint.font = .systemFont(ofSize: 11)
        shortcutHint.textColor = .tertiaryLabelColor
        shortcutHint.lineBreakMode = .byTruncatingTail
        shortcutHint.frame = NSRect(x: 20, y: Self.paneHeight - 20, width: Self.width - 40, height: 16)
        shortcutPane.addSubview(shortcutHint)

        // 底部留 12pt：被裁切的行必须明显属于滚动区，不能贴着下面那排按钮
        shortcutScroll.frame = NSRect(x: 16, y: 12, width: Self.width - 32, height: Self.paneHeight - 42)
        shortcutScroll.hasVerticalScroller = true
        shortcutScroll.autohidesScrollers = true
        shortcutScroll.borderType = .noBorder
        shortcutScroll.drawsBackground = false
        shortcutScroll.scrollerStyle = .overlay
        shortcutScroll.documentView = shortcutContent
        shortcutPane.addSubview(shortcutScroll)

        buildShortcutRows()
        shortcutHint.stringValue = "点右侧按钮后按下新组合；Delete 清除，Esc 取消。"
    }

    private func buildShortcutRows() {
        for view in shortcutContent.subviews { view.removeFromSuperview() }
        recorders.removeAll()

        let rowHeight: CGFloat = 30
        let groupHeight: CGFloat = 26
        let contentWidth = max(300, shortcutScroll.contentSize.width)
        var y: CGFloat = 2
        var lastGroup = ""

        for action in ShortcutAction.allCases {
            if action.group != lastGroup {
                lastGroup = action.group
                let header = NSTextField(labelWithString: action.group)
                header.font = .systemFont(ofSize: 11, weight: .semibold)
                header.textColor = .secondaryLabelColor
                header.frame = NSRect(x: 4, y: y + 4, width: 200, height: 16)
                shortcutContent.addSubview(header)
                y += groupHeight
            }

            let title = NSTextField(labelWithString: action.title)
            title.font = .systemFont(ofSize: 12)
            title.frame = NSRect(x: 14, y: y + 3, width: 190, height: 18)
            shortcutContent.addSubview(title)

            let recorder = ShortcutRecorderButton()
            recorder.frame = NSRect(x: 210, y: y, width: 170, height: 22)
            recorder.combo = AppSettings.shared.shortcut(action)
            recorder.toolTip = "「\(action.title)」：点一下再按下新组合"
            recorder.onCommit = { [weak self] combo in self?.commit(combo, for: action) }
            shortcutContent.addSubview(recorder)
            recorders[action] = recorder

            y += rowHeight
        }

        shortcutContent.frame = NSRect(x: 0, y: 0, width: contentWidth,
                                       height: max(y + 4, shortcutScroll.contentSize.height))
    }

    private func commit(_ combo: KeyCombo?, for action: ShortcutAction) {
        let settings = AppSettings.shared
        if let combo, let other = settings.conflictingAction(for: combo, excluding: action) {
            shortcutHint.stringValue = "「\(other.title)」已占用 \(combo.displayText)，未修改"
            shortcutHint.textColor = .systemOrange
            recorders[action]?.combo = settings.shortcut(action)
            return
        }
        settings.setShortcut(combo, for: action)
        recorders[action]?.combo = settings.shortcut(action)
        if let combo {
            shortcutHint.stringValue = "「\(action.title)」→ \(combo.displayText)"
            shortcutHint.textColor = .secondaryLabelColor
        } else {
            shortcutHint.stringValue = "已清除「\(action.title)」的快捷键"
            shortcutHint.textColor = .secondaryLabelColor
        }
    }

    func selectPane(_ pane: Pane) {
        paneSelector.selectedSegment = pane.rawValue
        paneChanged()
    }

    @objc private func paneChanged() {
        let showShortcuts = paneSelector.selectedSegment == Pane.shortcuts.rawValue
        generalPane.isHidden = showShortcuts
        shortcutPane.isHidden = !showShortcuts
        if !showShortcuts {
            // 切走时结束录制，避免监听器留着吞按键
            for recorder in recorders.values { recorder.endRecording() }
        }
    }

    // MARK: - 同步

    @objc private func syncFromSettings() {
        let settings = AppSettings.shared
        maxRowsStepper.integerValue = settings.maxTabRows
        maxRowsValue.stringValue = "\(settings.maxTabRows) 行"

        minWidthSlider.doubleValue = Double(settings.minTabWidth)
        minWidthValue.stringValue = "\(Int(settings.minTabWidth.rounded())) pt"

        tabSpacesCheckbox.state = settings.tabInsertsSpaces ? .on : .off

        thresholdStepper.integerValue = settings.largeFileThresholdMB
        // 焦点在输入框里时别回写，否则用户敲一半就被覆盖
        if window?.firstResponder !== thresholdValue.currentEditor() {
            thresholdValue.stringValue = "\(settings.largeFileThresholdMB)"
        }
        let mb = settings.largeFileThresholdMB
        let sizeText = mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
        let hardLimitMB = EditorDocument.plainTextHardLimitBytes / 1024 / 1024
        thresholdHint.stringValue = "超过 \(sizeText) 只读，但仍可选中、复制、折行；超过 \(hardLimitMB) MB 才改用纯文本面板"

        draftSlider.doubleValue = settings.draftSnapshotDelaySec
        draftValue.stringValue = String(format: "%.1f 秒", settings.draftSnapshotDelaySec)

        for (action, recorder) in recorders where !recorder.isRecording {
            recorder.combo = settings.shortcut(action)
        }
    }

    // MARK: - 动作

    @objc private func maxRowsChanged() {
        AppSettings.shared.maxTabRows = maxRowsStepper.integerValue
        syncFromSettings()
    }

    @objc private func minWidthChanged() {
        AppSettings.shared.minTabWidth = CGFloat(minWidthSlider.doubleValue.rounded())
        syncFromSettings()
    }

    @objc private func tabSpacesChanged() {
        AppSettings.shared.tabInsertsSpaces = tabSpacesCheckbox.state == .on
    }

    @objc private func thresholdChanged() {
        AppSettings.shared.largeFileThresholdMB = thresholdStepper.integerValue
        syncFromSettings()
    }

    /// 输入框回车 / 失焦：解析失败就回退到当前值，别让空串把设置写成默认
    @objc private func thresholdFieldChanged() {
        let text = thresholdValue.stringValue
            .replacingOccurrences(of: "MB", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let mb = Int(text) {
            AppSettings.shared.largeFileThresholdMB = mb
        }
        syncFromSettings()
    }

    @objc private func draftDelayChanged() {
        AppSettings.shared.draftSnapshotDelaySec = (draftSlider.doubleValue * 10).rounded() / 10
        syncFromSettings()
    }

    @objc private func resetDefaults() {
        AppSettings.shared.resetToDefaults()
        syncFromSettings()
        shortcutHint.stringValue = "已恢复全部默认设置（含快捷键）"
        shortcutHint.textColor = .secondaryLabelColor
    }

    @objc private func closeWindow() {
        for recorder in recorders.values { recorder.endRecording() }
        window?.close()
    }

    @objc func showSettings(_ sender: Any?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 快捷键列表容器：从上到下排布，靠 scroll view 撑高
final class ShortcutListContainer: NSView {
    override var isFlipped: Bool { true }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// 输入框失焦也算提交：用户改完直接点别处，不该丢掉这次修改
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === thresholdValue else { return }
        thresholdFieldChanged()
    }
}

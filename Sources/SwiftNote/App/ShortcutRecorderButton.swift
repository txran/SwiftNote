import AppKit
import SwiftNoteKit

/// 快捷键录制按钮：点一下进入录制态，捕获下一次按键组合。
///
/// 用本地事件监听而不是 `keyDown`：⌘ 组合会先被菜单栏截走，
/// 录制期间必须在这一层就把事件吞掉，否则按 ⌘S 会直接触发保存。
final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo? {
        didSet { refreshTitle() }
    }
    /// 提交结果；nil 表示清除
    var onCommit: ((KeyCombo?) -> Void)?

    private var monitor: Any?
    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        bezelStyle = .rounded
        font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        focusRingType = .none
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    // MARK: - 录制

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) {
            [weak self] event in
            guard let self, self.isRecording else { return event }
            switch event.type {
            case .flagsChanged:
                return nil                     // 只按修饰键不算输入，吞掉避免切焦点
            case .leftMouseDown:
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.stopRecording() }
                return event                   // 鼠标照常派发，点别处就结束录制
            default:
                self.handleKey(event)
                return nil                     // 录制期间的按键一律吞掉
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53:                               // Esc：取消，保持原值
            stopRecording()
        case 51, 117:                           // Delete / Forward Delete：清除
            onCommit?(nil)
            stopRecording()
        default:
            guard let combo = KeyCombo.from(event: event) else {
                NSSound.beep()                  // 没有 ⌘/⌃/⌥ 的组合不收
                return
            }
            onCommit?(combo)
            stopRecording()
        }
    }

    /// 外部（切页签/关窗口）要求结束录制
    func endRecording() {
        stopRecording()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTitle()
    }

    private func refreshTitle() {
        if isRecording {
            title = "按下快捷键…"
            contentTintColor = .controlAccentColor
        } else if let combo {
            title = combo.displayText
            contentTintColor = .labelColor
        } else {
            title = "未设置"
            contentTintColor = .tertiaryLabelColor
        }
    }
}

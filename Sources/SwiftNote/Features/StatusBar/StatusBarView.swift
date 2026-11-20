import AppKit
import SwiftNoteKit

/// 状态栏：路径 / 行列 / 编码 / 换行符 / 语法模式 / 校验提示（FR-01、FR-05、FR-11）
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    var onEncodingClick: ((NSButton) -> Void)?
    var onSyntaxClick: ((NSButton) -> Void)?
    var onLineEndingClick: ((NSButton) -> Void)?
    var onWrapToggle: ((NSButton) -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "行 1，列 1")
    private let encodingButton = NSButton(title: "UTF-8", target: nil, action: nil)
    private let lineEndingButton = NSButton(title: "LF", target: nil, action: nil)
    private let syntaxButton = NSButton(title: "JSON", target: nil, action: nil)
    private let readOnlyLabel = NSTextField(labelWithString: "")
    /// 自动换行开关：右下角常驻显示当前状态，点一下切换（与「显示」菜单里那项同一份设置）
    private let wrapButton = NSButton(title: "自动换行 开", target: nil, action: nil)

    private var validationMessage: String?
    /// 校验消息是否为错误（错误红、提示灰）
    private var validationIsError = true
    /// 外部变更提示（FR-11）：优先级高于校验消息，因为「文件被删/被改」比「JSON 有错」更急
    private var externalNotice: String?
    private var line = 1
    private var column = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let small = NSFont.systemFont(ofSize: 11)
        for label in [pathLabel, messageLabel, positionLabel, readOnlyLabel] {
            label.font = small
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        positionLabel.alignment = .right

        for button in [encodingButton, lineEndingButton, syntaxButton, wrapButton] {
            button.isBordered = false
            button.font = small
            button.contentTintColor = .secondaryLabelColor
            button.bezelStyle = .inline
            addSubview(button)
        }
        encodingButton.target = self
        encodingButton.action = #selector(encodingTapped)
        lineEndingButton.target = self
        lineEndingButton.action = #selector(lineEndingTapped)
        syntaxButton.target = self
        syntaxButton.action = #selector(syntaxTapped)
        wrapButton.target = self
        wrapButton.action = #selector(wrapTapped)
        readOnlyLabel.textColor = .systemOrange
        readOnlyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        updateWrapLines(AppSettings.shared.wrapLines)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func encodingTapped() { onEncodingClick?(encodingButton) }
    @objc private func lineEndingTapped() { onLineEndingClick?(lineEndingButton) }
    @objc private func syntaxTapped() { onSyntaxClick?(syntaxButton) }
    @objc private func wrapTapped() { onWrapToggle?(wrapButton) }

    /// 换行是全局设置（不是文档属性），所以不走 `update(document:)`，单独一个入口。
    /// 三种视图（正常编辑 / 只读 TextKit / 大文件面板）现在都支持折行，不再有置灰态
    func updateWrapLines(_ enabled: Bool) {
        wrapButton.title = enabled ? "自动换行 开" : "自动换行 关"
        // 关＝灰但不能灰到看不见（tertiaryLabelColor 在深色下只剩 22% 白）
        wrapButton.contentTintColor = enabled ? .labelColor : .secondaryLabelColor
        wrapButton.toolTip = enabled ? "自动换行：开 · 点击关闭" : "自动换行：关 · 点击开启"
        needsLayout = true
    }

    /// 无头核对用
    func wrapSummary() -> String {
        "\(wrapButton.title) · frame=\(NSStringFromRect(wrapButton.frame))"
            + " · 隐藏=\(wrapButton.isHidden) · 可用=\(wrapButton.isEnabled)"
    }

    func update(document: EditorDocument?) {
        guard let doc = document else {
            pathLabel.stringValue = ""
            positionLabel.stringValue = ""
            encodingButton.title = "UTF-8"
            encodingButton.toolTip = nil
            lineEndingButton.title = "LF"
            syntaxButton.title = ""
            readOnlyLabel.stringValue = ""
            messageLabel.stringValue = ""
            externalNotice = nil
            needsLayout = true
            return
        }
        pathLabel.stringValue = doc.fileURL?.path ?? "未命名"
        // BOM 是文件属性、不是编码，但用户在状态栏最关心的就是「我这份文件带不带 BOM」
        encodingButton.title = (doc.encoding == .utf8 && doc.hasBOM)
            ? "UTF-8 BOM" : doc.encoding.displayName
        encodingButton.toolTip = doc.encoding == .utf8
            ? (doc.hasBOM ? "UTF-8（带 BOM）· 点击切换编码" : "UTF-8（无 BOM）· 点击切换编码")
            : "\(doc.encoding.displayName) · 点击切换编码"
        lineEndingButton.title = doc.lineEnding.displayName
        syntaxButton.title = doc.syntaxMode.displayName
        readOnlyLabel.stringValue = doc.isReadOnly ? "只读 · \(doc.readOnlyReason?.displayText ?? "")" : ""
        refreshMessage()
        needsLayout = true
    }

    func updatePosition(line: Int, column: Int) {
        self.line = line
        self.column = column
        // line == 0 表示「不计算行列号」（超大文件跳过全文行表，见 EditorContainerView）
        positionLabel.stringValue = line > 0 ? "行 \(line)，列 \(column)" : "行 —"
        needsLayout = true
    }

    func setValidationMessage(_ message: String?, isError: Bool = true) {
        validationMessage = message
        validationIsError = isError
        refreshMessage()
    }

    /// 外部修改 / 文件被删除时的常驻提示；传 nil 清除
    func setExternalNotice(_ text: String?) {
        guard externalNotice != text else { return }
        externalNotice = text
        refreshMessage()
    }

    private func refreshMessage() {
        if let notice = externalNotice {
            messageLabel.stringValue = notice
            messageLabel.textColor = .systemOrange
        } else if let message = validationMessage {
            messageLabel.stringValue = message
            messageLabel.textColor = validationIsError ? .systemRed : .secondaryLabelColor
        } else {
            messageLabel.stringValue = ""
            messageLabel.textColor = .systemRed
        }
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 16
        let y = (bounds.height - h) / 2
        var x: CGFloat = 10

        pathLabel.sizeToFit()
        let pathWidth = min(pathLabel.frame.width, bounds.width * 0.42)
        pathLabel.frame = NSRect(x: x, y: y, width: pathWidth, height: h)
        x += pathWidth + 12

        messageLabel.sizeToFit()
        // 右侧预留：只读提示 + LF + 编码 + 语法 + 行列 + 自动换行（多一个开关就多 82pt）
        messageLabel.frame = NSRect(x: x, y: y,
                                    width: max(0, bounds.width - x - 490), height: h)

        var right: CGFloat = bounds.width - 10
        // 自动换行放最右端（用户要的「右下角展示」）；「行/列」往左让一位
        wrapButton.sizeToFit()
        let wrapW = max(74, wrapButton.frame.width + 10)
        wrapButton.frame = NSRect(x: right - wrapW, y: y - 2, width: wrapW, height: h + 4)
        right -= wrapW + 8

        positionLabel.sizeToFit()
        let posWidth = max(90, positionLabel.frame.width)
        positionLabel.frame = NSRect(x: right - posWidth, y: y, width: posWidth, height: h)
        right -= posWidth + 10

        syntaxButton.sizeToFit()
        let synW = max(56, syntaxButton.frame.width + 10)
        syntaxButton.frame = NSRect(x: right - synW, y: y - 2, width: synW, height: h + 4)
        right -= synW + 6

        encodingButton.sizeToFit()
        let encW = max(50, encodingButton.frame.width + 10)
        encodingButton.frame = NSRect(x: right - encW, y: y - 2, width: encW, height: h + 4)
        right -= encW + 6

        lineEndingButton.sizeToFit()
        let eolW = max(46, lineEndingButton.frame.width + 10)
        lineEndingButton.frame = NSRect(x: right - eolW, y: y - 2, width: eolW, height: h + 4)
        right -= eolW + 8

        if !readOnlyLabel.stringValue.isEmpty {
            readOnlyLabel.sizeToFit()
            let roW = readOnlyLabel.frame.width
            readOnlyLabel.frame = NSRect(x: right - roW, y: y, width: roW, height: h)
        } else {
            readOnlyLabel.frame = .zero
        }
    }
}

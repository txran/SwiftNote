import Foundation

/// 文档状态机：单一入口 transition(event:)，非法迁移断言拦截（设计说明书 4.3）
public final class DocumentStateMachine {
    public private(set) var state: DocumentState

    public init(state: DocumentState = .clean) {
        self.state = state
    }

    @discardableResult
    public func transition(_ event: DocumentEvent) -> DocumentState {
        switch (state, event) {
        case (.clean, .edited), (.dirty, .edited):
            state = .dirty
        case (.dirty, .saved), (.clean, .saved):
            state = .clean
        case (_, .demotedToReadOnly):
            state = .readOnly
        case (.readOnly, .savedAsNewFile), (_, .savedAsNewFile):
            state = .clean
        case (.readOnly, .edited):
            assertionFailure("只读文档收到 edited 事件，调用方未走 ReadOnlyPolicy（设计说明书 5.10）")
        case (.readOnly, .saved):
            assertionFailure("只读文档禁止保存，调用方未走 ReadOnlyPolicy（设计说明书 5.10）")
        }
        return state
    }

    public func forceSet(_ newState: DocumentState) {
        state = newState
    }
}

/// 一个打开的文档 = 一个标签
public final class EditorDocument: Identifiable {
    public let id: UUID
    public var fileURL: URL?
    public var syntaxMode: SyntaxMode
    public var encoding: FileEncoding
    /// 磁盘上使用的换行风格。内存文本恒为 `\n`，保存时按它写回；
    /// 在状态栏切换后只改这个字段 + 标脏，文本本身不动（Notepad++ 同款行为）
    public var lineEnding: LineEnding
    /// 保存时是否写 UTF-8 BOM（打开时探测、可手动切换；GBK 下无意义）
    public var hasBOM: Bool
    public var readOnlyReason: ReadOnlyReason?
    public var fileMeta: FileMeta?
    public var scrollPosition: CGFloat
    public var cursorOffset: Int
    /// 非活动标签的内存文本（保存 / 草稿快照用；活动标签的权威文本在 NSTextView 中）
    public var cachedText: String
    /// 外部修改冲突标记（FR-11）
    public var hasExternalConflict: Bool = false
    /// 文件已被外部删除（异常 #3）
    public var isFileMissing: Bool = false

    /// 磁盘上那份内容的指纹：撤销/重做回到这个状态时，文档应重新变回「未修改」
    public private(set) var savedFingerprint: TextFingerprint = .empty

    private let stateMachine: DocumentStateMachine

    public init(id: UUID = UUID(),
                fileURL: URL? = nil,
                text: String = "",
                encoding: FileEncoding = .utf8,
                syntaxMode: SyntaxMode = .plain,
                lineEnding: LineEnding = .lf,
                hasBOM: Bool = false) {
        self.id = id
        self.fileURL = fileURL
        self.cachedText = text
        self.encoding = encoding
        self.syntaxMode = syntaxMode
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
        self.scrollPosition = 0
        self.cursorOffset = 0
        self.savedFingerprint = TextFingerprint(text: text)
        self.stateMachine = DocumentStateMachine()
    }

    public var state: DocumentState { stateMachine.state }
    public var isDirty: Bool { state == .dirty }
    public var isReadOnly: Bool { state == .readOnly }
    public var isUntitled: Bool { fileURL == nil }

    public var displayName: String {
        let base = fileURL?.lastPathComponent ?? "未命名"
        return isFileMissing ? "\(base)（已删除）" : base
    }

    public var fileSizeBytes: Int64 { fileMeta?.size ?? Int64(cachedText.utf8.count) }

    /// 进 TextKit 的**硬上限**：超过这个体积，无论用户把「只读阈值」调多大，
    /// 都必须走纯文本面板——`NSTextView` 是全量排版的，几十 MB 会把主线程钉死（D-23~D-26）。
    public static let plainTextHardLimitBytes: Int64 = 10 * 1024 * 1024

    /// 超过硬上限 → 主编辑器改用纯文本只读面板（不进 TextKit）。
    ///
    /// 刻意**不跟用户可调的只读阈值**联动：阈值只回答「能不能编辑」，
    /// 而「能不能选中 / 折行 / 高亮」取决于能不能进 TextKit。阈值调到 1MB 时，
    /// 一份 1.7MB 的配置文件仍该是个正常编辑器（只读），而不是 `less` 式面板。
    public var prefersPlainText: Bool {
        fileSizeBytes > Self.plainTextHardLimitBytes
    }

    public func markEdited() { stateMachine.transition(.edited) }

    /// 保存完成。带上 `text` 时一并记录磁盘基线（撤销回退判定的依据）
    public func markSaved(text: String? = nil) {
        if let text { savedFingerprint = TextFingerprint(text: text) }
        stateMachine.transition(.saved)
    }

    /// 当前内容是否与磁盘上的那份一致？
    ///
    /// 只在撤销/重做这类低频时机调用：1MB 文本算一次指纹约 1ms，
    /// 放进逐键 `textDidChange` 会白白吃掉每次按键的预算。
    public func matchesSavedText(_ text: String) -> Bool {
        TextFingerprint(text: text) == savedFingerprint
    }

    /// 重新加载 / 编码切换后，把新内容记为磁盘基线（不改变文档状态）
    public func captureSavedText(_ text: String) {
        savedFingerprint = TextFingerprint(text: text)
    }

    public func demoteToReadOnly(_ reason: ReadOnlyReason) {
        readOnlyReason = reason
        stateMachine.transition(.demotedToReadOnly(reason))
    }

    /// 解除「大文件只读」：用户把阈值调大到能包住这个文件了。
    ///
    /// 只解 `.largeFile` 这一种原因——`.permission` 是磁盘权限，跟阈值无关，
    /// 换个阈值不会让只读目录变得可写。
    @discardableResult
    public func promoteFromLargeFileReadOnly() -> Bool {
        guard state == .readOnly, readOnlyReason == .largeFile else { return false }
        readOnlyReason = nil
        stateMachine.forceSet(.clean)
        return true
    }

    /// 另存为后成为新 Clean 文档
    public func adopt(fileURL: URL, meta: FileMeta?, text: String? = nil) {
        self.fileURL = fileURL
        self.fileMeta = meta
        if let text { savedFingerprint = TextFingerprint(text: text) }
        self.isFileMissing = false
        self.hasExternalConflict = false
        self.readOnlyReason = nil
        stateMachine.transition(.savedAsNewFile)
    }

    /// 探测磁盘状态，返回变更结论（FR-11）
    ///
    /// 只做「探测 + 记账」，不自己决定提示还是重载——那是 EditorStore 的职责，
    /// 因为要区分 Clean / Dirty 走不同话术。探测后基线立即更新，
    /// 避免同一次变更被反复上报。
    @discardableResult
    public func refreshExternalState() -> ExternalFileChange {
        guard let url = fileURL else { return .none }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let current = exists ? FileMeta.read(from: url) : nil
        let change = FileChangeDetector.compare(cached: fileMeta, current: current)

        switch change {
        case .none:
            if let current { fileMeta = current }
            isFileMissing = false
        case .modified:
            fileMeta = current
            isFileMissing = false
            hasExternalConflict = true
        case .deleted:
            isFileMissing = true
        }
        return change
    }

    /// 保存 / 重新加载后刷新基线，并清掉冲突标记
    public func rebaseOnDisk() {
        guard let url = fileURL else { return }
        fileMeta = FileMeta.read(from: url)
        isFileMissing = false
        hasExternalConflict = false
    }
}

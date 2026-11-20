import AppKit
import SwiftNoteKit

extension Notification.Name {
    static let swiftNoteDocumentsChanged = Notification.Name("SwiftNote.documentsChanged")
    static let swiftNoteActiveDocumentChanged = Notification.Name("SwiftNote.activeDocumentChanged")
    static let swiftNoteDocumentStateChanged = Notification.Name("SwiftNote.documentStateChanged")
    static let swiftNoteCursorMoved = Notification.Name("SwiftNote.cursorMoved")
    static let swiftNoteValidationChanged = Notification.Name("SwiftNote.validationChanged")
    /// 会话恢复的内容是首帧之后异步到的，挂着的视图要据此重建（大文件行索引按空内容建过）
    static let swiftNoteDocumentContentLoaded = Notification.Name("SwiftNote.documentContentLoaded")
}

/// 文档与标签的协调中心（Features/Store）
final class EditorStore {
    static let shared = EditorStore()

    private(set) var documents: [EditorDocument] = []
    private(set) var activeIndex: Int = -1
    private(set) var recentFiles: [String] = []

    let drafts = DraftStore()
    let session = SessionService()

    private(set) var editors: [UUID: EditorContainerView] = [:]
    private var sessionSaveWork: DispatchWorkItem?

    /// 每文档一个 vnode 监视（FR-11 第一重保险）；窗口激活时另有 mtime 兜底
    var watchers: [UUID: FileWatcher] = [:]
    /// 冲突弹窗串行化：批量场景下不叠弹窗
    var isPresentingConflict = false

    var activeDocument: EditorDocument? {
        documents.indices.contains(activeIndex) ? documents[activeIndex] : nil
    }

    var activeEditor: EditorContainerView? {
        activeDocument.map { editor(for: $0) }
    }

    // MARK: - 编辑区

    func editor(for document: EditorDocument) -> EditorContainerView {
        if let existing = editors[document.id] { return existing }
        let container = EditorContainerView(document: document)
        container.onTextChanged = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .swiftNoteDocumentStateChanged, object: self)
            self.scheduleSessionSave()
        }
        container.onCursorMoved = { line, column in
            NotificationCenter.default.post(name: .swiftNoteCursorMoved, object: nil,
                                            userInfo: ["line": line, "column": column])
        }
        container.onValidationChanged = { message in
            NotificationCenter.default.post(name: .swiftNoteValidationChanged, object: nil,
                                            userInfo: ["message": message as Any, "isError": true])
        }
        container.onNotice = { message in
            NotificationCenter.default.post(name: .swiftNoteValidationChanged, object: nil,
                                            userInfo: ["message": message, "isError": false])
        }
        container.onRequestSnapshot = { [weak self, weak document] in
            guard let self, let document, let editor = self.editors[document.id] else { return }
            editor.syncToDocument()
            if document.isDirty {
                self.drafts.save(editor.text, for: document.id)
            }
        }
        container.onRevertedToClean = { [weak self, weak document] in
            guard let self, let document else { return }
            // 撤销回到磁盘内容：草稿已经没有存在意义，留着下次启动会把它当成未保存修改
            self.drafts.remove(for: document.id)
            NotificationCenter.default.post(name: .swiftNoteDocumentStateChanged, object: self)
            self.scheduleSessionSave()
        }
        editors[document.id] = container
        return container
    }

    // MARK: - 打开

    func open(urls: [URL], completion: (() -> Void)? = nil) {
        let urls = urls.filter { $0.isFileURL }
        guard !urls.isEmpty else { completion?(); return }

        let started = Date()
        FileLoader.loadAsync(urls: urls) { [weak self] loadedFiles, failures in
            guard let self else { return }
            AppLogger.info(String(format: "打开耗时（读盘+解码）%.2fs × %d 个文件",
                                  Date().timeIntervalSince(started), loadedFiles.count))
            var lastTargetIndex: Int?
            for file in loadedFiles {
                if let existing = self.documents.firstIndex(where: { $0.fileURL == file.url }) {
                    // 已经开着就直接切过去。注意别在循环外统一把 activeIndex 设成最后一个：
                    // 用户双击一份已经打开的文件时，那样会被带到别人的标签上
                    lastTargetIndex = existing
                    self.activate(index: existing)
                    continue
                }
                let doc = EditorDocument(fileURL: file.url,
                                         text: file.text,
                                         encoding: file.encoding,
                                         syntaxMode: file.syntaxMode,
                                         lineEnding: file.lineEnding,
                                         hasBOM: file.hasBOM)
                doc.fileMeta = file.meta
                let threshold = AppSettings.shared.largeFileThresholdBytes
                // 两个上限取小的：用户阈值，以及「进不了 TextKit」的硬上限
                let limit = min(threshold, EditorDocument.plainTextHardLimitBytes)
                if file.sizeBytes > limit {
                    doc.demoteToReadOnly(.largeFile)
                    AppLogger.info("大文件 \(file.url.lastPathComponent) \(file.sizeBytes / 1024 / 1024)MB → 只读")
                } else if !FileManager.default.isWritableFile(atPath: file.url.path) {
                    doc.demoteToReadOnly(.permission)
                }
                self.documents.append(doc)
                lastTargetIndex = self.documents.count - 1
                self.startWatching(doc)
                self.recordRecent(file.url)
            }
            // 多个文件一起打开时落到最后一个；全都已经开着时落到被点名的那个
            if let lastTargetIndex {
                self.activeIndex = lastTargetIndex
            }
            self.postDocumentsChanged()
            self.postActiveChanged()
            if !failures.isEmpty {
                self.presentFailures(failures)
            }
            self.scheduleSessionSave()
            completion?()
        }
    }

    func newDocument(activate shouldActivate: Bool = true) {
        let doc = EditorDocument()
        documents.append(doc)
        if shouldActivate {
            activeIndex = documents.count - 1
        }
        postDocumentsChanged()
        postActiveChanged()
        scheduleSessionSave()
    }

    // MARK: - 激活 / 关闭

    func activate(index: Int) {
        guard documents.indices.contains(index), index != activeIndex else { return }
        if let current = activeDocument {
            editors[current.id]?.syncToDocument()
            if current.isDirty, let editor = editors[current.id] {
                drafts.save(editor.text, for: current.id)
            }
        }
        activeIndex = index
        postActiveChanged()
    }

    /// 关闭标签；脏文档弹「保存 / 不保存 / 取消」
    /// - Returns: 是否已关闭
    @discardableResult
    func closeTab(index: Int) -> Bool {
        guard documents.indices.contains(index) else { return false }
        let doc = documents[index]
        editors[doc.id]?.syncToDocument()

        if doc.isDirty {
            let alert = NSAlert()
            alert.messageText = "「\(doc.displayName)」有未保存的修改"
            alert.informativeText = "关闭前是否保存？"
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "不保存")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !save(document: doc) { return false }
            case .alertSecondButtonReturn:
                break
            default:
                return false
            }
        }

        removeDocument(at: index)
        return true
    }

    // MARK: - 大文件阈值变更

    /// 阈值改了以后按新阈值重新评估**已打开**的文档。
    ///
    /// 只改设置不重评估的话，用户把阈值从 10MB 调到 100MB，
    /// 眼前的 20MB 文件还是只读——只能关掉重开，看起来就像设置没生效。
    ///
    /// - Returns: 被改为只读 / 恢复可编辑 / 因为有未保存修改而跳过的文档
    @discardableResult
    func reapplyLargeFilePolicy() -> (demoted: [EditorDocument],
                                      promoted: [EditorDocument],
                                      skippedDirty: [EditorDocument]) {
        let threshold = AppSettings.shared.largeFileThresholdBytes
        // 超硬上限的文件永远只读：阈值调多大都不能让 TextKit 去排版几十 MB
        let limit = min(threshold, EditorDocument.plainTextHardLimitBytes)
        var demoted: [EditorDocument] = []
        var promoted: [EditorDocument] = []
        var skippedDirty: [EditorDocument] = []

        for doc in documents {
            let overLimit = doc.fileSizeBytes > limit
            if doc.isReadOnly {
                // 先判体积再解锁：还在阈上就别动它
                if doc.readOnlyReason == .largeFile, !overLimit, doc.promoteFromLargeFileReadOnly() {
                    promoted.append(doc)
                }
            } else if overLimit {
                // 有未保存修改的先不动：变成只读就再也存不下去，等于逼用户丢内容
                if doc.isDirty {
                    skippedDirty.append(doc)
                } else {
                    doc.demoteToReadOnly(.largeFile)
                    demoted.append(doc)
                }
            }
        }

        guard !demoted.isEmpty || !promoted.isEmpty else { return (demoted, promoted, skippedDirty) }
        postDocumentsChanged()
        postActiveChanged()
        scheduleSessionSave()
        AppLogger.info("阈值重评估：改为只读 \(demoted.count)、恢复可编辑 \(promoted.count)、跳过后有修改 \(skippedDirty.count)")
        return (demoted, promoted, skippedDirty)
    }

    private func removeDocument(at index: Int) {
        let doc = documents[index]
        stopWatching(doc)
        editors[doc.id]?.removeFromSuperview()
        editors.removeValue(forKey: doc.id)
        drafts.remove(for: doc.id)
        documents.remove(at: index)

        if documents.isEmpty {
            activeIndex = -1
        } else if index < activeIndex {
            activeIndex -= 1
        } else if index == activeIndex {
            activeIndex = min(index, documents.count - 1)
        }
        postDocumentsChanged()
        postActiveChanged()
        scheduleSessionSave()
    }

    // MARK: - 保存

    @discardableResult
    func save(document: EditorDocument) -> Bool {
        guard !document.isReadOnly else {
            presentSimpleAlert(title: "只读模式无法保存",
                               message: "该文件以只读方式打开，请使用「另存为」保存副本。")
            return false
        }
        guard let editor = editors[document.id] else {
            return saveAs(document: document)
        }
        editor.syncToDocument()
        guard let url = document.fileURL else {
            return saveAs(document: document)
        }
        do {
            try AtomicSaver.save(text: editor.text, to: url,
                                 encoding: document.encoding,
                                 lineEnding: document.lineEnding,
                                 bom: document.hasBOM)
            document.markSaved(text: editor.text)
            // 保存前/后的输入分成两步：保存不该把撤销步骤连成一串
            editor.breakUndoCoalescing()
            document.rebaseOnDisk()
            // 原子写把 inode 换掉了，旧 vnode 源已失效 → 重新挂载
            restartWatching(document)
            drafts.remove(for: document.id)
            recordRecent(url)
            postDocumentsChanged()
            scheduleSessionSave()
            return true
        } catch {
            presentSimpleAlert(title: "保存失败", message: error.localizedDescription)
            return false
        }
    }

    /// 另存为。`encoding` / `bom` 给定时按传入的写，否则沿用文档当前设置——
    /// 「脏文件切编码」的三选里有一项是「用新编码另存为」，走的就是这条带参路径
    @discardableResult
    func saveAs(document: EditorDocument, encoding: FileEncoding? = nil, bom: Bool? = nil) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? "未命名.txt"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let editor = editors[document.id] else { return false }
        editor.syncToDocument()
        let targetEncoding = encoding ?? document.encoding
        let targetBOM = bom ?? document.hasBOM
        do {
            try AtomicSaver.save(text: editor.text, to: url,
                                 encoding: targetEncoding,
                                 lineEnding: document.lineEnding,
                                 bom: targetBOM)
            document.adopt(fileURL: url, meta: FileMeta.read(from: url), text: editor.text)
            document.encoding = targetEncoding
            document.hasBOM = targetBOM
            editor.breakUndoCoalescing()
            document.syntaxMode = SyntaxMode.detect(fileURL: url, contentPrefix: String(editor.text.prefix(4096)))
            restartWatching(document)
            drafts.remove(for: document.id)
            recordRecent(url)
            postDocumentsChanged()
            scheduleSessionSave()
            return true
        } catch {
            presentSimpleAlert(title: "保存失败", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - 排序

    func reorder(by ids: [UUID]) {
        let map = Dictionary(uniqueKeysWithValues: documents.enumerated().map { ($1.id, $0) })
        let previousActiveID = activeDocument?.id
        var reordered: [EditorDocument] = []
        for id in ids {
            if let index = map[id] { reordered.append(documents[index]) }
        }
        for doc in documents where !reordered.contains(where: { $0.id == doc.id }) {
            reordered.append(doc)
        }
        documents = reordered
        if let activeID = previousActiveID, let newIndex = documents.firstIndex(where: { $0.id == activeID }) {
            activeIndex = newIndex
        }
        postDocumentsChanged()
        scheduleSessionSave()
    }

    // MARK: - 最近文件

    func recordRecent(_ url: URL) {
        let path = url.path
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > SessionService.maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(SessionService.maxRecentFiles))
        }
    }

    /// 从最近文件里移除一条（文件已被删/移动时）
    func removeRecent(_ path: String) {
        guard recentFiles.contains(path) else { return }
        recentFiles.removeAll { $0 == path }
        scheduleSessionSave()
    }

    func clearRecentFiles() {
        guard !recentFiles.isEmpty else { return }
        recentFiles.removeAll()
        scheduleSessionSave()
    }

    // MARK: - 会话

    func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSession() }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func persistSession() {
        AppPaths.ensureDirectories()
        var tabs: [TabSnapshot] = []
        for doc in documents {
            if let editor = editors[doc.id] {
                editor.syncToDocument()
            }
            if doc.isDirty, let editor = editors[doc.id] {
                drafts.save(editor.text, for: doc.id)
            }
            tabs.append(TabSnapshot(id: doc.id.uuidString,
                                    filePath: doc.fileURL?.path,
                                    hasDraft: drafts.hasDraft(for: doc.id),
                                    scrollPosition: Double(doc.scrollPosition),
                                    cursorOffset: doc.cursorOffset,
                                    encoding: doc.encoding.rawValue,
                                    syntaxMode: doc.syntaxMode.rawValue,
                                    readOnly: doc.isReadOnly,
                                    lineEnding: doc.lineEnding.rawValue,
                                    hasBOM: doc.hasBOM))
        }
        let snapshot = SessionSnapshot(activeTabIndex: max(0, activeIndex),
                                       tabs: tabs,
                                       recentFiles: recentFiles)
        session.save(snapshot)
    }

    /// 启动恢复（两段式，R-18 / P-27）
    ///
    /// 首帧前只做「必须在首帧前定」的事：读 session.json（几百字节）+ stat 每个文件，
    /// 据此把标签、只读状态、光标位置先摆好；**内容一律首帧之后在后台读**。
    /// 旧实现把每个文件的全文读盘串行压在 `didFinishLaunching` 里——会话里有 100MB 日志时
    /// 启动会被拖住，冷缓存下甚至等出 -1712（读盘落在系统 open(2) 上的慢路径）。
    ///
    /// - Returns: 是否恢复出文档
    @discardableResult
    func restoreSession() -> Bool {
        guard let snapshot = session.load() else { return false }
        recentFiles = snapshot.recentFiles

        var restored: [EditorDocument] = []
        var pendingIDs: [UUID] = []
        var skipped = 0

        for tab in snapshot.tabs {
            guard let uuid = UUID(uuidString: tab.id) else { continue }
            let fileURL = tab.filePath.map { URL(fileURLWithPath: $0) }
            let exists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let encoding = FileEncoding(rawValue: tab.encoding) ?? .utf8
            let syntaxMode = SyntaxMode(rawValue: tab.syntaxMode) ?? .plain

            if let url = fileURL, exists {
                // stat 是毫秒级，读全文不是
                let meta = FileMeta.read(from: url)
                let doc = EditorDocument(id: uuid, fileURL: url, text: "",
                                         encoding: encoding, syntaxMode: syntaxMode,
                                         lineEnding: LineEnding(rawValue: tab.lineEnding ?? "") ?? .lf,
                                         hasBOM: tab.hasBOM ?? false)
                doc.fileMeta = meta
                doc.scrollPosition = CGFloat(tab.scrollPosition)
                doc.cursorOffset = tab.cursorOffset
                if tab.readOnly || (meta?.size ?? 0) > AppSettings.shared.largeFileThresholdBytes {
                    doc.demoteToReadOnly(.largeFile)
                }
                restored.append(doc)
                pendingIDs.append(uuid)
            } else if drafts.hasDraft(for: uuid) {
                // 文件没了但草稿还在：先把空壳恢复出来，内容同样等首帧后读
                let doc = EditorDocument(id: uuid, fileURL: fileURL, text: "",
                                         encoding: encoding, syntaxMode: syntaxMode,
                                         lineEnding: LineEnding(rawValue: tab.lineEnding ?? "") ?? .lf,
                                         hasBOM: tab.hasBOM ?? false)
                doc.scrollPosition = CGFloat(tab.scrollPosition)
                doc.cursorOffset = tab.cursorOffset
                doc.isFileMissing = fileURL != nil
                doc.markEdited()
                restored.append(doc)
                pendingIDs.append(uuid)
            } else {
                skipped += 1
            }
        }

        guard !restored.isEmpty else { return false }
        documents = restored
        activeIndex = min(max(0, snapshot.activeTabIndex), restored.count - 1)
        startWatchingAll()
        postDocumentsChanged()
        postActiveChanged()

        // 首帧之后补内容（到这时窗口已经按正确布局显示出来了）；
        // 活动标签排最前，用户最想看到的那份先上线
        if documents.indices.contains(activeIndex) {
            let activeID = documents[activeIndex].id
            if let index = pendingIDs.firstIndex(of: activeID) {
                pendingIDs.remove(at: index)
                pendingIDs.insert(activeID, at: 0)
            }
        }
        let order = pendingIDs
        DispatchQueue.main.async { [weak self] in
            self?.loadRestoredContents(order)
        }

        if skipped > 0 {
            AppLogger.warn("会话恢复跳过 \(skipped) 个失效标签")
        }
        return true
    }

    /// 后台读回恢复标签的内容（文件 + 草稿），完成后写回文档并刷新已挂载的编辑器
    private func loadRestoredContents(_ ids: [UUID]) {
        for id in ids {
            guard let doc = documents.first(where: { $0.id == id }) else { continue }
            let url = doc.fileURL
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var loaded: LoadedFile?
                if let url, FileManager.default.fileExists(atPath: url.path) {
                    loaded = try? FileLoader.load(url: url)
                }
                let draft = self?.drafts.load(for: id)
                DispatchQueue.main.async {
                    guard let self, let doc = self.documents.first(where: { $0.id == id }) else { return }
                    if let loaded {
                        doc.cachedText = loaded.text
                        doc.fileMeta = loaded.meta
                        doc.encoding = loaded.encoding
                        doc.syntaxMode = loaded.syntaxMode
                        doc.lineEnding = loaded.lineEnding
                        doc.hasBOM = loaded.hasBOM
                    }
                    if let draft, !draft.isEmpty, draft != doc.cachedText, !doc.isReadOnly {
                        doc.cachedText = draft
                        doc.markEdited()
                    }
                    if let editor = self.editors[doc.id] {
                        editor.reloadFromDocument()
                    }
                    NotificationCenter.default.post(name: .swiftNoteDocumentContentLoaded,
                                                    object: self, userInfo: ["id": id])
                    self.postDocumentsChanged()
                    self.postActiveChanged()
                }
            }
        }
    }

    // MARK: - 通知

    func postDocumentsChanged() {
        NotificationCenter.default.post(name: .swiftNoteDocumentsChanged, object: self)
    }

    func postActiveChanged() {
        NotificationCenter.default.post(name: .swiftNoteActiveDocumentChanged, object: self)
    }

    // MARK: - 弹窗

    func presentSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentFailures(_ failures: [(URL, Error)]) {
        // 异常 #5：批量失败汇总为一次提示
        let list = failures.map { "· \($0.0.lastPathComponent)：\($0.1.localizedDescription)" }
            .joined(separator: "\n")
        presentSimpleAlert(title: "有 \(failures.count) 个文件打开失败", message: list)
    }
}

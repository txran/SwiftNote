import AppKit
import SwiftNoteKit

// MARK: - 外部修改监视（FR-11）

/// 双保险：
/// 1. `FileWatcher`（vnode）—— 编辑未激活时也能感知；
/// 2. 窗口激活时批量校验 mtime —— 防监视源失效（inode 被换、路径重建、网络卷）漏报。
///
/// 冲突话术按「本地是否干净」分支：Clean 时重载无风险，默认「重新加载」；
/// Dirty 时重载会丢修改，默认「保留本地版本」（不丢数据的动作必须是默认按钮）。
extension EditorStore {

    // MARK: - 挂载 / 摘除

    func startWatchingAll() {
        for doc in documents where doc.fileURL != nil {
            startWatching(doc)
        }
    }

    func startWatching(_ doc: EditorDocument) {
        guard let url = doc.fileURL else { return }
        watchers.removeValue(forKey: doc.id)?.stop()

        let watcher = FileWatcher(url: url)
        watcher.onChange = { [weak self, weak doc] kind in
            guard let self, let doc else { return }
            self.handleExternalChange(kind, for: doc)
        }
        watcher.start()
        watchers[doc.id] = watcher
    }

    func stopWatching(_ doc: EditorDocument) {
        watchers.removeValue(forKey: doc.id)?.stop()
    }

    /// 重挂监视：原子写换了 inode，旧 fd 已失效。保留 watcher 对象，只换 fd
    func restartWatching(_ doc: EditorDocument) {
        guard let url = doc.fileURL else {
            stopWatching(doc)
            return
        }
        if let existing = watchers[doc.id] {
            existing.retarget(to: url)
        } else {
            startWatching(doc)
        }
    }

    // MARK: - 事件入口

    /// vnode 事件：不直接信事件类型，一律用当前磁盘状态复核
    /// （原子写的 delete+create 与真删除在 vnode 层看起来很像，只有复核能分开）
    func handleExternalChange(_ kind: FileChangeKind, for doc: EditorDocument) {
        guard documents.contains(where: { $0.id == doc.id }) else { return }
        AppLogger.info("vnode \(kind) → \(doc.fileURL?.lastPathComponent ?? "")")
        evaluate(doc)
    }

    /// 窗口激活时兜底校验（全量）
    ///
    /// 先扫完再弹窗：扫描过程里不能有模态打断，否则 `runModal` 嵌套事件循环会让
    /// 后续标签的探测结果与 UI 状态脱节。无变化时不做任何 UI 动作。
    func verifyExternalChanges() {
        guard !isPresentingConflict else { return }
        var conflicts: [EditorDocument] = []
        var missing = false
        for doc in documents where doc.fileURL != nil {
            switch doc.refreshExternalState() {
            case .none:
                continue
            case .deleted:
                missing = true
            case .modified:
                conflicts.append(doc)
            }
        }
        if missing {
            postDocumentsChanged()
            postActiveChanged()
            scheduleSessionSave()
        }
        for doc in conflicts {
            promptConflict(doc)
        }
    }

    /// vnode 事件到结论的复核
    private func evaluate(_ doc: EditorDocument) {
        guard doc.fileURL != nil else { return }
        switch doc.refreshExternalState() {
        case .none:
            return
        case .deleted:
            handleFileMissing(doc)
        case .modified:
            promptConflict(doc)
        }
    }

    // MARK: - 文件被外部删除 / 移动（异常 #3）

    private func handleFileMissing(_ doc: EditorDocument) {
        AppLogger.warn("文件已被外部删除：\(doc.fileURL?.path ?? "")")
        // 标签标题由 displayName 自动追加「（已删除）」，并保留内存内容允许另存为找回
        postDocumentsChanged()
        postActiveChanged()
        scheduleSessionSave()
    }

    // MARK: - 外部修改冲突

    private func promptConflict(_ doc: EditorDocument) {
        guard !isPresentingConflict else { return }

        // 无头验证：SWIFTNOTE_CONFLICT_ACTION 强制选分支（仅在截图模式下生效），
        // 否则模态框会阻塞主线程，截图与自动化都拿不到结果
        let env = ProcessInfo.processInfo.environment
        if env["SWIFTNOTE_SNAPSHOT"] != nil, let action = env["SWIFTNOTE_CONFLICT_ACTION"] {
            AppLogger.info("外部修改：\(doc.displayName)（自动选择 \(action)）")
            if action == "reload" { reload(document: doc) } else { keepLocal(doc) }
            return
        }

        isPresentingConflict = true
        defer { isPresentingConflict = false }

        let dirty = doc.isDirty
        let alert = NSAlert()
        alert.alertStyle = dirty ? .warning : .informational
        alert.messageText = "「\(doc.displayName)」已在外部被修改"
        alert.informativeText = dirty
            ? "本地有未保存的修改。重新加载会丢弃这些修改，且无法通过撤销恢复。"
            : "磁盘内容与编辑器中的内容不一致，请选择保留哪一份。"

        // Dirty：安全的「保留本地」必须是默认按钮
        alert.addButton(withTitle: dirty ? "保留本地版本" : "重新加载")
        alert.addButton(withTitle: dirty ? "重新加载（丢弃本地修改）" : "保留本地版本")

        let modal = alert.runModal()
        if dirty {
            if modal == .alertSecondButtonReturn {
                reload(document: doc)
            } else {
                keepLocal(doc)
            }
        } else {
            if modal == .alertFirstButtonReturn {
                reload(document: doc)
            } else {
                keepLocal(doc)
            }
        }
    }

    /// 采用磁盘版本
    func reload(document doc: EditorDocument) {
        guard let url = doc.fileURL else { return }
        do {
            let loaded = try FileLoader.load(url: url)
            doc.cachedText = loaded.text
            doc.encoding = loaded.encoding
            doc.lineEnding = loaded.lineEnding
            doc.hasBOM = loaded.hasBOM
            doc.rebaseOnDisk()
            if !doc.isReadOnly { doc.markSaved(text: loaded.text) }
            drafts.remove(for: doc.id)
            if let editor = editors[doc.id] {
                editor.reloadFromDocument()
            }
            restartWatching(doc)
            postDocumentsChanged()
            postActiveChanged()
            scheduleSessionSave()
            AppLogger.info("已重新加载磁盘版本：\(url.lastPathComponent)")
        } catch {
            presentSimpleAlert(title: "重新加载失败",
                              message: "\(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    /// 保留本地版本：只更新基线（否则每次激活都重复提示），并留一个冲突标记提醒「保存会覆盖磁盘」
    func keepLocal(_ doc: EditorDocument) {
        guard let url = doc.fileURL else { return }
        doc.fileMeta = FileMeta.read(from: url)
        doc.isFileMissing = false
        doc.hasExternalConflict = true
        postDocumentsChanged()
        postActiveChanged()
    }
}

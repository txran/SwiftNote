import Foundation

/// 磁盘上发生了什么（监视层只描述事件，不判定冲突——判定见 FileChangeDetector）
public enum FileChangeKind: Equatable, Sendable {
    case modified
    case deleted
}

/// 单文件 vnode 监视（设计说明书 5.8 第一重保险）
///
/// 两个必须处理的现实约束：
/// 1. **inode 会变**：原子写（`FileManager.replaceItemAt`）是「临时文件 rename 覆盖」，
///    被监视的 inode 随之消失，`DispatchSource` 会收到 `.delete`/`.rename` 后静默失效。
///    所以遇到这两类事件不能直接当删除，而要判断路径是否还在：在 → 内容变更 + 重新挂载；
///    不在 → 真删除。
/// 2. **一次写多个事件**：`.write` / `.extend` / `.attrib` 常连着来，必须 debounce 合并，
///    否则一次保存会触发多轮 UI 提示。
///
/// 线程约定：事件汇总在私有串行队列，最终回调到**主线程**。
public final class FileWatcher {
    public private(set) var url: URL
    /// 变更回调（主线程）
    public var onChange: ((FileChangeKind) -> Void)?
    /// 连续写入的合并窗口
    public var debounceInterval: TimeInterval = 0.15

    private let queue = DispatchQueue(label: "cn.swiftnote.file-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pendingWork: DispatchWorkItem?
    private var pendingKind: FileChangeKind?
    private var running = false

    public init(url: URL) {
        self.url = url
    }

    deinit {
        // 不走 queue.sync：deinit 可能发生在任意线程，取消即可，fd 由 cancelHandler 关闭
        pendingWork?.cancel()
        source?.cancel()
    }

    // MARK: - 生命周期

    public func start() {
        queue.sync { startLocked() }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    /// 另存为后换路径监视（旧 URL 的监视随即停止）
    public func retarget(to newURL: URL) {
        queue.sync {
            stopLocked()
            url = newURL
            startLocked()
        }
    }

    public var isRunning: Bool {
        queue.sync { running }
    }

    // MARK: - 内部（均在 queue 上执行）

    private func startLocked() {
        guard !running else { return }
        guard install() else {
            AppLogger.warn("无法监视文件（open O_EVTONLY 失败）：\(url.path)")
            return
        }
        running = true
    }

    private func stopLocked() {
        running = false
        pendingWork?.cancel()
        pendingWork = nil
        pendingKind = nil
        discardSource()
    }

    private func discardSource() {
        source?.cancel()   // cancelHandler 负责 close(fd)
        source = nil
    }

    /// 打开文件描述符并挂载事件源
    private func install() -> Bool {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            self.handle(events: src.data)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        return true
    }

    private func handle(events: DispatchSource.FileSystemEvent) {
        let removed = events.contains(.delete) || events.contains(.rename)
        if removed {
            if FileManager.default.fileExists(atPath: url.path) {
                // 原子写换掉了 inode：重新挂载，并当作一次内容变更上报
                discardSource()
                _ = install()
                schedule(.modified)
            } else {
                schedule(.deleted)
                // inode 已消失，继续监视没有意义；文件若重新出现由「窗口激活时 mtime 兜底」接管
                discardSource()
                running = false
            }
            return
        }
        if events.contains(.write) || events.contains(.extend) || events.contains(.attrib) {
            schedule(.modified)
        }
    }

    private func schedule(_ kind: FileChangeKind) {
        // deleted 优先级更高：合并窗口内先 modified 后 deleted 时不能丢删除
        if kind == .deleted {
            pendingKind = .deleted
        } else if pendingKind == nil {
            pendingKind = .modified
        }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let kind = self.pendingKind else { return }
            self.pendingKind = nil
            self.pendingWork = nil
            DispatchQueue.main.async {
                self.onChange?(kind)
            }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

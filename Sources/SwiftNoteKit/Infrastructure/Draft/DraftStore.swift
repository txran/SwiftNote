import Foundation

/// 草稿快照存储（设计说明书 5.9 / D-6）：会话恢复与崩溃恢复共用
public final class DraftStore {
    private let directory: URL

    public init(directory: URL = AppPaths.draftsDirectory) {
        self.directory = directory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func draftURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).txt")
    }

    public func hasDraft(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: draftURL(for: id).path)
    }

    public func save(_ text: String, for id: UUID) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            try AtomicSaver.write(data, to: draftURL(for: id))
        } catch {
            AppLogger.error("草稿写入失败 \(id.uuidString)：\(error.localizedDescription)")
        }
    }

    public func load(for id: UUID) -> String? {
        guard let data = try? Data(contentsOf: draftURL(for: id)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: draftURL(for: id))
    }

    /// 清理不属于任何存活文档的草稿（启动恢复消费完后调用）
    public func removeOrphans(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "txt" {
            guard let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            if !ids.contains(uuid) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

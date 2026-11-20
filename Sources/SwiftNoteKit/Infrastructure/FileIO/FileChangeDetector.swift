import Foundation

/// 磁盘变更的语义结论（FR-11）
public enum ExternalFileChange: Equatable, Sendable {
    case none
    /// 内容已变（mtime 或 size 不同）
    case modified
    /// 路径上已经没有文件
    case deleted

    public var hasChange: Bool { self != .none }
}

/// 基线比对：拿「上次记录的 FileMeta」与「当前磁盘 FileMeta」比，得出该不该提示
///
/// 单独抽出来是为了可测——外部修改误报/漏报的代价都很高（误报会打断打字，
/// 漏报会让用户保存时静默覆盖别人的改动），所以判定规则要能脱离 UI 与文件系统单测。
public enum FileChangeDetector {
    /// - Parameters:
    ///   - cached: 上次记录到基线（打开、保存、重新加载时写入）
    ///   - current: 当前磁盘状态；`nil` 表示路径上已无文件
    public static func compare(cached: FileMeta?, current: FileMeta?) -> ExternalFileChange {
        guard let current else { return .deleted }
        guard let cached else {
            // 没有基线（理论上不该出现）：不提示，由调用方补基线
            return .none
        }
        if current.modificationDate != cached.modificationDate || current.size != cached.size {
            return .modified
        }
        return .none
    }

    /// 读取路径当前状态并比对
    public static func inspect(url: URL, cached: FileMeta?) -> ExternalFileChange {
        let exists = FileManager.default.fileExists(atPath: url.path)
        return compare(cached: cached, current: exists ? FileMeta.read(from: url) : nil)
    }
}

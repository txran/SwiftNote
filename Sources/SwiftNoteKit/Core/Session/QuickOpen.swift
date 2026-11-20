import Foundation

/// 快速打开面板的一条候选（FR-11「最近文件」）
///
/// 纯数据 + 纯排序，界面只负责画。之所以把匹配放在 Core：
/// 「输入 `cbm json` 该不该命中 `~/cfg/cbm-types.json`」是产品规则，
/// 用单测钉住比在界面里手试可靠得多。
public struct QuickOpenItem: Equatable {
    public let path: String
    /// 文件名（含扩展名）
    public let name: String
    /// 所在目录，家目录前缀缩成 `~`
    public let directory: String
    /// 该文件当前已在标签页里打开
    public let isOpen: Bool
    /// 磁盘上还存在（不存在的只能展示，不能打开）
    public let exists: Bool

    public init(path: String, isOpen: Bool, exists: Bool, homeDirectory: String = NSHomeDirectory()) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        if !homeDirectory.isEmpty, dir == homeDirectory {
            self.directory = "~"
        } else if !homeDirectory.isEmpty, dir.hasPrefix(homeDirectory + "/") {
            self.directory = "~" + dir.dropFirst(homeDirectory.count)
        } else {
            self.directory = dir
        }
        self.isOpen = isOpen
        self.exists = exists
    }
}

/// 最近文件列表的组装与过滤
public enum QuickOpen {
    /// 候选上限：最近文件本身就限 20 条，界面上再放宽一点容纳已打开文档
    public static let maxItems = 40

    /// 合并「已打开文档」与「最近文件」，同一路径只留一条（已打开的优先，带 isOpen 标记）
    ///
    /// - Parameters:
    ///   - openPaths: 当前标签页里的文件路径，按标签顺序
    ///   - recentPaths: 最近文件，最新的在前
    ///   - existing: 判断磁盘是否存在（注入进来才能单测）
    public static func items(openPaths: [String],
                             recentPaths: [String],
                             existing: (String) -> Bool,
                             homeDirectory: String = NSHomeDirectory()) -> [QuickOpenItem] {
        let openSet = Set(openPaths)
        var seen = Set<String>()
        var ordered: [String] = []
        for path in openPaths + recentPaths where !path.isEmpty && !seen.contains(path) {
            seen.insert(path)
            ordered.append(path)
        }
        return ordered.prefix(maxItems).map {
            QuickOpenItem(path: $0, isOpen: openSet.contains($0),
                          exists: existing($0), homeDirectory: homeDirectory)
        }
    }

    /// 按查询词过滤并排序
    ///
    /// 规则：空格分词、全部命中才算匹配（顺序无关），匹配范围是完整路径；
    /// 排序按「命中位置的质量」分档，同档保持传入顺序（已打开 / 最近在前）：
    /// 0 文件名完全相同 → 1 文件名前缀 → 2 文件名包含全部词 → 3 仅目录命中。
    public static func filter(_ items: [QuickOpenItem], query: String) -> [QuickOpenItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)

        var scored: [(score: Int, index: Int, item: QuickOpenItem)] = []
        for (index, item) in items.enumerated() {
            let haystack = item.path.lowercased()
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            let name = item.name.lowercased()
            let score: Int
            if name == trimmed {
                score = 0
            } else if let first = tokens.first, name.hasPrefix(first) {
                score = 1
            } else if tokens.allSatisfy({ name.contains($0) }) {
                score = 2
            } else {
                score = 3
            }
            scored.append((score, index, item))
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
        }
        return scored.map(\.item)
    }
}

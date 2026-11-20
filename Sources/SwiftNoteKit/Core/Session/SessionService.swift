import Foundation

/// 会话快照模型（设计说明书 4.2，字段一律 camelCase）
public struct TabSnapshot: Codable {
    public var id: String
    public var filePath: String?
    public var hasDraft: Bool
    public var scrollPosition: Double
    public var cursorOffset: Int
    public var encoding: String
    public var syntaxMode: String
    public var readOnly: Bool
    /// 可选：旧版本 session.json 没有这个字段，解码不能因此失败
    public var lineEnding: String?
    /// 可选：同上，缺省按「无 BOM」处理
    public var hasBOM: Bool?

    public init(id: String, filePath: String?, hasDraft: Bool, scrollPosition: Double,
                cursorOffset: Int, encoding: String, syntaxMode: String, readOnly: Bool,
                lineEnding: String? = nil, hasBOM: Bool? = nil) {
        self.id = id
        self.filePath = filePath
        self.hasDraft = hasDraft
        self.scrollPosition = scrollPosition
        self.cursorOffset = cursorOffset
        self.encoding = encoding
        self.syntaxMode = syntaxMode
        self.readOnly = readOnly
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }
}

public struct SessionSnapshot: Codable {
    public var version: Int
    public var savedAt: String
    public var activeTabIndex: Int
    public var tabs: [TabSnapshot]
    public var recentFiles: [String]

    public init(version: Int = 1, savedAt: String = ISO8601DateFormatter().string(from: Date()),
                activeTabIndex: Int, tabs: [TabSnapshot], recentFiles: [String]) {
        self.version = version
        self.savedAt = savedAt
        self.activeTabIndex = activeTabIndex
        self.tabs = tabs
        self.recentFiles = recentFiles
    }
}

/// 会话读写（session.json）
public final class SessionService {
    private let fileURL: URL
    public static let maxRecentFiles = 20

    public init(fileURL: URL = AppPaths.sessionFile) {
        self.fileURL = fileURL
    }

    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(SessionSnapshot.self, from: data)
        } catch {
            AppLogger.warn("session.json 无法解析，忽略会话恢复：\(error.localizedDescription)")
            return nil
        }
    }

    public func save(_ snapshot: SessionSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try AtomicSaver.write(data, to: fileURL)
        } catch {
            AppLogger.error("会话保存失败：\(error.localizedDescription)")
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

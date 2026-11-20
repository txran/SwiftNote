import Foundation

/// 语法模式（FR-04 / FR-06 / FR-07）
public enum SyntaxMode: String, CaseIterable, Sendable {
    case json
    case xml
    case properties
    case plain

    public var displayName: String {
        switch self {
        case .json: return "JSON"
        case .xml: return "XML"
        case .properties: return "Properties"
        case .plain: return "纯文本"
        }
    }

    /// 扩展名优先，内容嗅探兜底（设计说明书 6.1）
    ///
    /// `.txt` / `.log` / `.md` 这类**通用文本**显式按纯文本处理，不参与内容嗅探：
    /// 一堆日志里有 `=` 就会被判成 Properties、开头是 `{` 又变成 JSON，
    /// 于是状态栏挂着 JSON 校验错误、打字还带语法色——而用户只是打开了一个 txt。
    /// 真要看高亮/校验，状态栏点一下切过去即可。
    public static func detect(fileURL: URL?, contentPrefix: String) -> SyntaxMode {
        switch fileURL?.pathExtension.lowercased() {
        case "json": return .json
        case "xml", "plist", "xsd", "xsl": return .xml
        case "properties", "props", "conf", "ini", "cfg": return .properties
        case "txt", "text", "log", "md", "markdown", "csv", "tsv": return .plain
        default: break
        }
        let head = contentPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("<?xml") || head.hasPrefix("<") { return .xml }
        if head.hasPrefix("{") || head.hasPrefix("[") { return .json }
        if head.contains("=") && !head.contains("{") { return .properties }
        return .plain
    }
}

/// 文件编码（MVP：UTF-8 / GBK(GB18030)）
public enum FileEncoding: String, CaseIterable, Sendable {
    case utf8 = "UTF-8"
    case gbk = "GBK"

    public var displayName: String { rawValue }
}

/// 文档状态机状态（PRD 9.1）
public enum DocumentState: String, Sendable {
    case clean
    case dirty
    case readOnly
}

public enum ReadOnlyReason: String, Sendable {
    case largeFile
    case permission

    public var displayText: String {
        switch self {
        case .largeFile: return "大文件只读"
        case .permission: return "无写入权限"
        }
    }
}

public struct FileMeta: Equatable, Sendable {
    public var size: Int64
    public var modificationDate: Date

    public init(size: Int64, modificationDate: Date) {
        self.size = size
        self.modificationDate = modificationDate
    }

    public static func read(from url: URL) -> FileMeta? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs[.modificationDate] as? Date) ?? .distantPast
        return FileMeta(size: size, modificationDate: date)
    }
}

/// 状态机事件
public enum DocumentEvent {
    case edited
    case saved
    case demotedToReadOnly(ReadOnlyReason)
    case savedAsNewFile
}

import Foundation

/// 换行符（EOL）风格。
///
/// 内存里**一律用 `\n`**，磁盘上按文档记录的风格写回。
/// 理由：CBM 那批配置文件多半来自 Windows 工具链（CRLF），而 TextKit 的
/// 行号、搜索、diff 全部按 `\n` 计算；让 `\r` 混在 textStorage 里，
/// 行号栏会多算一列、正则 `$` 也不匹配。统一归一化后只在一处（读盘/写盘）
/// 做转换，其余逻辑不必关心换行符长什么样。
public enum LineEnding: String, CaseIterable, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var displayName: String { rawValue }

    /// 设置菜单里的说明文字
    public var platformName: String {
        switch self {
        case .lf: return "Unix / macOS"
        case .crlf: return "Windows"
        case .cr: return "Classic Mac"
        }
    }

    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// 探测：数一遍三种换行各有多少，取最多的那种。
    ///
    /// 混合换行的文件（Windows 工具 + 手改）取多数派，不报错——
    /// 编辑器能做的只有「保存时统一成一种」，问用户反而更烦。
    public static func detect(in text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var cr = 0
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let scalar = scalars[i]
            if scalar == "\r" {
                let next = scalars.index(after: i)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    crlf += 1
                    i = scalars.index(after: next)
                    continue
                }
                cr += 1
            } else if scalar == "\n" {
                lf += 1
            }
            i = scalars.index(after: i)
        }
        if crlf == 0, lf == 0, cr == 0 { return .lf }
        if crlf >= lf, crlf >= cr { return .crlf }
        if cr >= lf { return .cr }
        return .lf
    }

    /// 是否混用了多种换行（状态栏可据此提示）
    public static func isMixed(_ text: String) -> Bool {
        var seen = Set<UInt8>()
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let scalar = scalars[i]
            if scalar == "\r" {
                let next = scalars.index(after: i)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    seen.insert(0)
                    i = scalars.index(after: next)
                    continue
                }
                seen.insert(1)
            } else if scalar == "\n" {
                seen.insert(2)
            }
            if seen.count > 1 { return true }
            i = scalars.index(after: i)
        }
        return false
    }

    /// 把任意换行统一成 `\n`（读盘后、进 TextKit 前调用）
    ///
    /// 注意这里**不能**用 `text.contains("\r")` 做短路：Swift 的 String 按扩展字形簇
    /// 切分，`"\r\n"` 是单个 Character，`contains("\r")` 对纯 CRLF 文本返回 false，
    /// 于是归一化被静默跳过，后面写回时 `\n` 再被替换成 `\r\n`，磁盘上就成了 `\r\r\n`。
    /// （实测：一行 CRLF 存回去变成三个字节的换行，Windows 侧直接读成空行）
    public static func normalized(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// 把 `\n` 换成目标换行（写盘前调用）。
    /// 进来先归一一次：调用方忘了归一也不会把 `\r\n` 变成 `\r\r\n`
    public func applied(to text: String) -> String {
        let lf = LineEnding.normalized(text)
        switch self {
        case .lf:
            return lf
        case .crlf:
            return lf.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr:
            return lf.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}

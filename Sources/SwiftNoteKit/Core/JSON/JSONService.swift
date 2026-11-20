import Foundation

public struct JSONValidationError: Error, CustomStringConvertible {
    public let line: Int      // 1-based，0 表示未知
    public let column: Int    // 1-based
    public let message: String

    public var description: String {
        line > 0 ? "第 \(line) 行 第 \(column) 列：\(message)" : message
    }
}

/// JSON 格式化与校验（FR-05）
public enum JSONService {
    /// 格式化：失败抛出 JSONValidationError（含行列）
    ///
    /// 实现分两步：**先用 JSONSerialization 严格校验**（错误信息里带行列，
    /// 也是唯一能保证语法合法的权威判定），校验通过后**只做词法层面的重排**。
    ///
    /// 不用 `JSONSerialization.data(withJSONObject:)` 直接产出缩进文本，是因为它：
    /// ① 键值分隔输出 `" : "`，与 CBM 配置里惯用的 `": "` 不一致；
    /// ② 数字会长途过一遍 NSNumber（`1.0` 变 `1`、大整数精度有风险）。
    /// 词法重排只搬字符、不碰值，保序、保转义、也保数字原样。
    public static func format(_ text: String, indent: Int = 2) throws -> String {
        if case .failure(let error) = validate(text) { throw error }
        return beautify(text, indent: max(1, indent))
    }

    /// 校验：只解析不重排
    public static func validate(_ text: String) -> Result<Void, JSONValidationError> {
        guard let data = text.data(using: .utf8) else {
            return .failure(JSONValidationError(line: 0, column: 0, message: "文本无法按 UTF-8 编码"))
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .success(())
        } catch {
            return .failure(makeError(error, source: text))
        }
    }

    // MARK: - 内部

    private static func makeError(_ error: Error, source: String) -> JSONValidationError {
        let nsError = error as NSError
        let raw = (nsError.userInfo[NSDebugDescriptionErrorKey] as? String)
            ?? nsError.localizedDescription
        if let (line, col) = parseLineColumn(raw) {
            return JSONValidationError(line: line, column: col, message: "JSON 语法错误")
        }
        // 兜底：只报消息，不猜行列
        return JSONValidationError(line: 0, column: 0, message: raw)
    }

    private static func parseLineColumn(_ message: String) -> (Int, Int)? {
        // Foundation 常见形态："… around line 3, column 5."
        let pattern = #"line\s+(\d+),\s*column\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(location: 0, length: (message as NSString).length)
        guard let m = regex.firstMatch(in: message, options: [], range: range), m.numberOfRanges >= 3,
              let l = Int((message as NSString).substring(with: m.range(at: 1))),
              let c = Int((message as NSString).substring(with: m.range(at: 2))) else { return nil }
        return (l, c)
    }

    /// 词法重排：只按 `{}[] , :` 与字符串状态插入缩进/换行，不解析值
    private static func beautify(_ text: String, indent: Int) -> String {
        let chars = Array(text)
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false

        func pad(_ level: Int) -> String {
            String(repeating: " ", count: max(0, level) * indent)
        }
        func nextSignificant(after index: Int) -> Character? {
            var i = index + 1
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                    continue
                }
                return c
            }
            return nil
        }

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString {
                out.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            switch ch {
            case "\"":
                inString = true
                out.append(ch)
            case "{", "[":
                let closer: Character = ch == "{" ? "}" : "]"
                if nextSignificant(after: i) == closer {
                    out.append(ch)
                    out.append(closer)
                    // 空容器：吃掉中间的空白与闭合符
                    i += 1
                    while i < chars.count, chars[i] != closer { i += 1 }
                } else {
                    out.append(ch)
                    depth += 1
                    out.append("\n" + pad(depth))
                }
            case "}", "]":
                depth = max(0, depth - 1)
                out.append("\n" + pad(depth))
                out.append(ch)
            case ",":
                out.append(ch)
                out.append("\n" + pad(depth))
            case ":":
                out.append(": ")
            case " ", "\t", "\n", "\r":
                break
            default:
                out.append(ch)
            }
            i += 1
        }
        return out
    }
}

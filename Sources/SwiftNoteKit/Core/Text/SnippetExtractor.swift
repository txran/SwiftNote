import Foundation

/// 在混杂文本里定位一段报文
///
/// 场景：`2026-05-28 15:15:58.5 [INFO] resp={"code":0} cost=12ms` 里拖选整行，
/// 报文前后都带噪声。右键「转换为 JSON」只该换报文那一段，前缀与尾巴原样留着。
///
/// 只在用户点了菜单项之后才调用（O(n) 扫一遍选区），不参与菜单开合——
/// 菜单那侧只取 64 字符判型，见 `EditorContainerView.selectedSnippetKind`。
public enum SnippetExtractor {

    public struct Match {
        public let kind: SnippetFormatter.Kind
        /// 报文起点在原文中的偏移（UTF-16 单元，可直接叠加到 NSRange.location）
        public let location: Int
        /// 报文长度（UTF-16 单元）
        public let length: Int
        public let snippet: String
    }

    /// 找第一段结构完整的报文；找不到返回 nil
    public static func locate(in text: String) -> Match? {
        var cursor = text.startIndex
        while let start = firstCandidate(from: cursor, in: text) {
            let isXML = text[start] == "<"
            let end = isXML ? xmlEnd(from: start, in: text) : jsonEnd(from: start, in: text)
            if let end {
                let snippet = String(text[start..<end])
                // 括号配平还不够：日志里的 `[INFO]` / `[WARN]` 配平得很漂亮但解析不了。
                // 用真正的解析器验一次，不合格就把起点往后挪、接着找。
                if parses(snippet, isXML: isXML) {
                    return Match(kind: isXML ? .xml : .json,
                                 location: text.utf16.distance(from: text.startIndex, to: start),
                                 length: snippet.utf16.count,
                                 snippet: snippet)
                }
            }
            cursor = text.index(after: start)
        }
        return nil
    }

    /// 轻校验：只为了排除「形状像报文、其实不是」的候选
    private static func parses(_ snippet: String, isXML: Bool) -> Bool {
        if isXML {
            return (try? XMLService.format(snippet)) != nil
        }
        if case .success = JSONService.validate(snippet) { return true }
        return false
    }

    // MARK: - 起点与配对

    private static func firstCandidate(from index: String.Index, in text: String) -> String.Index? {
        var i = index
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" || ch == "[" || ch == "<" { return i }
            i = text.index(after: i)
        }
        return nil
    }

    /// JSON：括号配对，跳过字符串与转义（`"}"` 里的花括号不算数）
    private static func jsonEnd(from start: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return text.index(after: i) }
                    if depth < 0 { return nil }
                default: break
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// XML：标签栈配对；注释 / CDATA / 处理指令整体跳过
    private static func xmlEnd(from start: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var i = start
        while i < text.endIndex {
            guard text[i] == "<" else {
                i = text.index(after: i)
                continue
            }
            if hasPrefix(text, at: i, "<![CDATA[") {
                guard let end = text.range(of: "]]>", range: i..<text.endIndex)?.upperBound else { return nil }
                i = end
                continue
            }
            if hasPrefix(text, at: i, "<!--") {
                guard let end = text.range(of: "-->", range: i..<text.endIndex)?.upperBound else { return nil }
                i = end
                continue
            }
            if hasPrefix(text, at: i, "<?") {
                guard let end = text.range(of: "?>", range: i..<text.endIndex)?.upperBound else { return nil }
                i = end
                continue
            }
            if hasPrefix(text, at: i, "<!") {
                guard let end = text.range(of: ">", range: i..<text.endIndex)?.upperBound else { return nil }
                i = end
                continue
            }
            guard let gt = tagEnd(from: i, in: text) else { return nil }
            let raw = text[text.index(after: i)..<gt]
            i = text.index(after: gt)
            if raw.hasPrefix("/") {
                depth -= 1
                if depth == 0 { return i }
                if depth < 0 { return nil }
            } else if raw.hasSuffix("/") {
                if depth == 0 { return i }   // 自闭合的根元素
            } else {
                depth += 1
            }
        }
        return nil
    }

    private static func hasPrefix(_ text: String, at index: String.Index, _ prefix: String) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    /// 找 `>`，跳过属性值引号里的内容（`<a b="1>2">` 不能截断）
    private static func tagEnd(from start: String.Index, in text: String) -> String.Index? {
        var i = text.index(after: start)
        var quote: Character?
        while i < text.endIndex {
            let ch = text[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }
}

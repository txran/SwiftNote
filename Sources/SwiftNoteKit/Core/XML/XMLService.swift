import Foundation

public struct XMLFormatError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// XML 报文层级化（FR-05 扩展）。
///
/// 只做「词法层面的重排」：不解析 DOM、不改属性顺序、不动实体与 CDATA，
/// 因此对 CBM 报文这类结构规整、但字段名大小写混排的配置最安全。
///
/// 三条输出约定：
/// 1. 元素内容只有文本 → 保持一行（`<MsgId>12</MsgId>`），不拆成三行；
/// 2. 注释 / CDATA / 处理指令各占一行，跟随当前层级缩进；
/// 3. 标签内部的换行与多余空格压成单空格（`<a\n  x="1">` → `<a x="1">`）。
public enum XMLService {

    /// 层级化。失败抛出 `XMLFormatError`（标签不闭合 / 不匹配 / 选中不完整）
    public static func format(_ text: String, indent: Int = 2) throws -> String {
        let width = max(0, indent)
        let tokens = try tokenize(text)
        guard tokens.contains(where: { token in
            switch token {
            case .open, .close, .selfClosing: return true
            default: return false
            }
        }) else {
            throw XMLFormatError("选中的内容里没有 XML 标签")
        }

        var lines: [String] = []
        var stack: [String] = []
        var depth = 0

        func pad(_ level: Int) -> String {
            String(repeating: " ", count: max(0, level) * width)
        }
        func token(at index: Int) -> Token? {
            tokens.indices.contains(index) ? tokens[index] : nil
        }
        func closeName(_ candidate: Token?) -> String? {
            if case .close(let name)? = candidate { return name }
            return nil
        }
        func textBody(_ candidate: Token?) -> String? {
            if case .text(let value)? = candidate { return value }
            return nil
        }

        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case .declaration(let raw), .doctype(let raw), .comment(let raw), .cdata(let raw):
                lines.append(pad(depth) + raw)
                index += 1

            case .selfClosing(_, let raw):
                lines.append(pad(depth) + collapseTag(raw))
                index += 1

            case .open(let name, let raw):
                let tag = collapseTag(raw)
                // <a></a>
                if closeName(token(at: index + 1)) == name {
                    lines.append(pad(depth) + tag + "</\(name)>")
                    index += 2
                    continue
                }
                // <a>text</a>：内容只有文本时保持一行
                if let body = textBody(token(at: index + 1)),
                   !collapseText(body).isEmpty,
                   closeName(token(at: index + 2)) == name {
                    lines.append(pad(depth) + tag + collapseText(body) + "</\(name)>")
                    index += 3
                    continue
                }
                lines.append(pad(depth) + tag)
                stack.append(name)
                depth += 1
                index += 1

            case .close(let name):
                guard let openName = stack.popLast() else {
                    throw XMLFormatError("多余的结束标签 </\(name)>，选中内容不是完整的 XML 片段")
                }
                guard openName == name else {
                    throw XMLFormatError("标签不匹配：<\(openName)> 对应的是 </\(openName)>，实际遇到 </\(name)>")
                }
                depth = max(0, depth - 1)
                lines.append(pad(depth) + "</\(name)>")
                index += 1

            case .text(let value):
                let trimmed = collapseText(value)
                if !trimmed.isEmpty {
                    lines.append(pad(depth) + trimmed)
                }
                index += 1
            }
        }

        if let unclosed = stack.last {
            throw XMLFormatError("元素 <\(unclosed)> 没有闭合，选中内容不是完整的 XML 片段")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 词法

    private enum Token {
        case declaration(String)
        case doctype(String)
        case comment(String)
        case cdata(String)
        case open(name: String, raw: String)
        case close(name: String)
        case selfClosing(name: String, raw: String)
        case text(String)
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var pendingText = ""
        var index = text.startIndex

        func flushText() {
            if !pendingText.isEmpty {
                tokens.append(.text(pendingText))
                pendingText = ""
            }
        }

        while index < text.endIndex {
            guard text[index] == "<" else {
                pendingText.append(text[index])
                index = text.index(after: index)
                continue
            }
            let rest = text[index...]
            if rest.hasPrefix("<!--") {
                guard let range = text.range(of: "-->", range: index..<text.endIndex) else {
                    throw XMLFormatError("注释没有闭合（缺少 `-->`）")
                }
                flushText()
                tokens.append(.comment(String(text[index..<range.upperBound])))
                index = range.upperBound
            } else if rest.hasPrefix("<![CDATA[") {
                guard let range = text.range(of: "]]>", range: index..<text.endIndex) else {
                    throw XMLFormatError("CDATA 没有闭合（缺少 `]]>`）")
                }
                flushText()
                tokens.append(.cdata(String(text[index..<range.upperBound])))
                index = range.upperBound
            } else if rest.hasPrefix("<?") {
                guard let range = text.range(of: "?>", range: index..<text.endIndex) else {
                    throw XMLFormatError("处理指令没有闭合（缺少 `?>`）")
                }
                flushText()
                tokens.append(.declaration(String(text[index..<range.upperBound])))
                index = range.upperBound
            } else if rest.hasPrefix("<!") {
                guard let end = tagEnd(in: text, from: index) else {
                    throw XMLFormatError("DOCTYPE 没有闭合（缺少 `>`）")
                }
                flushText()
                tokens.append(.doctype(String(text[index..<end])))
                index = end
            } else {
                guard let end = tagEnd(in: text, from: index) else {
                    throw XMLFormatError("标签没有闭合（缺少 `>`）")
                }
                let raw = String(text[index..<end])
                flushText()
                if raw.hasPrefix("</") {
                    let name = tagName(raw)
                    guard !name.isEmpty else { throw XMLFormatError("无法识别的结束标签：\(raw)") }
                    tokens.append(.close(name: name))
                } else {
                    let name = tagName(raw)
                    guard !name.isEmpty else { throw XMLFormatError("无法识别的标签：\(raw)") }
                    // 自闭合判定用 collapse 之后的形态：`<a x="1" />` 与 `<a x="1"/>` 都算
                    if collapseTag(raw).hasSuffix("/>") || raw.hasSuffix("/>") {
                        tokens.append(.selfClosing(name: name, raw: raw))
                    } else {
                        tokens.append(.open(name: name, raw: raw))
                    }
                }
                index = end
            }
        }
        flushText()
        return tokens
    }

    /// 找标签结尾的 `>`，跳过引号内的内容（`attr="a>b"` 合法）
    private static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        var index = text.index(after: start)
        var quote: Character?
        while index < text.endIndex {
            let ch = text[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return text.index(after: index)
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `<ns:a x="1">` → `ns:a`
    private static func tagName(_ raw: String) -> String {
        var body = raw.dropFirst()                      // 去掉 '<'
        if body.hasPrefix("/") { body = body.dropFirst() }
        var name = ""
        for ch in body {
            if ch.isWhitespace || ch == "/" || ch == ">" { break }
            name.append(ch)
        }
        return name
    }

    /// 标签内的换行/多余空格压成单空格；`>` 与 `/` 前的空格丢掉
    private static func collapseTag(_ raw: String) -> String {
        var out = ""
        var quote: Character?
        var pendingSpace = false
        for ch in raw {
            if let q = quote {
                out.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                if pendingSpace { out.append(" ") ; pendingSpace = false }
                quote = ch
                out.append(ch)
                continue
            }
            if ch.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                if ch != ">" && ch != "/" { out.append(" ") }
                pendingSpace = false
            }
            out.append(ch)
        }
        return out
    }

    /// 文本节点：连续空白压成一个空格，首尾去空白
    private static func collapseText(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}

/// 选中片段格式化的统一入口（右键菜单用）
public enum SnippetFormatter {
    public enum Kind: String, Sendable {
        case json
        case xml

        public var displayName: String { rawValue.uppercased() }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// 按首字符判断：`{` / `[` → JSON，`<` → XML。判不出来返回 nil
    public static func detect(_ text: String) -> Kind? {
        let head = text.drop { $0.isWhitespace || $0.isNewline }
        guard let first = head.first else { return nil }
        if first == "{" || first == "[" { return .json }
        if first == "<" { return .xml }
        return nil
    }

    public static func format(_ text: String, kind: Kind? = nil, indent: Int = 2) throws -> String {
        guard let kind = kind ?? detect(text) else {
            throw Failure("选中的内容看起来不是 JSON 或 XML（应以 `{`、`[` 或 `<` 开头）")
        }
        switch kind {
        case .json:
            do {
                return try JSONService.format(text, indent: indent)
            } catch let error as JSONValidationError {
                throw Failure("JSON 校验失败 · \(error.description)")
            }
        case .xml:
            do {
                return try XMLService.format(text, indent: indent)
            } catch let error as XMLFormatError {
                throw Failure(error.message)
            }
        }
    }
}

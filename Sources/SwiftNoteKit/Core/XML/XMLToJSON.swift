import Foundation

/// XML 报文 → JSON（CBM 配置对照用）
///
/// 映射规则（刻意保持"可预测"而不是"聪明"）：
/// - 根元素也是一层键：`<Msg><A>1</A></Msg>` → `{"Msg": {"A": "1"}}`，根名不丢
/// - 同名兄弟元素 → 数组；只有一个时 → 单个对象（不强制套数组）
/// - 属性加 `@` 前缀，与子元素区分：`<A id="1"/>` → `{"A": {"@id": "1"}}`
/// - 元素既有属性又有文本时，文本放 `#text`
/// - 空元素 → 空字符串
/// - **文本一律输出字符串**：XML 没有类型信息，`<msisdn>13800138000</msisdn>`
///   若按数字输出，前导零会丢、ID 会变成数值，下游解析反而容易错。
///   需要数字的字段请在下游自行转换。
/// - 注释、处理指令、DOCTYPE 丢弃；CDATA 当普通文本
public enum XMLToJSON {

    public struct Failure: Error, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// 属性键前缀与混合文本键名：写死在这里，UI 提示文案引用同一常量，避免两处不一致
    public static let attributePrefix = "@"
    public static let textKey = "#text"

    public static func convert(_ xml: String, indent: Int = 2) throws -> String {
        let roots = try parse(xml)
        guard !roots.isEmpty else {
            throw Failure("没有找到 XML 元素（选中内容里没有 `<标签>`）")
        }
        return render(rootObject(from: roots), indent: max(1, indent))
    }

    // MARK: - 值模型

    /// 用 `[(String, JSONValue)]` 而不是字典：报文对照要求键顺序与原文一致
    private indirect enum JSONValue {
        case string(String)
        case array([JSONValue])
        case object([(String, JSONValue)])
    }

    private final class Node {
        let name: String
        var attributes: [(String, String)] = []
        var children: [Node] = []
        var textChunks: [String] = []

        init(name: String) { self.name = name }

        /// 连续空白压成单空格：报文里的缩进换行是排版噪声，不是内容
        var normalizedText: String? {
            let joined = textChunks.joined()
            let parts = joined.split(whereSeparator: { $0.isWhitespace })
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " ")
        }
    }

    /// 多个根（选中一段没包根节点的报文片段）时，按名依次放进同一个对象
    private static func rootObject(from roots: [Node]) -> JSONValue {
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for root in roots {
            if groups[root.name] == nil {
                order.append(root.name)
                groups[root.name] = []
            }
            groups[root.name]?.append(value(of: root))
        }
        let pairs: [(String, JSONValue)] = order.map { name in
            let list = groups[name] ?? []
            return (name, list.count == 1 ? list[0] : .array(list))
        }
        return .object(pairs)
    }

    private static func value(of node: Node) -> JSONValue {
        let text = node.normalizedText
        if node.attributes.isEmpty && node.children.isEmpty {
            return .string(text ?? "")
        }

        var pairs: [(String, JSONValue)] = []
        for attribute in node.attributes {
            pairs.append((attributePrefix + attribute.0, .string(attribute.1)))
        }

        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for child in node.children {
            if groups[child.name] == nil {
                order.append(child.name)
                groups[child.name] = []
            }
            groups[child.name]?.append(value(of: child))
        }
        for name in order {
            let list = groups[name] ?? []
            pairs.append((name, list.count == 1 ? list[0] : .array(list)))
        }

        if let text { pairs.append((textKey, .string(text))) }
        return .object(pairs)
    }

    // MARK: - 解析

    private static func parse(_ xml: String) throws -> [Node] {
        let chars = Array(xml)
        var i = 0
        var stack: [Node] = []
        var roots: [Node] = []

        func line(of index: Int) -> Int {
            var count = 1
            for k in 0..<min(index, chars.count) where chars[k] == "\n" { count += 1 }
            return count
        }

        func attach(_ node: Node) {
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }

        func appendText(_ text: String) {
            guard !text.isEmpty, let top = stack.last else { return }
            top.textChunks.append(text)
        }

        while i < chars.count {
            guard chars[i] == "<" else {
                var j = i
                while j < chars.count, chars[j] != "<" { j += 1 }
                appendText(String(chars[i..<j]))
                i = j
                continue
            }

            if matches(chars, at: i, "<![CDATA[") {
                guard let end = find(chars, "]]>", from: i + 9) else {
                    throw Failure("第 \(line(of: i)) 行：CDATA 没有结束（缺少 `]]>`）")
                }
                appendText(String(chars[(i + 9)..<end]))
                i = end + 3
                continue
            }
            if matches(chars, at: i, "<!--") {
                guard let end = find(chars, "-->", from: i + 4) else {
                    throw Failure("第 \(line(of: i)) 行：注释没有结束（缺少 `-->`）")
                }
                i = end + 3
                continue
            }
            if matches(chars, at: i, "<?") {
                guard let end = find(chars, "?>", from: i + 2) else {
                    throw Failure("第 \(line(of: i)) 行：处理指令没有结束（缺少 `?>`）")
                }
                i = end + 2
                continue
            }
            if matches(chars, at: i, "<!") {
                // DOCTYPE 声明：跳到 `>`（内部子集 `[...]` 极少见，不做特殊处理）
                guard let end = find(chars, ">", from: i + 2) else {
                    throw Failure("第 \(line(of: i)) 行：声明没有结束（缺少 `>`）")
                }
                i = end + 1
                continue
            }

            guard let end = tagEnd(chars, from: i) else {
                throw Failure("第 \(line(of: i)) 行：标签没有结束（缺少 `>`）")
            }
            let raw = String(chars[(i + 1)..<end])
            i = end + 1

            if raw.hasPrefix("/") {
                let name = raw.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let top = stack.popLast() else {
                    throw Failure("第 \(line(of: end)) 行：多余的结束标签 `</\(name)>`")
                }
                guard top.name == name else {
                    throw Failure("第 \(line(of: end)) 行：结束标签 `</\(name)>` 与开始标签 `<\(top.name)>` 不匹配")
                }
                attach(top)
                continue
            }

            let selfClosing = raw.hasSuffix("/")
            let body = selfClosing ? String(raw.dropLast()) : raw
            let node = try makeNode(body, line: line(of: i - 1))
            if selfClosing {
                attach(node)
            } else {
                stack.append(node)
            }
        }

        if let unclosed = stack.last {
            throw Failure("标签 `<\(unclosed.name)>` 没有闭合")
        }
        return roots
    }

    private static func makeNode(_ body: String, line: Int) throws -> Node {
        let chars = Array(body)
        var i = 0
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        var nameChars: [Character] = []
        while i < chars.count, !chars[i].isWhitespace, chars[i] != "/" {
            nameChars.append(chars[i])
            i += 1
        }
        let name = String(nameChars)
        guard !name.isEmpty else {
            throw Failure("第 \(line) 行：标签名为空")
        }
        let node = Node(name: name)

        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] != "/" else { break }

            var attributeChars: [Character] = []
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace, chars[i] != "/" {
                attributeChars.append(chars[i])
                i += 1
            }
            let attributeName = String(attributeChars)
            while i < chars.count, chars[i].isWhitespace { i += 1 }

            var attributeValue = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    var valueChars: [Character] = []
                    while i < chars.count, chars[i] != quote {
                        valueChars.append(chars[i])
                        i += 1
                    }
                    i += 1
                    attributeValue = decodeEntities(String(valueChars))
                } else {
                    // 无引号属性值：宽容处理，读到空白或标签结尾
                    var valueChars: [Character] = []
                    while i < chars.count, !chars[i].isWhitespace, chars[i] != "/" {
                        valueChars.append(chars[i])
                        i += 1
                    }
                    attributeValue = decodeEntities(String(valueChars))
                }
            }

            if attributeName.isEmpty {
                // 防止畸形标签死循环
                i += 1
                continue
            }
            node.attributes.append((attributeName, attributeValue))
        }
        return node
    }

    private static func matches(_ chars: [Character], at index: Int, _ prefix: String) -> Bool {
        var i = index
        for ch in prefix {
            guard i < chars.count, chars[i] == ch else { return false }
            i += 1
        }
        return true
    }

    /// 找 `>`，跳过引号内的内容（`<a b="x>y">` 不能在这里截断）
    private static func tagEnd(_ chars: [Character], from start: Int) -> Int? {
        var i = start + 1
        var quote: Character?
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func find(_ chars: [Character], _ needle: String, from start: Int) -> Int? {
        let target = Array(needle)
        guard !target.isEmpty, start <= chars.count - target.count else { return nil }
        var i = start
        while i <= chars.count - target.count {
            if chars[i] == target[0] {
                var matched = true
                for k in 1..<target.count where chars[i + k] != target[k] {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "&" else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            guard let semicolon = text[i...].firstIndex(of: ";"),
                  text.distance(from: i, to: semicolon) <= 10 else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let body = String(text[text.index(after: i)..<semicolon])
            if let scalar = decodeEntity(body) {
                out.append(scalar)
                i = text.index(after: semicolon)
            } else {
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }

    private static func decodeEntity(_ body: String) -> Character? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init).map(Character.init)
            }
            return nil
        }
    }

    // MARK: - 输出

    private static func render(_ value: JSONValue, indent: Int, level: Int = 0) -> String {
        let pad = String(repeating: " ", count: level * indent)
        let innerPad = String(repeating: " ", count: (level + 1) * indent)
        switch value {
        case .string(let text):
            return quote(text)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items
                .map { innerPad + render($0, indent: indent, level: level + 1) }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs
                .map { innerPad + quote($0.0) + ": " + render($0.1, indent: indent, level: level + 1) }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

import Foundation

public struct XMLLexer: Lexer {
    public init() {}

    public func tokenize(line: NSString, offset: Int, context: inout LexContext) -> [Token] {
        let n = line.length
        guard n > 0 else { return [] }
        let buf = line.snCharacterBuffer()
        var tokens: [Token] = []
        var i = 0

        // 跨行 XML 注释
        if context.inBlockComment {
            if let end = find(buf, marker: [CharCode.minus, CharCode.minus, CharCode.gt], from: 0) {
                tokens.append(Token(range: NSRange(location: offset, length: end), type: .comment))
                context.inBlockComment = false
                i = end
            } else {
                tokens.append(Token(range: NSRange(location: offset, length: n), type: .comment))
                return tokens
            }
        }

        // 跨行 CDATA
        if context.inCDATA {
            if let end = find(buf, marker: [CharCode.rbracket, CharCode.rbracket, CharCode.gt], from: 0) {
                tokens.append(Token(range: NSRange(location: offset, length: end), type: .cdata))
                context.inCDATA = false
                i = end
            } else {
                tokens.append(Token(range: NSRange(location: offset, length: n), type: .cdata))
                return tokens
            }
        }

        // 跨行标签（上一行的 <tag 未闭合）
        if context.insideXMLTag {
            let next = parseTagBody(buf, from: i, n: n, offset: offset, tokens: &tokens, context: &context)
            if context.insideXMLTag { return tokens }
            i = next
        }

        while i < n {
            let c = buf[i]
            if c == CharCode.lt {
                // <!-- 注释
                if i + 3 < n, buf[i + 1] == CharCode.bang, buf[i + 2] == CharCode.minus, buf[i + 3] == CharCode.minus {
                    if let end = find(buf, marker: [CharCode.minus, CharCode.minus, CharCode.gt], from: i + 4) {
                        tokens.append(Token(range: NSRange(location: offset + i, length: end - i), type: .comment))
                        i = end
                    } else {
                        tokens.append(Token(range: NSRange(location: offset + i, length: n - i), type: .comment))
                        context.inBlockComment = true
                        return tokens
                    }
                    continue
                }
                // <![CDATA[
                if i + 8 < n, matchesCDATAStart(buf, at: i) {
                    if let end = find(buf, marker: [CharCode.rbracket, CharCode.rbracket, CharCode.gt], from: i + 9) {
                        tokens.append(Token(range: NSRange(location: offset + i, length: end - i), type: .cdata))
                        i = end
                    } else {
                        tokens.append(Token(range: NSRange(location: offset + i, length: n - i), type: .cdata))
                        context.inCDATA = true
                        return tokens
                    }
                    continue
                }
                // <?xml … ?> / <tag …> / </tag>
                let next = parseTagBody(buf, from: i + 1, n: n, offset: offset, tokens: &tokens, context: &context)
                if context.insideXMLTag { return tokens }
                i = next
                continue
            }
            // 文本内容：不着色，只推进到下一个 <
            while i < n && buf[i] != CharCode.lt { i += 1 }
        }
        return tokens
    }

    /// 解析标签体（从标签名开始，不含 '<'）；返回下一个待扫描位置
    private func parseTagBody(_ buf: [unichar], from start: Int, n: Int, offset: Int,
                              tokens: inout [Token], context: inout LexContext) -> Int {
        var i = start
        // 结束标签的 '/'
        if i < n && buf[i] == CharCode.slash { i += 1 }
        // 处理指令的 '?'
        if i < n && buf[i] == CharCode.question { i += 1 }

        let nameStart = i
        while i < n && CharCode.isNameBody(buf[i]) { i += 1 }
        if i > nameStart {
            tokens.append(Token(range: NSRange(location: offset + nameStart, length: i - nameStart), type: .tagName))
        }

        while i < n {
            let c = buf[i]
            if CharCode.isWhitespace(c) { i += 1; continue }
            if c == CharCode.gt {
                context.insideXMLTag = false
                return i + 1
            }
            if c == CharCode.slash || c == CharCode.question {
                context.insideXMLTag = false
                if c == CharCode.slash, i + 1 < n, buf[i + 1] == CharCode.gt { return i + 2 }
                if c == CharCode.question, i + 1 < n, buf[i + 1] == CharCode.gt { return i + 2 }
                return i + 1
            }

            // 属性名
            let attrStart = i
            while i < n && CharCode.isNameBody(buf[i]) { i += 1 }
            if i == attrStart { i += 1; continue }
            tokens.append(Token(range: NSRange(location: offset + attrStart, length: i - attrStart), type: .attrName))

            while i < n && CharCode.isWhitespace(buf[i]) { i += 1 }
            guard i < n, buf[i] == CharCode.equals else { continue }
            i += 1
            while i < n && CharCode.isWhitespace(buf[i]) { i += 1 }
            guard i < n else { context.insideXMLTag = true; return n }

            // 属性值（含引号）
            let quote = buf[i]
            if quote == CharCode.dquote || quote == 39 {
                let valueStart = i
                var j = i + 1
                var closed = false
                while j < n {
                    if buf[j] == quote { j += 1; closed = true; break }
                    j += 1
                }
                tokens.append(Token(range: NSRange(location: offset + valueStart, length: j - valueStart),
                                    type: .attrValue))
                if !closed {
                    context.insideXMLTag = true
                    return n
                }
                i = j
            } else {
                let valueStart = i
                while i < n && !CharCode.isWhitespace(buf[i]) && buf[i] != CharCode.gt { i += 1 }
                tokens.append(Token(range: NSRange(location: offset + valueStart, length: i - valueStart),
                                    type: .attrValue))
            }
        }
        // 行尾仍在标签内
        context.insideXMLTag = true
        return n
    }

    private func matchesCDATAStart(_ buf: [unichar], at i: Int) -> Bool {
        let marker: [unichar] = [CharCode.lbracket, 67, 68, 65, 84, 65, CharCode.lbracket] // [CDATA[
        guard i + 1 + marker.count <= buf.count else { return false }
        for (k, m) in marker.enumerated() where buf[i + 1 + k] != m { return false }
        return true
    }

    /// 查找标记序列，返回标记结束后的位置
    private func find(_ buf: [unichar], marker: [unichar], from start: Int) -> Int? {
        guard !marker.isEmpty else { return nil }
        var i = start
        while i + marker.count <= buf.count {
            var matched = true
            for k in 0..<marker.count where buf[i + k] != marker[k] {
                matched = false
                break
            }
            if matched { return i + marker.count }
            i += 1
        }
        return nil
    }
}

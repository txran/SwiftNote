import Foundation

public struct PropertiesLexer: Lexer {
    public init() {}

    public func tokenize(line: NSString, offset: Int, context: inout LexContext) -> [Token] {
        let n = line.length
        guard n > 0 else { return [] }
        let buf = line.snCharacterBuffer()
        var tokens: [Token] = []
        var i = 0
        while i < n && CharCode.isWhitespace(buf[i]) { i += 1 }
        guard i < n else { return [] }

        // 注释行（# 或 !）
        if buf[i] == CharCode.hash || buf[i] == CharCode.bang {
            tokens.append(Token(range: NSRange(location: offset + i, length: n - i), type: .comment))
            return tokens
        }

        // 段头 [section]
        if buf[i] == CharCode.lbracket {
            var j = i + 1
            while j < n && buf[j] != CharCode.rbracket && buf[j] != CharCode.lf { j += 1 }
            tokens.append(Token(range: NSRange(location: offset + i, length: min(j + 1, n) - i), type: .section))
            return tokens
        }

        // 续行块：整行视为 value 延续
        if context.continuationDepth > 0 {
            let continues = endsWithContinuation(buf, n: n)
            context.continuationDepth = continues ? context.continuationDepth + 1 : 0
            tokens.append(Token(range: NSRange(location: offset + i, length: n - i), type: .propValue))
            return tokens
        }

        // key [=|:] value
        let keyStart = i
        while i < n {
            let c = buf[i]
            if c == CharCode.equals || c == CharCode.colon || CharCode.isWhitespace(c) { break }
            i += 1
        }
        let keyEnd = i
        if keyEnd > keyStart {
            tokens.append(Token(range: NSRange(location: offset + keyStart, length: keyEnd - keyStart), type: .propKey))
        }

        var sepFound = false
        while i < n {
            let c = buf[i]
            if c == CharCode.equals || c == CharCode.colon {
                sepFound = true
                i += 1
                break
            }
            if CharCode.isWhitespace(c) { i += 1; continue }
            break
        }
        while i < n && CharCode.isWhitespace(buf[i]) { i += 1 }

        if sepFound && i < n {
            let valueStart = i
            tokens.append(Token(range: NSRange(location: offset + valueStart, length: n - valueStart), type: .propValue))
        }

        if endsWithContinuation(buf, n: n) {
            context.continuationDepth += 1
        } else {
            context.continuationDepth = 0
        }
        return tokens
    }

    /// 行尾是否为未转义的反斜杠续行
    private func endsWithContinuation(_ buf: [unichar], n: Int) -> Bool {
        var end = n - 1
        while end >= 0 && (buf[end] == CharCode.lf || buf[end] == CharCode.cr) { end -= 1 }
        guard end >= 0, buf[end] == CharCode.backslash else { return false }
        // 统计连续反斜杠数量，偶数个表示已转义
        var count = 0
        var k = end
        while k >= 0 && buf[k] == CharCode.backslash { count += 1; k -= 1 }
        return count % 2 == 1
    }
}

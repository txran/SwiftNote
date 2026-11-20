import Foundation

public struct JSONLexer: Lexer {
    public init() {}

    public func tokenize(line: NSString, offset: Int, context: inout LexContext) -> [Token] {
        let n = line.length
        guard n > 0 else { return [] }
        let buf = line.snCharacterBuffer()
        var tokens: [Token] = []
        var i = 0

        // 续接上一行的块注释
        if context.inBlockComment {
            var j = 0
            var closed = false
            while j + 1 < n {
                if buf[j] == CharCode.star && buf[j + 1] == CharCode.slash {
                    j += 2
                    closed = true
                    break
                }
                j += 1
            }
            if !closed { j = n }
            tokens.append(Token(range: NSRange(location: offset, length: j), type: .comment))
            context.inBlockComment = !closed
            i = j
            if closed { context.inBlockComment = false }
        }

        // 续接上一行的字符串（宽松场景：JSON 字符串跨行）
        if context.inJSONString && i < n {
            var j = i
            var closed = false
            while j < n {
                if buf[j] == CharCode.backslash { j += 2; continue }
                if buf[j] == CharCode.dquote { j += 1; closed = true; break }
                j += 1
            }
            let end = min(j, n)
            if end > i {
                tokens.append(Token(range: NSRange(location: offset + i, length: end - i), type: .stringValue))
            }
            context.inJSONString = !closed
            i = end
        }

        while i < n {
            let c = buf[i]
            if CharCode.isWhitespace(c) { i += 1; continue }

            // 行注释 / 块注释（配置文件常见宽松写法）
            if c == CharCode.slash && i + 1 < n && buf[i + 1] == CharCode.slash {
                tokens.append(Token(range: NSRange(location: offset + i, length: n - i), type: .comment))
                return tokens
            }
            if c == CharCode.slash && i + 1 < n && buf[i + 1] == CharCode.star {
                var j = i + 2
                var closed = false
                while j + 1 < n {
                    if buf[j] == CharCode.star && buf[j + 1] == CharCode.slash {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed { j = n }
                tokens.append(Token(range: NSRange(location: offset + i, length: j - i), type: .comment))
                context.inBlockComment = !closed
                i = j
                continue
            }

            // 字符串（判断是否为 key）
            if c == CharCode.dquote {
                var j = i + 1
                var closed = false
                while j < n {
                    if buf[j] == CharCode.backslash { j += 2; continue }
                    if buf[j] == CharCode.dquote { j += 1; closed = true; break }
                    j += 1
                }
                let end = min(j, n)
                var isKey = false
                if closed {
                    var k = end
                    while k < n && CharCode.isWhitespace(buf[k]) { k += 1 }
                    isKey = k < n && buf[k] == CharCode.colon
                }
                tokens.append(Token(range: NSRange(location: offset + i, length: end - i),
                                    type: isKey ? .key : .stringValue))
                if !closed { context.inJSONString = true }
                i = end
                continue
            }

            // 数字
            if CharCode.isDigit(c) || (c == CharCode.minus && i + 1 < n && CharCode.isDigit(buf[i + 1])) {
                var j = i + 1
                while j < n {
                    let d = buf[j]
                    if CharCode.isDigit(d) || d == CharCode.dot || d == 46
                        || d == 101 || d == 69 || d == CharCode.plus || d == CharCode.minus {
                        j += 1
                    } else {
                        break
                    }
                }
                tokens.append(Token(range: NSRange(location: offset + i, length: j - i), type: .number))
                i = j
                continue
            }

            // true / false / null
            if CharCode.isNameStart(c) {
                var j = i
                while j < n && CharCode.isNameBody(buf[j]) { j += 1 }
                let word = line.substring(with: NSRange(location: i, length: j - i))
                let type: TokenType?
                switch word {
                case "true", "false": type = .boolean
                case "null": type = .nullLiteral
                default: type = nil
                }
                if let t = type {
                    tokens.append(Token(range: NSRange(location: offset + i, length: j - i), type: t))
                }
                i = j
                continue
            }

            tokens.append(Token(range: NSRange(location: offset + i, length: 1), type: .punctuation))
            i += 1
        }
        return tokens
    }
}

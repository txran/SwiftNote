import Foundation

/// 着色分类（设计说明书 5.2.1）
public enum TokenType: String, Sendable {
    // JSON
    case key
    case stringValue
    case number
    case boolean
    case nullLiteral
    case punctuation
    // XML
    case tagName
    case attrName
    case attrValue
    case comment
    case cdata
    // Properties
    case propKey
    case propValue
    case section
}

public struct Token: Equatable, Sendable {
    public let range: NSRange
    public let type: TokenType
    public init(range: NSRange, type: TokenType) {
        self.range = range
        self.type = type
    }
}

/// 跨行词法上下文（行边界携带）
public struct LexContext: Equatable, Sendable {
    public var insideXMLTag = false
    public var inBlockComment = false
    public var inCDATA = false
    public var continuationDepth = 0
    public var inJSONString = false

    public init() {}
}

/// 单行词法器；range 为绝对 UTF-16 偏移
public protocol Lexer {
    func tokenize(line: NSString, offset: Int, context: inout LexContext) -> [Token]
}

enum CharCode {
    static let tab: unichar = 9
    static let lf: unichar = 10
    static let cr: unichar = 13
    static let space: unichar = 32
    static let bang: unichar = 33
    static let dquote: unichar = 34
    static let hash: unichar = 35
    static let star: unichar = 42
    static let plus: unichar = 43
    static let comma: unichar = 44
    static let minus: unichar = 45
    static let dot: unichar = 46
    static let slash: unichar = 47
    static let colon: unichar = 58
    static let equals: unichar = 61
    static let gt: unichar = 62
    static let question: unichar = 63
    static let lbracket: unichar = 91
    static let backslash: unichar = 92
    static let rbracket: unichar = 93
    static let lt: unichar = 60

    static func isWhitespace(_ c: unichar) -> Bool {
        c == space || c == tab || c == cr || c == lf
    }

    static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    static func isNameStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == colon
    }

    static func isNameBody(_ c: unichar) -> Bool {
        isNameStart(c) || isDigit(c) || c == minus || c == dot
    }
}

extension NSString {
    /// 逐行词法的字符缓冲（避免逐字符调用 character(at:) 的桥接开销）
    func snCharacterBuffer() -> [unichar] {
        var buffer = [unichar](repeating: 0, count: length)
        if length > 0 {
            getCharacters(&buffer, range: NSRange(location: 0, length: length))
        }
        return buffer
    }
}

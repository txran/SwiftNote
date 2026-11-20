import Foundation

/// 搜索查询条件（设计说明书 5.4）
public struct SearchQuery: Equatable {
    public var term: String
    public var isRegex: Bool
    public var isCaseSensitive: Bool
    public var isWholeWord: Bool

    public init(term: String = "",
                isRegex: Bool = false,
                isCaseSensitive: Bool = false,
                isWholeWord: Bool = false) {
        self.term = term
        self.isRegex = isRegex
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
    }

    public var isEmpty: Bool { term.isEmpty }

    /// 走字面量快路径的条件：非正则且不要求整词（整词需要边界断言，交给正则）
    fileprivate var useLiteralFastPath: Bool { !isRegex && !isWholeWord }

    /// 正则编译一次复用；正则语法错误抛出 `SearchError.invalidRegex`
    public func compiledRegex() throws -> NSRegularExpression? {
        guard !term.isEmpty else { return nil }
        var pattern = isRegex ? term : NSRegularExpression.escapedPattern(for: term)
        if isWholeWord { pattern = "\\b(?:\(pattern))\\b" }
        var options: NSRegularExpression.Options = []
        if !isCaseSensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw SearchError.invalidRegex(error.localizedDescription)
        }
    }
}

public enum SearchError: LocalizedError {
    case invalidRegex(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRegex(let message): return "正则表达式无效：\(message)"
        }
    }
}

/// 搜索/替换算法（FR-08）。全部为纯函数，不含 UI，可在 CoreTests 中覆盖。
public enum SearchEngine {

    /// 全量命中（升序、互不重叠）。`range` 用于视口/子区间扫描。
    public static func findAll(in text: NSString, query: SearchQuery, in range: NSRange? = nil) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let scope = range ?? NSRange(location: 0, length: text.length)
        guard scope.location >= 0, scope.length > 0, NSMaxRange(scope) <= text.length else { return [] }

        if query.useLiteralFastPath {
            return findLiteral(in: text, term: query.term,
                               caseSensitive: query.isCaseSensitive, in: scope)
        }
        guard let compiled = try? query.compiledRegex() else { return [] }
        var results: [NSRange] = []
        compiled.enumerateMatches(in: text as String, options: [], range: scope) { match, _, _ in
            guard let match else { return }
            results.append(match.range)
        }
        return results
    }

    public static func findAll(in text: String, query: SearchQuery, in range: NSRange? = nil) -> [NSRange] {
        findAll(in: text as NSString, query: query, in: range)
    }

    /// 后台全量扫描（D-4）：调用方负责丢弃过期结果（generation token）
    public static func findAllAsync(in text: String, query: SearchQuery) async -> [NSRange] {
        await Task.detached(priority: .userInitiated) { @Sendable in
            findAll(in: text as NSString, query: query)
        }.value
    }

    /// 全部替换：返回新文本与替换数（调用方负责单 undo 组落盘）
    ///
    /// - 字面量模式：替换串按字面量插入，`$1` 不做展开；
    /// - 正则模式：保留 `$1` / `\n` 等模板语义。
    public static func replaceAll(in text: String,
                                  query: SearchQuery,
                                  with replacement: String) throws -> (String, Int) {
        guard !query.isEmpty else { return (text, 0) }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        if query.useLiteralFastPath || !query.isRegex {
            let ranges = findAll(in: ns, query: query, in: whole)
            guard !ranges.isEmpty else { return (text, 0) }
            let buffer = NSMutableString(string: text)
            for range in ranges.reversed() {
                buffer.replaceCharacters(in: range, with: replacement)
            }
            return (buffer as String, ranges.count)
        }

        guard let compiled = try query.compiledRegex() else { return (text, 0) }
        let count = compiled.numberOfMatches(in: text, options: [], range: whole)
        guard count > 0 else { return (text, 0) }
        let replaced = compiled.stringByReplacingMatches(in: text, options: [], range: whole,
                                                        withTemplate: replacement)
        return (replaced, count)
    }

    // MARK: - 导航

    /// 命中的游标推进：`forward == true` 取光标之后（含光标处）第一条，到尾部回卷
    public static func nextIndex(in matches: [NSRange], from offset: Int, forward: Bool,
                                 wrapping: Bool = true) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            if let index = matches.firstIndex(where: { NSMaxRange($0) > offset }) { return index }
            return wrapping ? 0 : nil
        } else {
            if let index = matches.lastIndex(where: { $0.location < offset }) { return index }
            return wrapping ? matches.count - 1 : nil
        }
    }

    /// 命中在全文中的相对位置（0~1），供滚动条刻度使用
    public static func relativePositions(of matches: [NSRange], textLength: Int) -> [Double] {
        guard textLength > 0 else { return [] }
        return matches.map { min(1, max(0, Double($0.location) / Double(textLength))) }
    }

    // MARK: - 内部

    private static func findLiteral(in text: NSString, term: String,
                                    caseSensitive: Bool, in scope: NSRange) -> [NSRange] {
        guard !term.isEmpty else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var results: [NSRange] = []
        var cursor = scope.location
        let end = NSMaxRange(scope)
        while cursor < end {
            let searchRange = NSRange(location: cursor, length: end - cursor)
            let found = text.range(of: term, options: options, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            results.append(found)
            cursor = NSMaxRange(found)
        }
        return results
    }
}

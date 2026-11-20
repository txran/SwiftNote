import Foundation

/// 行级词法缓存 + 不动点增量重词法（设计说明书 5.2.2）
public final class SyntaxEngine {
    public struct LineLex: Equatable {
        public var tokens: [Token]
        public var contextAfter: LexContext
    }

    public private(set) var mode: SyntaxMode
    private var lexer: Lexer?
    private var text: NSString = ""
    private var lineStarts: [Int] = [0]
    private var lineEnds: [Int] = [0]
    private var caches: [LineLex] = [LineLex(tokens: [], contextAfter: LexContext())]

    public init(mode: SyntaxMode) {
        self.mode = mode
        switch mode {
        case .json: lexer = JSONLexer()
        case .xml: lexer = XMLLexer()
        case .properties: lexer = PropertiesLexer()
        case .plain: lexer = nil
        }
    }

    public var isHighlightEnabled: Bool { lexer != nil }
    public var lineCount: Int { lineStarts.count }
    /// 当前缓存对应的文本长度（用于判断引擎是否与编辑器同步）
    public var textLength: Int { text.length }

    public func setMode(_ mode: SyntaxMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        switch mode {
        case .json: lexer = JSONLexer()
        case .xml: lexer = XMLLexer()
        case .properties: lexer = PropertiesLexer()
        case .plain: lexer = nil
        }
        relexAll()
    }

    public func setText(_ text: NSString) {
        self.text = text
        rebuildLineIndex()
        relexAll()
    }

    /// 文本变更后的增量重词法：重建行索引后只重扫变更行起的受影响区间
    /// - Parameter offset: 变更附近的 UTF-16 偏移（用于定位起始行）
    /// - Returns: 受影响的行范围（用于只重着色这一区间）
    @discardableResult
    public func applyChange(text newText: NSString, aroundOffset offset: Int) -> ClosedRange<Int>? {
        let oldLineCount = lineStarts.count
        self.text = newText
        rebuildLineIndex()
        if lineStarts.count != oldLineCount {
            // 行数变化（换行/删除行/粘贴多行）：行缓存整体失效，全量重扫
            caches = Array(repeating: LineLex(tokens: [], contextAfter: LexContext()), count: lineStarts.count)
            return relex(from: 0, forceFull: true)
        }
        let clamped = min(max(0, offset), max(0, newText.length - 1))
        let line = lineIndex(atOffset: clamped)
        return relex(from: line)
    }

    private func rebuildLineIndex() {
        let len = text.length
        guard len > 0 else {
            lineStarts = [0]
            lineEnds = [0]
            return
        }
        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(max(1, len / 40))
        ends.reserveCapacity(max(1, len / 40))
        var idx = 0
        while idx < len {
            var start = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&start, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: idx, length: 0))
            starts.append(start)
            ends.append(lineEnd)
            if lineEnd <= idx { break } // 防御：避免死循环
            idx = lineEnd
        }
        lineStarts = starts
        lineEnds = ends
    }

    private func relexAll() {
        caches = Array(repeating: LineLex(tokens: [], contextAfter: LexContext()), count: lineStarts.count)
        guard lexer != nil else { return }
        // 缓存刚被清空，必须全量重扫（不能按"上下文一致"提前收敛）
        _ = relex(from: 0, forceFull: true)
    }

    /// 从指定行重词法，直到上下文与旧缓存一致（不动点）
    /// 返回受影响行范围
    @discardableResult
    public func relex(from line: Int, forceFull: Bool = false) -> ClosedRange<Int>? {
        guard let lexer, !lineStarts.isEmpty else { return nil }
        let start = max(0, min(line, lineStarts.count - 1))
        var context = start == 0 ? LexContext() : caches[start - 1].contextAfter
        var idx = start
        var last = start
        while idx < lineStarts.count {
            let lineText = text.substring(with: rawRange(idx)) as NSString
            let tokens = lexer.tokenize(line: lineText, offset: lineStarts[idx], context: &context)
            let old = caches[idx]
            caches[idx] = LineLex(tokens: tokens, contextAfter: context)
            last = idx
            // 非首行且上下文回到旧值 → 后续行不受影响，停止
            if !forceFull, idx > start, old.contextAfter == context { break }
            idx += 1
        }
        return start...last
    }

    /// 行索引（含行尾换行）
    public func rawRange(_ line: Int) -> NSRange {
        guard line >= 0 && line < lineStarts.count else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lineStarts[line], length: max(0, lineEnds[line] - lineStarts[line]))
    }

    /// 行索引（不含行尾换行，用于替换/着色）
    public func contentRange(_ line: Int) -> NSRange {
        var r = rawRange(line)
        while r.length > 0 {
            let last = text.character(at: r.location + r.length - 1)
            if last == 10 || last == 13 { r.length -= 1 } else { break }
        }
        return r
    }

    public func tokens(inLine line: Int) -> [Token] {
        guard line >= 0 && line < caches.count else { return [] }
        return caches[line].tokens
    }

    public func contextAfter(line: Int) -> LexContext? {
        guard line >= 0 && line < caches.count else { return nil }
        return caches[line].contextAfter
    }

    public func spans(inLines range: ClosedRange<Int>) -> [Token] {
        var result: [Token] = []
        for line in range where line >= 0 && line < caches.count {
            result.append(contentsOf: caches[line].tokens)
        }
        return result
    }

    /// 字符偏移 → 行号（二分查找）
    public func lineIndex(atOffset offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

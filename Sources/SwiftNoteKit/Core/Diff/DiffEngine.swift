import Foundation

// MARK: - 结果类型

/// 单行差异类型（行级）
public enum DiffLineKind: String, Sendable, Equatable {
    case equal
    case inserted
    case deleted
    case changed

    public var isDifferent: Bool { self != .equal }

    public var displayName: String {
        switch self {
        case .equal: return "相同"
        case .inserted: return "新增"
        case .deleted: return "删除"
        case .changed: return "修改"
        }
    }
}

/// 降级原因（FR-09 GWT：必须明确提示，禁止无限等待）
public enum DiffDegradeReason: String, Sendable, Equatable {
    /// 参与字符级标差的内容量超预算（与文件体积无关：100MB 日志只改 2 行时仍会做行内标差）
    case largeFile
    case timeout
    case tooManyChanges

    public var displayText: String {
        switch self {
        case .largeFile: return "差异内容过多，已跳过字符级标差"
        case .timeout: return "字符级标差超过 3 秒，已跳过"
        case .tooManyChanges: return "差异行数过多，已按整段替换处理"
        }
    }
}

public struct DiffStats: Equatable, Sendable {
    public var inserted: Int
    public var deleted: Int
    public var changed: Int
    /// 差异块（连续的一段非相同区域）数量
    public var hunks: Int

    public init(inserted: Int = 0, deleted: Int = 0, changed: Int = 0, hunks: Int = 0) {
        self.inserted = inserted
        self.deleted = deleted
        self.changed = changed
        self.hunks = hunks
    }

    public var isEmpty: Bool { inserted == 0 && deleted == 0 && changed == 0 }

    public var displayText: String {
        if isEmpty { return "两份内容完全一致" }
        var parts: [String] = []
        if changed > 0 { parts.append("修改 \(changed)") }
        if inserted > 0 { parts.append("新增 \(inserted)") }
        if deleted > 0 { parts.append("删除 \(deleted)") }
        parts.append("\(hunks) 处差异")
        return parts.joined(separator: " · ")
    }
}

/// 一次对比的完整结果：行级类型 + 行内差异 + 双向行映射
public struct DiffResult {
    public let leftLineCount: Int
    public let rightLineCount: Int
    /// 0 基行号 → 差异类型（长度 = 对应侧行数）
    public let leftKinds: [DiffLineKind]
    public let rightKinds: [DiffLineKind]
    /// 0 基行号 → 该行内的差异片段（UTF-16 偏移，相对行首）
    public let leftInline: [Int: [NSRange]]
    public let rightInline: [Int: [NSRange]]
    /// 同步滚动用的行映射（另一侧没有对应行时取最近的有效行）
    public let leftToRightLine: [Int]
    public let rightToLeftLine: [Int]
    public let stats: DiffStats
    public let degradeReasons: [DiffDegradeReason]
    /// 行内阶段是否真正执行（false = 已降级，只有行级底色）
    public let isInlineApplied: Bool

    public var isIdentical: Bool { stats.isEmpty }
    public var isDegraded: Bool { !degradeReasons.isEmpty }
}

// MARK: - 引擎

/// 两阶段 diff（设计说明书 5.5 / ADR D-8）：
/// 1. 行级 Myers（必做，带编辑距离上限）；
/// 2. 行内字符级 LCS（可丢弃：超预算 / 超时即降级）。
///
/// 纯函数、无状态，可在后台线程调用；超时通过「每对行检查一次截止时间」实现，
/// 不依赖线程中断，因此结果确定、可单测。
public enum DiffEngine {
    public struct Options {
        public var inlineCharacterLevel: Bool
        /// 行内阶段可处理的内容量预算（字节，两侧 changed 行合计）。
        /// 与文件体积解耦：100MB 日志只改几行时照样做行内标差。
        public var inlineSizeLimit: Int64
        /// 行内阶段总预算（默认 3s）
        public var timeout: TimeInterval
        /// 行级 Myers 的编辑距离上限，超过则退化为「整段替换」
        public var maxEditDistance: Int

        public init(inlineCharacterLevel: Bool = true,
                    inlineSizeLimit: Int64 = 8 * 1024 * 1024,
                    timeout: TimeInterval = 3.0,
                    maxEditDistance: Int = 600) {
            self.inlineCharacterLevel = inlineCharacterLevel
            self.inlineSizeLimit = inlineSizeLimit
            self.timeout = timeout
            self.maxEditDistance = maxEditDistance
        }
    }

    /// 行内 LCS 的规模上限（单行对）。超过则整段标为差异，避免 DP 表爆炸。
    private static let maxInlineCellCount = 400_000

    public static func compare(left: String, right: String,
                               options: Options = Options()) -> DiffResult {
        let started = Date()
        let leftIndex = LineIndex(text: left)
        let rightIndex = LineIndex(text: right)
        let leftIDs = leftIndex.hashes
        let rightIDs = rightIndex.hashes

        var reasons: [DiffDegradeReason] = []

        // 1. 前后缀剪枝：配置文件通常只有局部改动，剪枝后 Myers 只跑中间段
        var prefix = 0
        while prefix < min(leftIDs.count, rightIDs.count),
              leftIDs[prefix] == rightIDs[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(leftIDs.count, rightIDs.count) - prefix,
              leftIDs[leftIDs.count - 1 - suffix] == rightIDs[rightIDs.count - 1 - suffix] {
            suffix += 1
        }

        let leftMid = leftIDs[prefix..<(leftIDs.count - suffix)]
        let rightMid = rightIDs[prefix..<(rightIDs.count - suffix)]

        var blocks: [Block] = []
        if prefix > 0 {
            blocks.append(Block(kind: .equal, leftStart: 0, leftCount: prefix,
                                rightStart: 0, rightCount: prefix))
        }
        if leftMid.isEmpty && rightMid.isEmpty {
            // 完全相同，无需 Myers
        } else if let ops = myers(leftMid, rightMid, maxD: options.maxEditDistance) {
            blocks.append(contentsOf: groupOps(ops, leftOffset: prefix, rightOffset: prefix))
        } else {
            // 编辑距离超上限：整段视作一次替换，避免 O(ND) 无界增长
            reasons.append(.tooManyChanges)
            blocks.append(Block(kind: .replace, leftStart: prefix, leftCount: leftMid.count,
                                rightStart: prefix, rightCount: rightMid.count))
        }
        if suffix > 0 {
            blocks.append(Block(kind: .equal,
                                leftStart: leftIDs.count - suffix, leftCount: suffix,
                                rightStart: rightIDs.count - suffix, rightCount: suffix))
        }

        // 2. 按块落行级类型 + 双向行映射
        var leftKinds = [DiffLineKind](repeating: .equal, count: leftIDs.count)
        var rightKinds = [DiffLineKind](repeating: .equal, count: rightIDs.count)
        var leftMap = [Int](repeating: -1, count: leftIDs.count)
        var rightMap = [Int](repeating: -1, count: rightIDs.count)
        var stats = DiffStats()
        var pairs: [(Int, Int)] = []

        for block in blocks {
            if block.kind == .equal {
                for offset in 0..<block.leftCount {
                    leftMap[block.leftStart + offset] = block.rightStart + offset
                    rightMap[block.rightStart + offset] = block.leftStart + offset
                }
                continue
            }
            stats.hunks += 1
            let pairCount = min(block.leftCount, block.rightCount)
            for offset in 0..<pairCount {
                leftKinds[block.leftStart + offset] = .changed
                rightKinds[block.rightStart + offset] = .changed
                leftMap[block.leftStart + offset] = block.rightStart + offset
                rightMap[block.rightStart + offset] = block.leftStart + offset
                pairs.append((block.leftStart + offset, block.rightStart + offset))
            }
            stats.changed += pairCount
            if block.leftCount > pairCount {
                for offset in pairCount..<block.leftCount {
                    leftKinds[block.leftStart + offset] = .deleted
                }
                stats.deleted += block.leftCount - pairCount
            }
            if block.rightCount > pairCount {
                for offset in pairCount..<block.rightCount {
                    rightKinds[block.rightStart + offset] = .inserted
                }
                stats.inserted += block.rightCount - pairCount
            }
        }

        fillMissing(&leftMap, upperBound: max(0, rightIDs.count - 1))
        fillMissing(&rightMap, upperBound: max(0, leftIDs.count - 1))

        // 3. 行内字符级（可丢弃阶段）：预算按「参与比较的字符量」算，不按文件大小
        var leftInline: [Int: [NSRange]] = [:]
        var rightInline: [Int: [NSRange]] = [:]
        var inlineApplied = false

        if options.inlineCharacterLevel, !pairs.isEmpty {
            inlineApplied = true
            var budget = options.inlineSizeLimit
            for (leftRow, rightRow) in pairs {
                budget -= Int64(leftIndex.byteLength(leftRow) + rightIndex.byteLength(rightRow))
                if budget < 0 {
                    reasons.append(.largeFile)
                    leftInline.removeAll()
                    rightInline.removeAll()
                    inlineApplied = false
                    break
                }
                if Date().timeIntervalSince(started) > options.timeout {
                    // 超时：丢弃已算出的行内结果，退回纯行级
                    reasons.append(.timeout)
                    leftInline.removeAll()
                    rightInline.removeAll()
                    inlineApplied = false
                    break
                }
                let spans = inlineSpans(leftIndex.line(leftRow), rightIndex.line(rightRow))
                if !spans.left.isEmpty { leftInline[leftRow] = spans.left }
                if !spans.right.isEmpty { rightInline[rightRow] = spans.right }
            }
        }

        return DiffResult(leftLineCount: leftIDs.count,
                          rightLineCount: rightIDs.count,
                          leftKinds: leftKinds,
                          rightKinds: rightKinds,
                          leftInline: leftInline,
                          rightInline: rightInline,
                          leftToRightLine: leftMap,
                          rightToLeftLine: rightMap,
                          stats: stats,
                          degradeReasons: reasons,
                          isInlineApplied: inlineApplied)
    }

    // MARK: - Myers

    private struct Block {
        enum Kind { case equal, replace }
        var kind: Kind
        var leftStart: Int
        var leftCount: Int
        var rightStart: Int
        var rightCount: Int
    }

    private enum EditOp {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// 经典 Myers O(ND)。超过 maxD 返回 nil（调用方降级），避免内存与时间无界增长。
    private static func myers(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>,
                              maxD: Int) -> [EditOp]? {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }

        let aBase = a.startIndex
        let bBase = b.startIndex
        let limit = min(maxD, n + m)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        trace.reserveCapacity(limit + 1)
        var foundD = -1

        for d in 0...limit {
            trace.append(v)
            var k = -d
            while k <= d {
                let index = k + offset
                var x: Int
                if k == -d || (k != d && v[index - 1] < v[index + 1]) {
                    x = v[index + 1]              // 向下走（插入）
                } else {
                    x = v[index - 1] + 1          // 向右走（删除）
                }
                var y = x - k
                while x < n, y < m, a[aBase + x] == b[bBase + y] {
                    x += 1
                    y += 1
                }
                v[index] = x
                if x >= n, y >= m {
                    foundD = d
                    break
                }
                k += 2
            }
            if foundD >= 0 { break }
        }

        guard foundD >= 0 else { return nil }

        var ops: [EditOp] = []
        ops.reserveCapacity(n + m)
        var x = n
        var y = m
        var d = foundD
        while d > 0 {
            let previous = trace[d]
            let k = x - y
            let index = k + offset
            let previousK: Int
            if k == -d || (k != d && previous[index - 1] < previous[index + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = previous[previousK + offset]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                ops.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if x == previousX {
                ops.append(.insert(y - 1))
                y -= 1
            } else {
                ops.append(.delete(x - 1))
                x -= 1
            }
            d -= 1
        }
        while x > 0, y > 0 {
            ops.append(.equal(x - 1, y - 1))
            x -= 1
            y -= 1
        }
        while x > 0 {
            ops.append(.delete(x - 1))
            x -= 1
        }
        while y > 0 {
            ops.append(.insert(y - 1))
            y -= 1
        }
        return Array(ops.reversed())
    }

    /// 把编辑脚本按「连续非相同」合并成替换块（相邻 delete+insert 才能配成 changed）
    private static func groupOps(_ ops: [EditOp], leftOffset: Int, rightOffset: Int) -> [Block] {
        var blocks: [Block] = []
        var leftCursor = leftOffset
        var rightCursor = rightOffset
        var index = 0
        while index < ops.count {
            if isEqual(ops[index]) {
                let leftStart = leftCursor
                let rightStart = rightCursor
                var count = 0
                while index < ops.count, isEqual(ops[index]) {
                    count += 1
                    index += 1
                    leftCursor += 1
                    rightCursor += 1
                }
                blocks.append(Block(kind: .equal,
                                    leftStart: leftStart, leftCount: count,
                                    rightStart: rightStart, rightCount: count))
            } else {
                let leftStart = leftCursor
                let rightStart = rightCursor
                var leftCount = 0
                var rightCount = 0
                while index < ops.count, !isEqual(ops[index]) {
                    if case .delete = ops[index] {
                        leftCount += 1
                        leftCursor += 1
                    } else {
                        rightCount += 1
                        rightCursor += 1
                    }
                    index += 1
                }
                blocks.append(Block(kind: .replace,
                                    leftStart: leftStart, leftCount: leftCount,
                                    rightStart: rightStart, rightCount: rightCount))
            }
        }
        return blocks
    }

    private static func isEqual(_ op: EditOp) -> Bool {
        if case .equal = op { return true }
        return false
    }

    /// 删除行没有对应行时，向前继承最近的有效映射（保证同步滚动单调）
    private static func fillMissing(_ map: inout [Int], upperBound: Int) {
        guard !map.isEmpty else { return }
        var last = 0
        for index in map.indices {
            if map[index] < 0 {
                map[index] = last
            } else {
                map[index] = min(max(0, map[index]), upperBound)
                last = map[index]
            }
        }
    }

    // MARK: - 行内字符级

    /// 先剪公共前后缀，再对中间段做 LCS；超过规模上限则整段标差异。
    /// 偏移全部是 UTF-16，可直接用于 NSRange（含中文场景）。
    static func inlineSpans(_ left: Substring, _ right: Substring) -> (left: [NSRange], right: [NSRange]) {
        let a = Array(left.utf16)
        let b = Array(right.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        if aMid.isEmpty || bMid.isEmpty {
            // 纯插入/删除：整行已由行级底色表达，无需行内片段
            return ([], [])
        }
        if aMid.count * bMid.count > maxInlineCellCount {
            return ([NSRange(location: prefix, length: aMid.count)],
                    [NSRange(location: prefix, length: bMid.count)])
        }

        let n = aMid.count
        let m = bMid.count
        let width = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * (m + 1))
        var i = n - 1
        while i >= 0 {
            var j = m - 1
            while j >= 0 {
                dp[i * width + j] = aMid[i] == bMid[j]
                    ? dp[(i + 1) * width + j + 1] + 1
                    : max(dp[(i + 1) * width + j], dp[i * width + j + 1])
                j -= 1
            }
            i -= 1
        }

        var leftSpans: [NSRange] = []
        var rightSpans: [NSRange] = []
        var leftRun: NSRange?
        var rightRun: NSRange?

        func closeRuns() {
            if let run = leftRun { leftSpans.append(run); leftRun = nil }
            if let run = rightRun { rightSpans.append(run); rightRun = nil }
        }
        func extendLeft(_ index: Int) {
            if let run = leftRun {
                leftRun = NSRange(location: run.location, length: run.length + 1)
            } else {
                leftRun = NSRange(location: index, length: 1)
            }
        }
        func extendRight(_ index: Int) {
            if let run = rightRun {
                rightRun = NSRange(location: run.location, length: run.length + 1)
            } else {
                rightRun = NSRange(location: index, length: 1)
            }
        }

        i = 0
        var j = 0
        while i < n, j < m {
            if aMid[i] == bMid[j] {
                closeRuns()
                i += 1
                j += 1
            } else if dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                extendLeft(i)
                i += 1
            } else {
                extendRight(j)
                j += 1
            }
        }
        while i < n { extendLeft(i); i += 1 }
        while j < m { extendRight(j); j += 1 }
        closeRuns()

        let shiftedLeft = expandToToken(leftSpans.map {
            NSRange(location: $0.location + prefix, length: $0.length)
        }, in: a)
        let shiftedRight = expandToToken(rightSpans.map {
            NSRange(location: $0.location + prefix, length: $0.length)
        }, in: b)
        return (shiftedLeft, shiftedRight)
    }

    /// 把字符级片段扩展到「词」边界并合并相邻片段。
    ///
    /// 纯 LCS 的编辑脚本是「最小」的：`3000` → `5000` 只会标出首位 `3`/`5`，
    /// 因为 `000` 被当成公共子序列。对配置阅读者来说这是噪声级提示，
    /// 因此按 ASCII 词字符向两侧扩到 token 边界（`"timeout": 3000,` 只吃数字本身）。
    private static func expandToToken(_ spans: [NSRange], in units: [UInt16]) -> [NSRange] {
        guard !spans.isEmpty else { return [] }
        var expanded: [NSRange] = []
        for span in spans {
            var start = span.location
            var end = NSMaxRange(span)
            while start > 0, isWordUnit(units[start - 1]) { start -= 1 }
            while end < units.count, isWordUnit(units[end]) { end += 1 }
            expanded.append(NSRange(location: start, length: end - start))
        }
        var merged: [NSRange] = [expanded[0]]
        for span in expanded.dropFirst() {
            let last = merged[merged.count - 1]
            if span.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location,
                                                   length: max(NSMaxRange(last), NSMaxRange(span)) - last.location)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (48...57).contains(unit)          // 0-9
            || (65...90).contains(unit)    // A-Z
            || (97...122).contains(unit)   // a-z
            || unit == 95                  // _
    }
}

// MARK: - 差异块（导航用）

/// 一处差异（连续的一段非相同行）
public struct DiffHunk: Equatable, Sendable {
    /// 左侧起始行（0 基）
    public let leftLine: Int
    /// 右侧起始行（0 基）
    public let rightLine: Int
    /// 块内行数（两侧取大，用于显示「第 n 处」时的上下文判断）
    public let lineCount: Int

    public init(leftLine: Int, rightLine: Int, lineCount: Int) {
        self.leftLine = leftLine
        self.rightLine = rightLine
        self.lineCount = lineCount
    }
}

public extension DiffResult {
    /// 按文档顺序列出差异块。
    ///
    /// 只扫 `leftKinds` 会漏掉「左侧纯插入」的块（那种块在左侧全是 equal），
    /// 所以把右侧的差异行按 `rightToLeftLine` 投影回左侧，再合并成连续区间。
    var hunks: [DiffHunk] {
        if isIdentical { return [] }
        let n = leftKinds.count
        guard n > 0 else {
            // 左侧空文件、右侧有内容：整篇就是一处在「第 0 行」的插入
            return rightKinds.contains(where: { $0.isDifferent })
                ? [DiffHunk(leftLine: 0, rightLine: 0, lineCount: max(1, rightKinds.count))]
                : []
        }

        var flagged = [Bool](repeating: false, count: n)
        for (i, kind) in leftKinds.enumerated() where kind.isDifferent {
            flagged[i] = true
        }
        for (r, kind) in rightKinds.enumerated() where kind.isDifferent {
            let base = r < rightToLeftLine.count ? rightToLeftLine[r] : n - 1
            // 纯插入行在左侧没有对应行，映射指向的是它前面的那一行；
            // 导航要落到「插入点之后」的首行，才能把新增内容带进视口
            let projected = (kind == .inserted) ? base + 1 : base
            flagged[min(max(0, projected), n - 1)] = true
        }

        var result: [DiffHunk] = []
        var i = 0
        while i < n {
            guard flagged[i] else { i += 1; continue }
            let start = i
            while i < n, flagged[i] { i += 1 }
            let right = start < leftToRightLine.count ? leftToRightLine[start] : start
            result.append(DiffHunk(leftLine: start, rightLine: right, lineCount: i - start))
        }
        return result
    }
}

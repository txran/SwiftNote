import Foundation

/// 纯文本行索引：只保留原文本 + 每行边界，**不切 `[String]`**。
///
/// 100MB 级日志按行切分会生成上百万个小字符串（每个至少 16 字节头 + 独立缓冲区），
/// 实测 82MB 输入峰值内存 654MB；改成边界索引后同一输入降到 340MB 以内，
/// 且切行是零分配的。DiffEngine 与纯文本面板共用这一份索引。
public struct LineIndex {
    public let text: String
    private let starts: [String.Index]
    private let ends: [String.Index]
    /// FNV-1a 64 位行哈希。左右两侧天然同域，不需要任何映射表
    /// （碰撞概率：70 万行约 1.3e-8，可忽略）
    let hashes: [UInt64]

    public var count: Int { hashes.count }
    /// 空文本也计 1 行（与 TextKit 一致）
    public var isEmpty: Bool { text.isEmpty }

    public init(text: String) {
        var starts: [String.Index] = []
        var ends: [String.Index] = []
        var hashes: [UInt64] = []

        let utf8 = text.utf8
        // 行数无法预知，按字节数给一个保守估计避免多次扩容
        let estimate = max(1, utf8.count / 48)
        starts.reserveCapacity(estimate)
        ends.reserveCapacity(estimate)
        hashes.reserveCapacity(estimate)

        let seed: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3

        var lineStart = utf8.startIndex
        var index = utf8.startIndex
        var hash = seed
        /// 喂入最后一个字节**之前**的哈希，用于剥掉行尾 `\r`（FNV 不可回退）
        var hashBeforeLast = seed
        var lastWasCR = false

        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A {
                starts.append(lineStart)
                ends.append(lastWasCR ? utf8.index(before: index) : index)
                hashes.append(lastWasCR ? hashBeforeLast : hash)
                lineStart = utf8.index(after: index)
                hash = seed
                hashBeforeLast = seed
                lastWasCR = false
            } else {
                hashBeforeLast = hash
                hash = (hash ^ UInt64(byte)) &* prime
                lastWasCR = (byte == 0x0D)
            }
            index = utf8.index(after: index)
        }

        // 末尾行：`"a\n"` 视为 2 行，末行为空行
        starts.append(lineStart)
        ends.append(lastWasCR ? utf8.index(before: utf8.endIndex) : utf8.endIndex)
        hashes.append(lastWasCR ? hashBeforeLast : hash)

        self.text = text
        self.starts = starts
        self.ends = ends
        self.hashes = hashes
    }

    /// 取第 n 行（0 基）文本，行尾 `\r` 已剥离，**不含换行符**
    public func line(_ index: Int) -> Substring {
        text[starts[index]..<ends[index]]
    }

    func byteLength(_ index: Int) -> Int {
        text.utf8.distance(from: starts[index], to: ends[index])
    }
}

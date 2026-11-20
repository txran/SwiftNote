import Foundation

/// 文本内容指纹（FNV-1a 64 位 + 字节数）。
///
/// 用途只有一个：判断「撤销/重做之后是否回到了磁盘上的内容」（FR-10）。
/// 存整份副本做比较会让每个打开的标签多占一倍内存（200MB 文件不可接受），
/// 因此只留指纹——两个 64 位值即可，碰撞概率可以忽略（与 `LineIndex` 的行哈希同源）。
///
/// 按 UTF-8 字节计算：同一段文本无论经过哪种编码解码，只要字符一致指纹就一致。
public struct TextFingerprint: Equatable {
    public let byteCount: Int
    public let hash: UInt64

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    public init(text: String) {
        var hash = Self.offsetBasis
        var count = 0
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* Self.prime
            count += 1
        }
        self.byteCount = count
        self.hash = hash
    }

    /// 空文本的指纹（新建的未命名文档就是这个状态）
    public static let empty = TextFingerprint(text: "")
}

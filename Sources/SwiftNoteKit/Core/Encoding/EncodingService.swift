import Foundation

public struct DecodedFile {
    public let text: String
    public let encoding: FileEncoding
    /// 解码过程中出现替换字符（兜底容错解码）
    public let isLossy: Bool
    /// 磁盘上带 UTF-8 BOM。读取时剥掉、保存时按这个标记写回——
    /// 不记的话「打开带 BOM 的文件再保存」会静默把 BOM 抹掉，
    /// 某些只认 BOM 的 Windows 工具（记事本早期版本、部分脚本解释器）就会改判成 GBK
    public let hasBOM: Bool

    public init(text: String, encoding: FileEncoding, isLossy: Bool, hasBOM: Bool = false) {
        self.text = text
        self.encoding = encoding
        self.isLossy = isLossy
        self.hasBOM = hasBOM
    }
}

/// 编码服务（设计说明书 5.6 / D-7）
public enum EncodingService {
    /// GB18030（GBK 超集），走 CFString 零依赖
    public static let gb18030: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    public static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 探測链：UTF-8 BOM → UTF-8 严格 → GB18030 → UTF-8 容错兜底
    public static func detectAndDecode(_ data: Data) -> DecodedFile {
        let hasBOM = hasUTF8BOM(data)
        var payload = data
        if hasBOM {
            payload = payload.dropFirst(3)
        }
        if let s = String(data: payload, encoding: .utf8) {
            return DecodedFile(text: s, encoding: .utf8, isLossy: false, hasBOM: hasBOM)
        }
        if let s = String(data: payload, encoding: gb18030) {
            return DecodedFile(text: s, encoding: .gbk, isLossy: false, hasBOM: hasBOM)
        }
        AppLogger.warn("编码探测失败，使用 UTF-8 容错解码（可能含替换字符）")
        return DecodedFile(text: String(decoding: payload, as: UTF8.self),
                           encoding: .utf8, isLossy: true, hasBOM: hasBOM)
    }

    /// 按**指定**编码解码（切换编码 / 重新解码用）。
    ///
    /// 与 `detectAndDecode` 的区别是「用户说了算」：解不出来返回 nil，
    /// 绝不退化到容错解码——否则用户切错编码会拿到一堆 `\u{FFFD}`
    /// 还以为是文件坏了。
    public static func decode(_ data: Data, as encoding: FileEncoding) -> DecodedFile? {
        switch encoding {
        case .utf8:
            let hasBOM = hasUTF8BOM(data)
            let payload = hasBOM ? data.dropFirst(3) : data[...]
            guard let s = String(data: payload, encoding: .utf8) else { return nil }
            return DecodedFile(text: s, encoding: .utf8, isLossy: false, hasBOM: hasBOM)
        case .gbk:
            // GBK 没有 BOM 概念；真带 BOM 的多半是被误存的 UTF-8，剥掉再试更宽松
            let payload = hasUTF8BOM(data) ? data.dropFirst(3) : data[...]
            guard let s = String(data: payload, encoding: gb18030) else { return nil }
            return DecodedFile(text: s, encoding: .gbk, isLossy: false, hasBOM: false)
        }
    }

    public static func hasUTF8BOM(_ data: Data) -> Bool {
        data.count >= 3
            && data[data.startIndex] == 0xEF
            && data[data.startIndex + 1] == 0xBB
            && data[data.startIndex + 2] == 0xBF
    }

    /// 按指定编码编码；GBK 遇到不可映射字符返回 nil（调用方提示改用 UTF-8 保存）
    public static func encode(_ text: String, as encoding: FileEncoding) -> Data? {
        switch encoding {
        case .utf8:
            return text.data(using: .utf8)
        case .gbk:
            return text.data(using: gb18030)
        }
    }

    /// 带 BOM 开关的编码：只有 UTF-8 才谈得上 BOM，GBK 传 true 会被忽略
    public static func encode(_ text: String, as encoding: FileEncoding, bom: Bool) -> Data? {
        guard let body = encode(text, as: encoding) else { return nil }
        guard bom, encoding == .utf8 else { return body }
        var data = Data(utf8BOM)
        data.append(body)
        return data
    }

    /// 当前文本能否用该编码无损保存（切换编码前的可逆性检查）
    ///
    /// 注意：这里用的是 GB18030（GBK 超集），理论上能表示全部 Unicode，
    /// 所以对 `.gbk` 几乎恒为 true。真正要当心的是「写出来的字节别的工具读不读得动」，
    /// 那个用 `hasSupplementaryPlaneCharacters` 判。
    public static func canEncode(_ text: String, as encoding: FileEncoding) -> Bool {
        encode(text, as: encoding) != nil
    }

    /// 文本里有没有 BMP 以外的字符（emoji、生僻扩展汉字等）。
    ///
    /// GB18030 会把它们编成 4 字节序列——自己读回来没问题，
    /// 但只认 GBK 双字节区的工具（不少 Java/MFC 报文工具）会截断或报错。
    /// 转 GBK 前拿这个提示一下，比事后排查乱码便宜。
    public static func hasSupplementaryPlaneCharacters(in text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value > 0xFFFF { return true }
        return false
    }
}

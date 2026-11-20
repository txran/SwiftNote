import Foundation

public enum FileIOError: Error, LocalizedError {
    case unreadable(String)
    case writeDenied(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let p): return "无法读取文件：\(p)"
        case .writeDenied(let p): return "无写入权限：\(p)"
        case .encodeFailed(let v): return "文本包含当前编码无法表示的字符（\(v)），请改用 UTF-8 保存"
        }
    }
}

/// 原子写：同目录临时文件 → fsync → 原子替换（设计说明书 6.2 / D-5）
public enum AtomicSaver {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".swiftnote-\(UUID().uuidString).tmp")
        let fm = FileManager.default

        guard fm.isWritableFile(atPath: dir.path) else {
            throw FileIOError.writeDenied(url.path)
        }
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw FileIOError.writeDenied(temp.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()   // fsync：防写一半崩溃丢内容
            try handle.close()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: temp,
                                         backupItemName: nil,
                                         options: [.usingNewMetadataOnly])
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        } else {
            do {
                try fm.moveItem(at: temp, to: url)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
    }

    /// - Parameters:
    ///   - lineEnding: 写盘用的换行风格。内存文本始终是 `\n`，
    ///     这里统一转换（Windows 工具链读的文件必须是 CRLF，否则会被当成一整行）
    ///   - bom: 是否写 UTF-8 BOM。只对 `.utf8` 有意义；带 BOM 打开的文件必须原样写回，
    ///     否则「打开—保存」一轮就把 BOM 抹掉了（GBK 分支会忽略它）
    public static func save(text: String, to url: URL, encoding: FileEncoding,
                            lineEnding: LineEnding = .lf, bom: Bool = false) throws {
        let payload = lineEnding.applied(to: text)
        guard let data = EncodingService.encode(payload, as: encoding, bom: bom) else {
            throw FileIOError.encodeFailed(encoding.displayName)
        }
        try write(data, to: url)
    }
}

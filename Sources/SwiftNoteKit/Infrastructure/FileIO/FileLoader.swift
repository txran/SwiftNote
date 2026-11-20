import Foundation

public struct LoadedFile {
    public let url: URL
    public let text: String
    public let encoding: FileEncoding
    public let syntaxMode: SyntaxMode
    public let meta: FileMeta
    public let isLossy: Bool
    /// 磁盘上带 UTF-8 BOM（保存时原样写回）
    public let hasBOM: Bool
    /// 磁盘上原本的换行风格（内存文本已归一成 `\n`，保存时按它写回）
    public let lineEnding: LineEnding

    public var sizeBytes: Int64 { meta.size }
}

/// 文件加载（设计说明书 6.1）：后台读 Data，不阻塞主线程
public enum FileLoader {
    public static func load(url: URL) throws -> LoadedFile {
        let meta = FileMeta.read(from: url) ?? FileMeta(size: 0, modificationDate: Date())
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FileIOError.unreadable(url.lastPathComponent)
        }
        let decoded = EncodingService.detectAndDecode(data)
        // 换行归一：CRLF/CR 一律变 `\n`，行号栏、搜索、diff 只认一种分隔符
        let lineEnding = LineEnding.detect(in: decoded.text)
        let text = LineEnding.normalized(decoded.text)
        let prefix = String(text.prefix(4096))
        let mode = SyntaxMode.detect(fileURL: url, contentPrefix: prefix)
        return LoadedFile(url: url, text: text, encoding: decoded.encoding,
                          syntaxMode: mode, meta: meta, isLossy: decoded.isLossy,
                          hasBOM: decoded.hasBOM, lineEnding: lineEnding)
    }

    /// 并发加载多文件（拖入 / 批量打开），完成后主线程回调
    public static func loadAsync(urls: [URL],
                                 completion: @escaping ([LoadedFile], [(URL, Error)]) -> Void) {
        guard !urls.isEmpty else {
            completion([], [])
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [LoadedFile] = []
        var failures: [(URL, Error)] = []

        for url in urls {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let file = try load(url: url)
                    lock.lock(); loaded.append(file); lock.unlock()
                } catch {
                    lock.lock(); failures.append((url, error)); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            // 保持与传入顺序一致的稳定排序
            let order = Dictionary(uniqueKeysWithValues: urls.enumerated().map { ($1, $0) })
            loaded.sort { (order[$0.url] ?? 0) < (order[$1.url] ?? 0) }
            completion(loaded, failures)
        }
    }
}

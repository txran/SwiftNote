import Foundation
import SwiftNoteKit

// 轻量测试运行器（CLT 环境无 XCTest）：`swift run CoreTests`
var failures = 0
var checks = 0

func check(_ condition: Bool, _ name: String, detail: String = "") {
    checks += 1
    if condition {
        print("  ✅ \(name)")
    } else {
        failures += 1
        print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    check(actual == expected, name, detail: "实际 \(actual)，期望 \(expected)")
}

/// 跑主线程 run loop 等待条件成立（异步回调在 main queue 上交付）
@discardableResult
func waitUntil(_ timeout: Double = 2.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

// MARK: - 词法器

print("\n[词法] JSON")
let jsonLine = "  \"name\": \"cbmMessage\", \"count\": 12, \"ok\": true, \"n\": null"
let jsonEngine = SyntaxEngine(mode: .json)
jsonEngine.setText(jsonLine as NSString)
let jsonTokens = jsonEngine.spans(inLines: 0...0)
equal(jsonTokens.filter { $0.type == .key }.count, 4, "识别 4 个 key")
equal(jsonTokens.filter { $0.type == .stringValue }.count, 1, "识别 1 个字符串值")
equal(jsonTokens.filter { $0.type == .number }.count, 1, "识别数字")
equal(jsonTokens.filter { $0.type == .boolean }.count, 1, "识别布尔")
equal(jsonTokens.filter { $0.type == .nullLiteral }.count, 1, "识别 null")

print("\n[词法] XML 跨行注释与标签")
let xml = "<!-- 开始\n继续注释\n结束 -->\n<root attr=\"v\">x</root>"
let xmlEngine = SyntaxEngine(mode: .xml)
xmlEngine.setText(xml as NSString)
equal(xmlEngine.lineCount, 4, "4 行")
equal(xmlEngine.tokens(inLine: 1).first?.type, .comment, "第 2 行仍在注释内")
check(xmlEngine.tokens(inLine: 3).contains { $0.type == .tagName }, "第 4 行识别标签名")
check(xmlEngine.tokens(inLine: 3).contains { $0.type == .attrValue }, "第 4 行识别属性值")

print("\n[词法] Properties 续行")
let props = "# 注释\nkey=value \\\n  续行值\nother:2"
let propsEngine = SyntaxEngine(mode: .properties)
propsEngine.setText(props as NSString)
equal(propsEngine.tokens(inLine: 0).first?.type, .comment, "注释行")
check(propsEngine.tokens(inLine: 1).contains { $0.type == .propKey }, "识别 key")
equal(propsEngine.tokens(inLine: 2).first?.type, .propValue, "续行整行视为 value")

print("\n[词法] 增量重词法收敛")
let incEngine = SyntaxEngine(mode: .json)
incEngine.setText("{\n  \"a\": 1,\n  \"b\": 2\n}" as NSString)
let updated: NSString = "{\n  \"a\": 100,\n  \"b\": 2\n}"
let affected = incEngine.applyChange(text: updated, aroundOffset: 9)
check(affected != nil && affected!.count <= 2, "普通编辑只影响 1~2 行", detail: "实际 \(String(describing: affected))")

// MARK: - JSON 服务

print("\n[JSON] 格式化与校验")
if let formatted = try? JSONService.format("{\"b\":1,\"a\":2}") {
    check(formatted.contains("\n  "), "输出 2 空格缩进")
    let bIndex = formatted.range(of: "\"b\"")?.lowerBound
    let aIndex = formatted.range(of: "\"a\"")?.lowerBound
    if let b = bIndex, let a = aIndex {
        check(b < a, "键序保持不变")
    }
    check((try? JSONService.format(formatted)) == formatted, "格式化幂等")
} else {
    check(false, "格式化成功")
}
switch JSONService.validate("{\"a\": }") {
case .success:
    check(false, "非法 JSON 应校验失败")
case .failure(let error):
    check(!error.message.isEmpty, "非法 JSON 返回错误信息", detail: error.message)
}
switch JSONService.validate("{\"a\": 1}") {
case .success: check(true, "合法 JSON 通过校验")
case .failure(let e): check(false, "合法 JSON 通过校验", detail: e.message)
}

// MARK: - 编码

print("\n[编码] 探测与转换")
let utf8Data = "{\"中文\":\"值\"}".data(using: .utf8)!
let utf8Decoded = EncodingService.detectAndDecode(utf8Data)
equal(utf8Decoded.encoding, .utf8, "UTF-8 探测")
equal(utf8Decoded.text, "{\"中文\":\"值\"}", "UTF-8 内容一致")
let gbkData = "网关超时=3000".data(using: EncodingService.gb18030)!
let gbkDecoded = EncodingService.detectAndDecode(gbkData)
equal(gbkDecoded.encoding, .gbk, "GBK 探测")
equal(gbkDecoded.text, "网关超时=3000", "GBK 内容一致")
check(EncodingService.canEncode("纯 ASCII", as: .gbk), "ASCII 可用 GBK 保存")

print("\n[编码] BOM 读写")
let bomPayload = "带 BOM 的中文".data(using: .utf8)!
let bomData = Data(EncodingService.utf8BOM) + bomPayload
let bomDecoded = EncodingService.detectAndDecode(bomData)
equal(bomDecoded.text, "带 BOM 的中文", "读取时剥掉 BOM")
check(bomDecoded.hasBOM, "记录到 BOM 标记")
check(!EncodingService.detectAndDecode(bomPayload).hasBOM, "无 BOM 的文件不误判")
let bomEncoded = EncodingService.encode("带 BOM 的中文", as: .utf8, bom: true)
equal(bomEncoded?.count, bomData.count, "带 BOM 编码长度 = BOM + 正文")
equal(EncodingService.encode("x", as: .gbk, bom: true)?.count, 1, "GBK 忽略 BOM 开关")

let bomFile = FileManager.default.temporaryDirectory
    .appendingPathComponent("swiftnote-bom-\(UUID().uuidString).json")
try? AtomicSaver.save(text: "内容", to: bomFile, encoding: .utf8, bom: true)
check(EncodingService.hasUTF8BOM((try? Data(contentsOf: bomFile)) ?? Data()), "落盘带 BOM")
try? AtomicSaver.save(text: "内容", to: bomFile, encoding: .utf8, bom: false)
check(!EncodingService.hasUTF8BOM((try? Data(contentsOf: bomFile)) ?? Data()), "关掉开关后落盘无 BOM")
try? FileManager.default.removeItem(at: bomFile)

print("\n[编码] 指定编码重解码（切换编码）")
equal(EncodingService.decode(bomData, as: .utf8)?.text, "带 BOM 的中文", "指定 UTF-8 解码也剥 BOM")
equal(EncodingService.decode(bomData, as: .utf8)?.hasBOM, true, "重解码回报 BOM")
check(EncodingService.decode(gbkData, as: .utf8) == nil, "GBK 字节按 UTF-8 严格解码返回 nil（不给乱码）")
equal(EncodingService.decode(gbkData, as: .gbk)?.text, "网关超时=3000", "指定 GBK 解码正确")
check(EncodingService.decode(utf8Data, as: .gbk)?.text != "{\"中文\":\"值\"}",
      "UTF-8 字节按 GBK 解不出原文（所以「转为」与「重新解码」必须分开）")

print("\n[编码] GB18030 超集行为")
// GB18030 覆盖全部 Unicode，emoji 也能编——所以「转为 GBK」几乎不会失败，
// 风险在另一端：4 字节序列别的工具读不懂
let emojiText = "中文😀"
check(EncodingService.canEncode(emojiText, as: .gbk), "GB18030 能编 emoji")
let emojiBytes = EncodingService.encode(emojiText, as: .gbk)!
equal(emojiBytes.count, 2 * 2 + 4, "中文占 2+2 字节，emoji 占 4 字节")
equal(EncodingService.decode(emojiBytes, as: .gbk)?.text, emojiText, "转 GBK 再读回内容不变（无损）")
check(EncodingService.hasSupplementaryPlaneCharacters(in: emojiText), "识别出 BMP 以外的字符")
check(!EncodingService.hasSupplementaryPlaneCharacters(in: "纯中文=1"), "普通中文不算超范围")
check(EncodingService.canEncode("纯中文=1", as: .gbk), "普通中文可编")

// MARK: - 偏好设置

print("\n[设置] 默认值与越界钳制")
let suiteName = "SwiftNoteTests-\(UUID().uuidString)"
let suite = UserDefaults(suiteName: suiteName)!
let settings = AppSettings(defaults: suite)
equal(settings.maxTabRows, 5, "maxTabRows 默认 5")
settings.maxTabRows = 99
equal(settings.maxTabRows, 5, "越界回落默认")
settings.maxTabRows = 2
equal(settings.maxTabRows, 2, "合法值生效")
equal(settings.draftSnapshotDelaySec, 2.0, "草稿快照延迟默认 2s")

print("\n[设置] 大文件只读阈值")
equal(settings.largeFileThresholdMB, 10, "只读阈值默认 10MB")
settings.largeFileThresholdMB = 0
equal(settings.largeFileThresholdMB, 1, "低于下限钳到 1MB")
settings.largeFileThresholdMB = 99999
equal(settings.largeFileThresholdMB, 2048, "高于上限钳到 2048MB")
settings.largeFileThresholdMB = 30
equal(settings.largeFileThresholdMB, 30, "合法值原样生效")
equal(settings.largeFileThresholdBytes, Int64(30) * 1024 * 1024, "MB → 字节换算")

print("\n[设置] 快捷键")
let saveCombo = KeyCombo(key: "s", modifiers: [.command])
equal(settings.shortcut(.saveDocument)?.serialized, saveCombo.serialized, "未改过 → 取默认 ⌘S")
equal(saveCombo.serialized, "cmd+s", "序列化形式")
equal(saveCombo.displayText, "⌘S", "显示形式")
equal(KeyCombo(serialized: "cmd+s")?.serialized, saveCombo.serialized, "序列化可回读")

let shiftCmdD = KeyCombo(key: "d", modifiers: [.command, .shift])
equal(shiftCmdD.serialized, "shift+cmd+d", "修饰键顺序固定")
equal(shiftCmdD.displayText, "⇧⌘D", "符号顺序为 ⇧⌘")
equal(KeyCombo(serialized: shiftCmdD.serialized)?.serialized, shiftCmdD.serialized, "⇧⌘D 往返一致")

let returnCombo = KeyCombo(key: "return", modifiers: [.command])
equal(KeyCombo(serialized: returnCombo.serialized)?.serialized, returnCombo.serialized, "具名键往返一致")
equal(returnCombo.displayText, "⌘↩", "具名键显示符号")

check(!KeyCombo(key: "a", modifiers: [.shift]).isAcceptable, "只有 shift 不接受")
check(KeyCombo(key: "a", modifiers: [.control]).isAcceptable, "⌃ 单独可用")
check(KeyCombo(serialized: "cmd+bogus") != nil, "多段解析时最后一段当作键名")
check(KeyCombo(serialized: "meta+s") == nil, "非法修饰键返回 nil")

let customSave = KeyCombo(key: "k", modifiers: [.command, .option, .control])
settings.setShortcut(customSave, for: .saveDocument)
equal(settings.shortcut(.saveDocument)?.serialized, customSave.serialized, "自定义后生效")
check(settings.isShortcutCustomized(.saveDocument), "标记为已自定义")
check(!settings.isShortcutCustomized(.openDocument), "未改过的不标记")

equal(settings.conflictingAction(for: customSave, excluding: .find), .saveDocument, "冲突检测命中")
check(settings.conflictingAction(for: customSave, excluding: .saveDocument) == nil, "排除自身不算冲突")
equal(settings.conflictingAction(for: KeyCombo(key: "f", modifiers: [.command]), excluding: .saveDocument),
      .find, "能查出默认值之间的占用")

settings.setShortcut(nil, for: .saveDocument)
check(settings.shortcut(.saveDocument) == nil, "显式清除后无快捷键")
check(settings.isShortcutCustomized(.saveDocument), "清除也算自定义")

settings.setShortcut(KeyCombo(key: "9", modifiers: [.command]), for: .validateJSON)
check(AppSettings.containsShortcutChange([AppSettings.shortcutKeyPrefix + ShortcutAction.validateJSON.rawValue]),
      "变更键可被识别为快捷键改动")
check(!AppSettings.containsShortcutChange([AppSettings.Key.maxTabRows]), "普通偏好不算快捷键改动")

settings.resetToDefaults()
equal(settings.shortcut(.saveDocument)?.serialized, saveCombo.serialized, "恢复默认后回到 ⌘S")
check(!settings.isShortcutCustomized(.saveDocument), "恢复默认后自定义标记清除")
check(settings.shortcut(.validateJSON) == nil, "恢复默认后校验 JSON 仍无快捷键")

suite.removePersistentDomain(forName: suiteName)

// MARK: - 文件与存储

print("\n[存储] 原子写 / 草稿 / 会话")
let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("SwiftNoteTests-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let target = tempDir.appendingPathComponent("sample.json")
do {
    try AtomicSaver.save(text: "{\"a\":1}", to: target, encoding: .utf8)
    let readBack = try String(contentsOf: target, encoding: .utf8)
    equal(readBack, "{\"a\":1}", "原子写后内容一致")
    try AtomicSaver.save(text: "{\"a\":2}", to: target, encoding: .utf8)
    equal(try String(contentsOf: target, encoding: .utf8), "{\"a\":2}", "覆盖写生效")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        .filter { $0.hasSuffix(".tmp") }
    equal(leftovers.count, 0, "无残留临时文件")
} catch {
    check(false, "原子写流程", detail: error.localizedDescription)
}

let draftDir = tempDir.appendingPathComponent("drafts", isDirectory: true)
let draftStore = DraftStore(directory: draftDir)
let docID = UUID()
draftStore.save("草稿内容", for: docID)
equal(draftStore.load(for: docID), "草稿内容", "草稿读写一致")
check(draftStore.hasDraft(for: docID), "hasDraft 判定正确")
draftStore.remove(for: docID)
check(draftStore.load(for: docID) == nil, "草稿删除生效")

let sessionFile = tempDir.appendingPathComponent("session.json")
let session = SessionService(fileURL: sessionFile)
let snapshot = SessionSnapshot(activeTabIndex: 1,
                               tabs: [TabSnapshot(id: docID.uuidString, filePath: "/tmp/a.json",
                                                  hasDraft: true, scrollPosition: 12.5, cursorOffset: 30,
                                                  encoding: "UTF-8", syntaxMode: "json", readOnly: false)],
                               recentFiles: ["/tmp/a.json"])
session.save(snapshot)
if let loaded = session.load() {
    equal(loaded.activeTabIndex, 1, "会话 activeTabIndex 往返")
    equal(loaded.tabs.first?.syntaxMode, "json", "会话语法模式往返")
    check(loaded.recentFiles.first == "/tmp/a.json", "最近文件往返")
} else {
    check(false, "会话读写")
}
let rawSession = (try? String(contentsOf: sessionFile, encoding: .utf8)) ?? ""
check(rawSession.contains("\"activeTabIndex\""), "会话字段为 camelCase")

// MARK: - 搜索替换（FR-08）

print("\n[搜索] 字面量与大小写")
let searchText = "CbmMessage cbmMessage CBM_MESSAGE 其他"
let literalInsensitive = SearchEngine.findAll(in: searchText, query: SearchQuery(term: "cbmMessage"))
equal(literalInsensitive.count, 2, "忽略大小写命中 2 处（不跨下划线）")
let literalSensitive = SearchEngine.findAll(in: searchText,
                                           query: SearchQuery(term: "cbmMessage", isCaseSensitive: true))
equal(literalSensitive.count, 1, "区分大小写命中 1 处")
check(SearchEngine.findAll(in: searchText, query: SearchQuery(term: "")).isEmpty, "空查询无命中")

print("\n[搜索] 正则与整词")
let regexHits = SearchEngine.findAll(in: "a1 b22 c333",
                                     query: SearchQuery(term: "[a-z]\\d+", isRegex: true))
equal(regexHits.count, 3, "正则命中 3 处")
let wordHits = SearchEngine.findAll(in: "cat concatenate a cat",
                                    query: SearchQuery(term: "cat", isWholeWord: true))
equal(wordHits.count, 2, "整词匹配跳过 concatenate")
let starHits = SearchEngine.findAll(in: "aaa", query: SearchQuery(term: "a*", isRegex: true))
check(!starHits.isEmpty, "零长度正则不死循环")
do {
    _ = try SearchQuery(term: "([", isRegex: true).compiledRegex()
    check(false, "非法正则抛错")
} catch {
    check(true, "非法正则抛错")
}

print("\n[搜索] 区间扫描与导航")
let scoped = SearchEngine.findAll(in: "xx ab xx ab",
                                  query: SearchQuery(term: "ab"),
                                  in: NSRange(location: 0, length: 8))
equal(scoped.count, 1, "只在给定区间内命中")
let navMatches = [NSRange(location: 2, length: 2),
                  NSRange(location: 10, length: 2),
                  NSRange(location: 20, length: 2)]
equal(SearchEngine.nextIndex(in: navMatches, from: 3, forward: true), 0, "光标在命中内部时先选中该命中")
equal(SearchEngine.nextIndex(in: navMatches, from: 4, forward: true), 1, "光标在命中末尾时前进到下一条")
equal(SearchEngine.nextIndex(in: navMatches, from: 30, forward: true), 0, "越过末尾回卷到首条")
equal(SearchEngine.nextIndex(in: navMatches, from: 11, forward: false), 1, "向前取第 2 条")
let positions = SearchEngine.relativePositions(of: navMatches, textLength: 40)
check(abs(positions[2] - 0.5) < 0.0001, "相对位置按偏移换算")

print("\n[替换] 字面量与模板")
let (literalReplaced, literalCount) = try SearchEngine.replaceAll(in: "a.b a.b",
                                                                 query: SearchQuery(term: "a.b"),
                                                                 with: "$1X")
equal(literalCount, 2, "字面量替换 2 处")
equal(literalReplaced, "$1X $1X", "字面量替换不展开 $1")
let (regexReplaced, regexCount) = try SearchEngine.replaceAll(in: "name=1 count=2",
                                                             query: SearchQuery(term: "(\\w+)=(\\d)",
                                                                                isRegex: true),
                                                             with: "$1:$2")
equal(regexCount, 2, "正则替换 2 处")
equal(regexReplaced, "name:1 count:2", "正则替换展开 $1/$2")
let (plainReplaced, _) = try SearchEngine.replaceAll(in: "Foo foo",
                                                     query: SearchQuery(term: "foo", isCaseSensitive: true),
                                                     with: "bar")
equal(plainReplaced, "Foo bar", "区分大小写替换只改一处")

// MARK: - 外部修改监视（FR-11）

print("\n[监视] 基线比对")
let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let metaA = FileMeta(size: 10, modificationDate: t0)
equal(FileChangeDetector.compare(cached: metaA, current: metaA).hasChange, false, "基线一致 → 无变化")
equal(FileChangeDetector.compare(cached: metaA, current: FileMeta(size: 11, modificationDate: t0)),
      .modified, "大小变化 → 修改")
equal(FileChangeDetector.compare(cached: metaA, current: FileMeta(size: 10, modificationDate: t0.addingTimeInterval(1))),
      .modified, "mtime 变化 → 修改")
equal(FileChangeDetector.compare(cached: metaA, current: nil), .deleted, "路径不存在 → 删除")
equal(FileChangeDetector.compare(cached: nil, current: metaA), .none, "无基线 → 不提示")

print("\n[监视] vnode 事件与 inode 重挂")
let watchDir = tempDir.appendingPathComponent("watch", isDirectory: true)
try? FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
let watchURL = watchDir.appendingPathComponent("watched.json")
try? AtomicSaver.save(text: "{\"a\":1}", to: watchURL, encoding: .utf8)

var watchEvents: [FileChangeKind] = []
let watcher = FileWatcher(url: watchURL)
watcher.debounceInterval = 0.05
watcher.onChange = { watchEvents.append($0) }
watcher.start()
check(watcher.isRunning, "监视已启动")

var baseline = watchEvents.count
try? AtomicSaver.save(text: "{\"a\":2}", to: watchURL, encoding: .utf8)
check(waitUntil { watchEvents.count > baseline }, "写入触发回调")
equal(watchEvents.last, FileChangeKind.modified, "事件类型为 modified")
check(!watchEvents.contains(.deleted), "原子写（换 inode）不误报为删除")

// 关键回归：原子写换掉 inode 后，监视必须仍然活着
baseline = watchEvents.count
try? AtomicSaver.save(text: "{\"a\":3}", to: watchURL, encoding: .utf8)
check(waitUntil { watchEvents.count > baseline }, "换 inode 后仍能收到下一次修改")

// 保存路径的重挂走 retarget（保留对象只换 fd）
baseline = watchEvents.count
watcher.retarget(to: watchURL)
try? AtomicSaver.save(text: "{\"a\":5}", to: watchURL, encoding: .utf8)
check(waitUntil { watchEvents.count > baseline }, "retarget 后仍能收到修改")

baseline = watchEvents.count
try? FileManager.default.removeItem(at: watchURL)
check(waitUntil { watchEvents.count > baseline }, "删除触发回调")
equal(watchEvents.last, FileChangeKind.deleted, "事件类型为 deleted")

watcher.stop()
check(!watcher.isRunning, "监视已停止")

print("\n[监视] 文档状态与删除标记")
let watchDoc = EditorDocument(fileURL: watchURL, text: "{}", encoding: .utf8, syntaxMode: .json)
watchDoc.fileMeta = FileMeta(size: 7, modificationDate: t0)
check(!watchDoc.isFileMissing, "初始未标记删除")
equal(watchDoc.refreshExternalState(), .deleted, "文件不存在 → 探测为 deleted")
check(watchDoc.isFileMissing, "标记 isFileMissing")
check(watchDoc.displayName.hasSuffix("（已删除）"), "标题追加已删除标识")
equal(watchDoc.state, .clean, "仅探测不改脏标记")

// MARK: - 双屏对比（FR-09）

print("\n[对比] 相同文本")
let sameResult = DiffEngine.compare(left: "a\nb\nc", right: "a\nb\nc")
check(sameResult.isIdentical, "完全一致时 isIdentical")
equal(sameResult.stats.hunks, 0, "无差异块")
equal(sameResult.leftKinds.count, 3, "左侧行数")
check(sameResult.leftToRightLine == [0, 1, 2], "一致时行映射为恒等",
      detail: "实际 \(sameResult.leftToRightLine)")

print("\n[对比] 修改行（含行内片段）")
let changedResult = DiffEngine.compare(left: "{\n  \"timeout\": 3000,\n  \"retry\": 3\n}",
                                       right: "{\n  \"timeout\": 5000,\n  \"retry\": 3\n}")
equal(changedResult.leftKinds[1], .changed, "左侧第 2 行标为修改")
equal(changedResult.rightKinds[1], .changed, "右侧第 2 行标为修改")
equal(changedResult.stats.changed, 1, "修改行计数")
equal(changedResult.stats.hunks, 1, "1 处差异")
check(changedResult.isInlineApplied, "行内阶段已执行")
let leftSpans = changedResult.leftInline[1] ?? []
check(!leftSpans.isEmpty, "左侧有行内片段")
if let span = leftSpans.first {
    let leftLine = "  \"timeout\": 3000," as NSString
    let fragment = leftLine.substring(with: span)
    check(fragment.contains("3000"), "行内片段命中改动的数字", detail: "实际「\(fragment)」")
}
equal(changedResult.leftKinds[0], .equal, "首行不变")
equal(changedResult.leftKinds[3], .equal, "末行不变")

print("\n[对比] 插入与删除")
let insertResult = DiffEngine.compare(left: "a\nc", right: "a\nb\nc")
equal(insertResult.stats.inserted, 1, "右侧新增 1 行")
equal(insertResult.stats.deleted, 0, "左侧无删除")
equal(insertResult.rightKinds[1], .inserted, "右侧中间行为新增")
check(insertResult.leftKinds.allSatisfy { $0 == .equal }, "左侧全部相同")
let deleteResult = DiffEngine.compare(left: "a\nb\nc", right: "a\nc")
equal(deleteResult.stats.deleted, 1, "左侧删除 1 行")
equal(deleteResult.leftKinds[1], .deleted, "左侧中间行为删除")
check(deleteResult.rightKinds.allSatisfy { $0 == .equal }, "右侧全部相同")

print("\n[对比] 前后缀剪枝与行映射")
var bigLeft: [String] = []
for i in 0..<2000 { bigLeft.append("line-\(i)") }
var bigRight = bigLeft
bigRight[1000] = "line-1000-changed"
let bigResult = DiffEngine.compare(left: bigLeft.joined(separator: "\n"),
                                   right: bigRight.joined(separator: "\n"))
equal(bigResult.stats.changed, 1, "2000 行中仅 1 行修改")
equal(bigResult.stats.hunks, 1, "1 处差异块")
equal(bigResult.leftToRightLine[999], 999, "差异前映射保持对齐")
equal(bigResult.leftToRightLine[1500], 1500, "差异后映射保持对齐")
equal(bigResult.leftToRightLine.count, 2000, "映射长度等于左侧行数")
check(bigResult.rightToLeftLine[1500] == 1500, "反向映射对齐")

print("\n[对比] 差异块导航（hunks）")
check(insertResult.hunks.isEmpty == false, "纯插入也算一处差异")
equal(insertResult.hunks.first?.leftLine, 1, "插入块映射回左侧第 1 行（0 基）")
check(deleteResult.hunks.count == 1, "纯删除 1 块")
equal(deleteResult.hunks.first?.leftLine, 1, "删除块起点")
let twoHunks = DiffEngine.compare(
    left: "a\nb\nc\nd\ne\nf\ng",
    right: "a\nB\nc\nd\ne\nF\ng")
equal(twoHunks.stats.hunks, 2, "两处修改")
equal(twoHunks.hunks.count, 2, "hunk 列表也是 2 块")
equal(twoHunks.hunks.map(\.leftLine), [1, 5], "hunk 起点行号")
equal(bigResult.hunks.count, bigResult.stats.hunks, "2000 行场景 hunk 数与统计一致")
equal(bigResult.hunks.first?.leftLine, 1000, "大文件 hunk 起点")
check(DiffEngine.compare(left: "x", right: "x").hunks.isEmpty, "相同文本无 hunk")
let leftEmpty = DiffEngine.compare(left: "", right: "a\nb")
check(leftEmpty.hunks.count <= 1, "左侧为空时最多一处")

print("\n[对比] CRLF 归一化")
let crlfResult = DiffEngine.compare(left: "a\r\nb\r\nc", right: "a\nb\nc")
check(crlfResult.isIdentical, "仅换行符风格不同不应报差异")

print("\n[对比] 中文字符行内片段（UTF-16 偏移）")
let cjkLeft = "网关超时=3000"
let cjkRight = "网关超时=5000"
let cjkResult = DiffEngine.compare(left: cjkLeft, right: cjkRight)
if let span = (cjkResult.leftInline[0] ?? []).first {
    let fragment = (cjkLeft as NSString).substring(with: span)
    check(fragment == "3000", "UTF-16 片段切出正确的数字", detail: "实际「\(fragment)」")
} else {
    check(false, "中文行产生行内片段")
}

print("\n[对比] 降级路径")
var inlineOff = DiffEngine.Options()
inlineOff.inlineCharacterLevel = false
let offResult = DiffEngine.compare(left: "a", right: "b", options: inlineOff)
check(!offResult.isInlineApplied, "关闭行内阶段时不执行")
check(offResult.leftInline.isEmpty, "关闭行内阶段无片段")
equal(offResult.leftKinds[0], .changed, "行级结果仍然存在")

var strictLimit = DiffEngine.Options()
strictLimit.inlineSizeLimit = 1
let largeReason = DiffEngine.compare(left: "aaa", right: "bbb", options: strictLimit)
check(largeReason.degradeReasons.contains(.largeFile), "超体积限制 → largeFile 降级")

var zeroTimeout = DiffEngine.Options()
zeroTimeout.timeout = 0
let timeoutResult = DiffEngine.compare(left: "a\nb", right: "x\ny", options: zeroTimeout)
check(timeoutResult.degradeReasons.contains(.timeout), "超时 → timeout 降级")
check(timeoutResult.leftInline.isEmpty, "降级后丢弃行内结果")
equal(timeoutResult.leftKinds[0], .changed, "降级后保留行级结果")

var tinyD = DiffEngine.Options()
tinyD.maxEditDistance = 1
let manyChanges = DiffEngine.compare(left: "1\n2\n3\n4\n5\n6\n7\n8", right: "a\nb\nc\nd\ne\nf\ng\nh",
                                     options: tinyD)
check(manyChanges.degradeReasons.contains(.tooManyChanges), "编辑距离超限 → tooManyChanges")
equal(manyChanges.leftKinds.count, 8, "降级后行级类型完整")
check(manyChanges.leftKinds.allSatisfy { $0.isDifferent }, "整段标记为差异")

print("\n[对比] 行索引与体积解耦")
let emptyTail = LineIndex(text: "a\n")
equal(emptyTail.count, 2, "以换行结尾视为 2 行（末行空行）")
equal(LineIndex(text: "a\nb\nc").count, 3, "3 行")
equal(LineIndex(text: "").count, 1, "空文本 1 行")
let crlfIndex = LineIndex(text: "a\r\nb\r\n")
equal(String(crlfIndex.line(0)), "a", "行尾 \\r 被剥离")
equal(String(crlfIndex.line(1)), "b", "第二行行尾 \\r 被剥离")
equal(String(crlfIndex.line(0)).utf8.count, 1, "剥掉 \\r 后字节数为 1")

// 大文件 + 少量修改：不能因为「文件大」就跳过字符级标差
var logLines: [String] = []
for i in 0..<40000 { logLines.append("2026-11-18T11:00:00.000Z INFO  msgId=CBM-\(i) field=amount payload=xxxx") }
var logRight = logLines
logRight[20000] = logRight[20000].replacingOccurrences(of: "amount", with: "AMOUNT")
let logResult = DiffEngine.compare(left: logLines.joined(separator: "\n"),
                                   right: logRight.joined(separator: "\n"))
equal(logResult.stats.changed, 1, "4 万行中 1 行修改")
check(!logResult.degradeReasons.contains(.largeFile), "体积大但差异少 → 不按体积降级")
check(logResult.isInlineApplied, "行内阶段仍然执行")
if let spans = logResult.leftInline[20000] {
    let fragment = (logLines[20000] as NSString).substring(with: spans[0])
    check(fragment == "amount", "行内片段命中被改的词", detail: "实际「\(fragment)」")
} else {
    check(false, "大文件少量修改应产生行内片段")
}

// 差异内容量超预算才降级
var budgetLimit = DiffEngine.Options()
budgetLimit.inlineSizeLimit = 100
let heavyDiff = DiffEngine.compare(
    left: Array(repeating: "a".padding(toLength: 80, withPad: "x", startingAt: 0), count: 20).joined(separator: "\n"),
    right: Array(repeating: "a".padding(toLength: 80, withPad: "y", startingAt: 0), count: 20).joined(separator: "\n"),
    options: budgetLimit)
check(heavyDiff.degradeReasons.contains(.largeFile), "差异内容超预算 → largeFile")
check(heavyDiff.leftInline.isEmpty, "降级后不保留行内片段")

print("\n[对比] 空文件与单侧全新增")
let emptyLeft = DiffEngine.compare(left: "", right: "a\nb")
equal(emptyLeft.stats.changed + emptyLeft.stats.inserted, 2, "左侧空 → 右侧 2 行全部标为差异")
check(emptyLeft.leftKinds[0].isDifferent, "空侧首行参与配对")
equal(emptyLeft.leftKinds.count, 1, "空文本计 1 行")
check(emptyLeft.leftToRightLine == [0], "空侧映射不越界", detail: "实际 \(emptyLeft.leftToRightLine)")

// MARK: - 文档状态机

print("\n[状态机] 脏标记流转")
let doc = EditorDocument(fileURL: target, text: "x", encoding: .utf8, syntaxMode: .json)
equal(doc.state, .clean, "初始 Clean")
doc.markEdited()
equal(doc.state, .dirty, "编辑后 Dirty")
doc.markSaved()
equal(doc.state, .clean, "保存后 Clean")
doc.demoteToReadOnly(.largeFile)
equal(doc.state, .readOnly, "降级为只读")
check(doc.isReadOnly, "isReadOnly 标记")
check(doc.promoteFromLargeFileReadOnly(), "阈值调大后可恢复可编辑")
equal(doc.state, .clean, "恢复后回到 Clean")
check(!doc.promoteFromLargeFileReadOnly(), "重复调用无副作用")
doc.demoteToReadOnly(.permission)
check(!doc.promoteFromLargeFileReadOnly(), "权限只读不会被阈值解锁")
equal(doc.state, .readOnly, "权限只读仍是只读")
doc.adopt(fileURL: target, meta: nil)
equal(doc.state, .clean, "另存为后回到 Clean")

// MARK: - 大文件面板判定（只读阈值 ≠ TextKit 硬上限）

print("\n[面板] 只读阈值与 TextKit 硬上限解耦")
let originalThresholdMB = AppSettings.shared.largeFileThresholdMB
defer { AppSettings.shared.largeFileThresholdMB = originalThresholdMB }
AppSettings.shared.largeFileThresholdMB = 1

let panelDoc = EditorDocument(text: "x", encoding: .utf8, syntaxMode: .plain)
panelDoc.fileMeta = FileMeta(size: 2 * 1024 * 1024, modificationDate: Date())
check(!panelDoc.prefersPlainText,
      "阈值 1MB 时 2MB 文件仍进 TextKit（只读也要能选中/折行）")
panelDoc.fileMeta = FileMeta(size: 11 * 1024 * 1024, modificationDate: Date())
check(panelDoc.prefersPlainText, "超硬上限才走纯文本面板")
equal(EditorDocument.plainTextHardLimitBytes, 10 * 1024 * 1024, "硬上限 10MB")

AppSettings.shared.largeFileThresholdMB = 64
panelDoc.fileMeta = FileMeta(size: 20 * 1024 * 1024, modificationDate: Date())
check(panelDoc.prefersPlainText, "阈值调到 64MB 也拦不住 20MB 文件进面板（否则 TextKit 会卡死）")

// MARK: - 内容指纹（FR-10 撤销回退判定）

print("\n[指纹] 撤销回到已保存内容")
let fingerprint = TextFingerprint(text: "{\"a\": 1}")
equal(TextFingerprint(text: "{\"a\": 1}"), fingerprint, "同内容同指纹")
check(TextFingerprint(text: "{\"a\": 2}") != fingerprint, "不同内容指纹不同")
check(TextFingerprint(text: "") != fingerprint, "空文本指纹不同")
equal(TextFingerprint.empty, TextFingerprint(text: ""), "空文本指纹常量")
equal(TextFingerprint(text: "中文").byteCount, 6, "长度按 UTF-8 字节计")

let undoDoc = EditorDocument(fileURL: target, text: "abc", encoding: .utf8, syntaxMode: .plain)
check(undoDoc.matchesSavedText("abc"), "初始内容等于基线")
undoDoc.markEdited()
undoDoc.markSaved(text: "abcd")
check(undoDoc.matchesSavedText("abcd"), "保存后基线更新为新内容")
check(!undoDoc.matchesSavedText("abc"), "保存前的内容不再算基线")
undoDoc.captureSavedText("abc")
check(undoDoc.matchesSavedText("abc"), "外部重载后基线可重新捕获")
check(undoDoc.matchesSavedText("abc"), "捕获基线不改变文档状态（仍为 Clean）")
equal(undoDoc.state, .clean, "captureSavedText 不动状态机")

try? FileManager.default.removeItem(at: tempDir)

// MARK: - 快速打开（FR-11 最近文件）

print("\n[快速打开] 路径显示")
let home = "/Users/tester"
let entry = QuickOpenItem(path: "/Users/tester/cfg/cbm-types.json", isOpen: false, exists: true,
                          homeDirectory: home)
equal(entry.name, "cbm-types.json", "取文件名")
equal(entry.directory, "~/cfg", "家目录缩成 ~")
let outside = QuickOpenItem(path: "/opt/conf/a.xml", isOpen: false, exists: true, homeDirectory: home)
equal(outside.directory, "/opt/conf", "家目录外保持原样")
let atHome = QuickOpenItem(path: "/Users/tester/a.txt", isOpen: false, exists: true, homeDirectory: home)
equal(atHome.directory, "~", "直接在家目录下显示 ~")

print("\n[快速打开] 合并与去重")
let merged = QuickOpen.items(openPaths: ["/a/b.json", "/a/d.json"],
                             recentPaths: ["/a/c.json", "/a/b.json", "/a/e.json"],
                             existing: { _ in true }, homeDirectory: home)
equal(merged.count, 4, "同一路径只留一条")
equal(merged.first?.path, "/a/b.json", "已打开文档排在前面")
equal(merged.filter { $0.path == "/a/b.json" }.count, 1, "去重后唯一")
check(merged.first?.isOpen == true, "已打开标记")
check(merged.last?.isOpen == false, "仅最近文件不标已打开")
let many = QuickOpen.items(openPaths: [], recentPaths: (0..<80).map { "/a/f\($0).json" },
                           existing: { _ in true }, homeDirectory: home)
equal(many.count, QuickOpen.maxItems, "候选条数封顶")

print("\n[快速打开] 过滤")
let candidates = QuickOpen.items(openPaths: [],
                                 recentPaths: ["/Users/tester/cfg/cbm-types.json",
                                               "/Users/tester/cfg/cbm-message.xml",
                                               "/Users/tester/notes/old-cbm.json",
                                               "/Users/tester/notes/todo.md"],
                                 existing: { !$0.contains("todo") }, homeDirectory: home)
equal(QuickOpen.filter(candidates, query: "").count, 4, "空查询返回全部")
equal(QuickOpen.filter(candidates, query: "cbm json").map(\.name),
      ["cbm-types.json", "old-cbm.json"], "空格分词全部命中（顺序无关）")
check(QuickOpen.filter(candidates, query: "cbm xml").contains { $0.name == "cbm-message.xml" },
      "cbm xml 命中 XML 文件")
equal(QuickOpen.filter(candidates, query: "cbm xml").count, 1, "cbm xml 不命中 json")
equal(QuickOpen.filter(candidates, query: "CBM").first?.name, "cbm-types.json", "查询不区分大小写")
equal(QuickOpen.filter(candidates, query: "cfg cbm").count, 2, "目录词也能过滤")
equal(QuickOpen.filter(candidates, query: "nothere"), [], "无匹配返回空")
equal(QuickOpen.filter(candidates, query: "  cbm  ").count, 3, "查询词两端空白忽略")
check(QuickOpen.filter(candidates, query: "todo").first?.exists == false, "不存在的文件仍可展示")

print("\n[快速打开] 排序")
let ranked = QuickOpen.items(openPaths: [],
                             recentPaths: ["/x/old-cbm.json", "/x/cbm-note.json", "/x/cbm.json"],
                             existing: { _ in true }, homeDirectory: home)
equal(QuickOpen.filter(ranked, query: "cbm.json").map(\.name).first, "cbm.json", "文件名完全相同排最前")
equal(QuickOpen.filter(ranked, query: "cbm").map(\.name),
      ["cbm-note.json", "cbm.json", "old-cbm.json"],
      "文件名前缀命中优先于仅包含，同档保持原顺序")

// MARK: - 换行符（EOL）

print("\n[换行符] 探测")
equal(LineEnding.detect(in: "a\r\nb\r\nc"), .crlf, "CRLF 识别")
equal(LineEnding.detect(in: "a\nb\nc"), .lf, "LF 识别")
equal(LineEnding.detect(in: "a\rb\rc"), .cr, "CR 识别")
equal(LineEnding.detect(in: "no newline"), .lf, "无换行默认 LF")
equal(LineEnding.detect(in: "a\r\nb\nc\r\nd"), .crlf, "混用取多数派 CRLF")
equal(LineEnding.detect(in: "a\nb\r\nc\n"), .lf, "混用取多数派 LF")
check(LineEnding.isMixed("a\r\nb\nc"), "CRLF+LF 判为混用")
check(!LineEnding.isMixed("a\r\nb\r\n"), "纯 CRLF 不算混用")
check(!LineEnding.isMixed("a\nb"), "纯 LF 不算混用")

print("\n[换行符] 归一与写回")
equal(LineEnding.normalized("a\r\nb\rc\nd"), "a\nb\nc\nd", "三种换行统一成 LF")
equal(LineEnding.crlf.applied(to: "a\nb"), "a\r\nb", "LF → CRLF")
equal(LineEnding.cr.applied(to: "a\nb"), "a\rb", "LF → CR")
equal(LineEnding.lf.applied(to: "a\nb"), "a\nb", "LF 保持原样")
equal(LineEnding.crlf.applied(to: LineEnding.normalized("a\r\nb\r\n")), "a\r\nb\r\n",
      "已是 CRLF 的文件写回不会叠加 \\r")
let mixedEOL = "x\r\ny\nz\r"
equal(LineEnding.normalized(mixedEOL), "x\ny\nz\n", "混行归一")
equal(LineEnding.detect(in: mixedEOL).applied(to: LineEnding.normalized(mixedEOL)),
      "x\r\ny\r\nz\r\n", "混行按主流风格写回")

// MARK: - JSON 美化（词法重排）

print("\n[JSON] 层级缩进")
let compactJSON = "{\"a\":1,\"b\":[2,3],\"c\":{\"d\":null}}"
let expectedJSON = """
{
  "a": 1,
  "b": [
    2,
    3
  ],
  "c": {
    "d": null
  }
}
"""
equal((try? JSONService.format(compactJSON)) ?? "<抛错>", expectedJSON,
      "缩进 2 空格、冒号后单空格、数组逐项换行")
equal((try? JSONService.format("{}")) ?? "<抛错>", "{}", "空对象保持一行")
equal((try? JSONService.format("{\"a\":{},\"b\":[]}")) ?? "<抛错>",
      "{\n  \"a\": {},\n  \"b\": []\n}", "嵌套空容器保持一行")
equal((try? JSONService.format("\"a:b\"")) ?? "<抛错>", "\"a:b\"", "字符串里的冒号不受影响")
equal((try? JSONService.format("[1,2]", indent: 4)) ?? "<抛错>", "[\n    1,\n    2\n]",
      "缩进宽度可调（4 空格）")

print("\n[JSON] 保真")
equal((try? JSONService.format("{\"id\":1234567890123456789}")) ?? "<抛错>",
      "{\n  \"id\": 1234567890123456789\n}", "大整数不经 NSNumber，原样保留")
equal((try? JSONService.format("{\"s\":\"a\\\"b\"}")) ?? "<抛错>",
      "{\n  \"s\": \"a\\\"b\"\n}", "转义引号不破坏结构")
equal((try? JSONService.format("{\"p\":\"a{b,c}\"}")) ?? "<抛错>",
      "{\n  \"p\": \"a{b,c}\"\n}", "字符串里的括号与逗号不触发换行")
if let once = try? JSONService.format(compactJSON), let twice = try? JSONService.format(once) {
    equal(once, twice, "二次格式化结果不变（幂等）")
} else {
    check(false, "幂等：格式化应成功")
}
do {
    _ = try JSONService.format("{\"a\":}")
    check(false, "非法 JSON 应抛错")
} catch let error as JSONValidationError {
    check(error.line > 0, "非法 JSON 的错误带行列", detail: error.description)
} catch {
    check(false, "非法 JSON 抛出的错误类型不对")
}

// MARK: - XML 报文层级化

print("\n[XML] 报文层级化")
let compactXML = "<Msg><Header><MsgId>12</MsgId><Type>B</Type></Header>"
    + "<Body a=\"1\" b=\"2\"><Item/></Body></Msg>"
let expectedXML = """
<Msg>
  <Header>
    <MsgId>12</MsgId>
    <Type>B</Type>
  </Header>
  <Body a="1" b="2">
    <Item/>
  </Body>
</Msg>
"""
equal((try? XMLService.format(compactXML)) ?? "<抛错>", expectedXML,
      "单行报文展开成层级，文本元素保持一行")
equal((try? XMLService.format("<a><b/></a>", indent: 4)) ?? "<抛错>",
      "<a>\n    <b/>\n</a>", "缩进宽度可调")
equal((try? XMLService.format("<a x=\"1>2\"><b/></a>")) ?? "<抛错>",
      "<a x=\"1>2\">\n  <b/>\n</a>", "属性里的 > 不当作标签结束")
equal((try? XMLService.format("<a>\n   hello   world\n</a>")) ?? "<抛错>",
      "<a>hello world</a>", "文本节点压空白后与标签合并成一行")
equal((try? XMLService.format("<a\n   x=\"1\"\n   y=\"2\" />")) ?? "<抛错>",
      "<a x=\"1\" y=\"2\"/>", "标签内部的换行压成单空格")
equal((try? XMLService.format("<a><b></b></a>")) ?? "<抛错>",
      "<a>\n  <b></b>\n</a>", "空元素保持 <b></b> 一行")

print("\n[XML] 声明 / 注释 / CDATA")
let withDecl = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Root><!--note--><A><![CDATA[x<y]]></A></Root>"
let expectedDecl = """
<?xml version="1.0" encoding="UTF-8"?>
<Root>
  <!--note-->
  <A>
    <![CDATA[x<y]]>
  </A>
</Root>
"""
equal((try? XMLService.format(withDecl)) ?? "<抛错>", expectedDecl,
      "声明不缩进、注释与 CDATA 各占一行")

print("\n[XML] 错误处理")
do {
    _ = try XMLService.format("<a><b></a></b>")
    check(false, "标签交叉应报错")
} catch let error as XMLFormatError {
    check(error.message.contains("不匹配"), "标签交叉报「不匹配」", detail: error.message)
} catch {
    check(false, "错误类型不对")
}
do {
    _ = try XMLService.format("<a><b></b>")
    check(false, "未闭合应报错")
} catch let error as XMLFormatError {
    check(error.message.contains("没有闭合"), "未闭合报「没有闭合」", detail: error.message)
} catch {
    check(false, "错误类型不对")
}
do {
    _ = try XMLService.format("</a>")
    check(false, "多余结束标签应报错")
} catch let error as XMLFormatError {
    check(error.message.contains("多余"), "多余结束标签报错", detail: error.message)
} catch {
    check(false, "错误类型不对")
}
do {
    _ = try XMLService.format("just text")
    check(false, "无标签应报错")
} catch let error as XMLFormatError {
    check(error.message.contains("没有 XML 标签"), "无标签时明确提示", detail: error.message)
} catch {
    check(false, "错误类型不对")
}

// MARK: - 片段格式化入口

print("\n[片段] 类型识别与格式化")
equal(SnippetFormatter.detect("  {\"a\":1}"), .json, "花括号开头判 JSON")
equal(SnippetFormatter.detect("[1,2]"), .json, "方括号开头判 JSON")
equal(SnippetFormatter.detect("\n  <Msg/>"), .xml, "尖括号开头判 XML")
check(SnippetFormatter.detect("hello") == nil, "普通文本不识别")
check(SnippetFormatter.detect("   ") == nil, "空白不识别")
equal((try? SnippetFormatter.format("<A><B>1</B></A>")) ?? "<抛错>",
      "<A>\n  <B>1</B>\n</A>", "自动识别 XML")
equal((try? SnippetFormatter.format("{\"a\":[1]}")) ?? "<抛错>",
      "{\n  \"a\": [\n    1\n  ]\n}", "自动识别 JSON")
do {
    _ = try SnippetFormatter.format("hello")
    check(false, "无法识别应抛错")
} catch {
    check(true, "无法识别时给出提示")
}

// MARK: - XML → JSON（右键「转换为 JSON」）

print("\n[转换] XML 报文 → JSON")
func lines(_ parts: String...) -> String { parts.joined(separator: "\n") }

equal((try? XMLToJSON.convert("<Msg><A>1</A><B>2</B></Msg>")) ?? "<抛错>",
      lines("{", "  \"Msg\": {", "    \"A\": \"1\",", "    \"B\": \"2\"", "  }", "}"),
      "保留根元素与子元素顺序")

equal((try? XMLToJSON.convert("<Msg><Item>1</Item><Item>2</Item></Msg>")) ?? "<抛错>",
      lines("{", "  \"Msg\": {", "    \"Item\": [", "      \"1\",", "      \"2\"", "    ]", "  }", "}"),
      "同名兄弟元素合成数组")

equal((try? XMLToJSON.convert("<Msg><Item>1</Item><Other>2</Other><Item>3</Item></Msg>")) ?? "<抛错>",
      lines("{", "  \"Msg\": {", "    \"Item\": [", "      \"1\",", "      \"3\"", "    ],",
            "    \"Other\": \"2\"", "  }", "}"),
      "同名元素不连续也归到同一数组（首次出现位置排序）")

equal((try? XMLToJSON.convert("<Msg><A id=\"7\" name=\"x\"/></Msg>")) ?? "<抛错>",
      lines("{", "  \"Msg\": {", "    \"A\": {", "      \"@id\": \"7\",", "      \"@name\": \"x\"", "    }", "  }", "}"),
      "属性加 @ 前缀")

equal((try? XMLToJSON.convert("<A id=\"1\">hi</A>")) ?? "<抛错>",
      lines("{", "  \"A\": {", "    \"@id\": \"1\",", "    \"#text\": \"hi\"", "  }", "}"),
      "属性与文本共存时文本放 #text")

equal((try? XMLToJSON.convert("<m a=\"x&gt;y\">007</m>")) ?? "<抛错>",
      lines("{", "  \"m\": {", "    \"@a\": \"x>y\",", "    \"#text\": \"007\"", "  }", "}"),
      "实体解码且文本保留前导零（不转数字）")

equal((try? XMLToJSON.convert("<A/>")) ?? "<抛错>",
      lines("{", "  \"A\": \"\"", "}"),
      "空元素给空字符串")

equal((try? XMLToJSON.convert("<?xml version=\"1.0\"?><!-- c --><r><![CDATA[a<b]]></r>")) ?? "<抛错>",
      lines("{", "  \"r\": \"a<b\"", "}"),
      "声明/注释丢弃，CDATA 当文本")

equal((try? XMLToJSON.convert("<a>1</a><b>2</b>")) ?? "<抛错>",
      lines("{", "  \"a\": \"1\",", "  \"b\": \"2\"", "}"),
      "多个根合成一个对象")

equal((try? XMLToJSON.convert("<r><a b=\"1>2\">x</a></r>")) ?? "<抛错>",
      lines("{", "  \"r\": {", "    \"a\": {", "      \"@b\": \"1>2\",", "      \"#text\": \"x\"", "    }", "  }", "}"),
      "属性值里的 > 不截断标签")

let convertedJSON = (try? XMLToJSON.convert("<r><a>1</a></r>")) ?? ""
check({ if case .success = JSONService.validate(convertedJSON) { return true }; return false }(),
      "输出能通过严格 JSON 校验")

for (bad, hint) in [("<a><b></a>", "不匹配"), ("<a>", "没有闭合"), ("纯文本", "没有找到")] {
    do {
        _ = try XMLToJSON.convert(bad)
        check(false, "\(bad) 应报错")
    } catch let error as XMLToJSON.Failure {
        check(error.message.contains(hint), "\(bad) 报错含「\(hint)」", detail: error.message)
    } catch {
        check(false, "\(bad) 错误类型不对")
    }
}

// MARK: - 选区里定位报文（日志夹报文）

print("\n[定位] SnippetExtractor")
let logLine = "2026-11-20 12:00:00 [INFO] resp={\"a\":1,\"b\":[2,3]} cost=12ms"
let jsonMatch = SnippetExtractor.locate(in: logLine)
equal(jsonMatch?.snippet ?? "<nil>", "{\"a\":1,\"b\":[2,3]}", "跳过日志前缀定位 JSON")
equal(jsonMatch?.kind ?? .xml, .json, "判为 JSON")
equal(jsonMatch?.location ?? -1, 32, "偏移指向左花括号")
equal((logLine as NSString).substring(with: NSRange(location: jsonMatch?.location ?? 0,
                                                   length: jsonMatch?.length ?? 0)),
      "{\"a\":1,\"b\":[2,3]}", "偏移+长度能直接切出 NSRange")

equal(SnippetExtractor.locate(in: "x={\"a\":\"}\"} y")?.snippet ?? "<nil>",
      "{\"a\":\"}\"}", "字符串里的 } 不提前闭合")

let xmlLog = "2026-11-20 12:00:00 [INFO] <Msg><A>1</A></Msg> tail"
equal(SnippetExtractor.locate(in: xmlLog)?.snippet ?? "<nil>", "<Msg><A>1</A></Msg>", "跳过前缀定位 XML")
equal(SnippetExtractor.locate(in: "p=<A/>q")?.snippet ?? "<nil>", "<A/>", "自闭合根元素")
equal(SnippetExtractor.locate(in: "arr=[1,2] z")?.snippet ?? "<nil>", "[1,2]", "数组报文")
check(SnippetExtractor.locate(in: "只有文字") == nil, "没有候选时返回 nil")
check(SnippetExtractor.locate(in: "{没有闭合") == nil, "不完整的报文返回 nil")
check(SnippetExtractor.locate(in: "a { b <c>") == nil, "都不完整时返回 nil")

// MARK: - 性能基线（默认跳过：SWIFTNOTE_BENCH=1 swift run CoreTests）
//
// 回答「右键菜单会不会因为大文件变慢」：菜单开合只取 64 字符判型，成本与文件大小无关；
// 定位与解析都在点击之后各做一次。

if ProcessInfo.processInfo.environment["SWIFTNOTE_BENCH"] != nil {
    print("\n[性能] 右键链路成本")
    let line = "2026-11-20 12:00:00 [INFO] some log line with 192.168.5.57 and payload\n"
    let big = String(repeating: line, count: 400_000)      // ≈ 26MB
    let bigNS = big as NSString
    print("  文档规模：\(big.count) 字符 / \(big.utf16.count) UTF-16")

    let tailRange = NSRange(location: bigNS.length - 200, length: 200)
    var stamp = Date()
    for _ in 0..<1000 {
        let head = bigNS.substring(with: NSRange(location: tailRange.location, length: 64))
        _ = SnippetFormatter.detect(head)
    }
    print(String(format: "  菜单判型 ×1000（每次取 64 字符）：%.1f ms（单次 ≈ %.0f µs）",
                 Date().timeIntervalSince(stamp) * 1000, Date().timeIntervalSince(stamp) * 1_000_000 / 1000))

    stamp = Date()
    let located = SnippetExtractor.locate(in: bigNS.substring(with: tailRange))
    print(String(format: "  点击后在 200 字符选区里定位：%.2f ms（结果 %@）",
                 Date().timeIntervalSince(stamp) * 1000, located == nil ? "nil" : "命中"))

    let json1MB = "{\"k\":[" + String(repeating: "1,", count: 500_000) + "1]}"
    stamp = Date()
    _ = try? JSONService.format(json1MB)
    print(String(format: "  对照：格式化 %d 万字符 JSON：%.1f ms",
                 json1MB.count / 10_000, Date().timeIntervalSince(stamp) * 1000))
}

// MARK: - 扩展名与语法模式（txt 支持）

print("\n[语法] 扩展名优先")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.txt"), contentPrefix: "{\"a\":1}"),
      .plain, "txt 不因内容像 JSON 就改判")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.txt"), contentPrefix: "a=b"),
      .plain, "txt 不因含 = 判成 Properties")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.log"), contentPrefix: "<x/>"),
      .plain, "log 按纯文本")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.md"), contentPrefix: "{\"a\":1}"),
      .plain, "md 按纯文本")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.json"), contentPrefix: ""),
      .json, "json 扩展名优先于内容")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.cfg"), contentPrefix: "x=1"),
      .properties, "cfg 判 Properties")
equal(SyntaxMode.detect(fileURL: URL(fileURLWithPath: "/tmp/a.unknown"), contentPrefix: "{\"a\":1}"),
      .json, "未知扩展名才做内容嗅探")

// MARK: - 汇总

print("\n————————————————————")
print("共 \(checks) 项，失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)

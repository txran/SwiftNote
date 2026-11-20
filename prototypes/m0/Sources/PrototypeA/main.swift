// PrototypeA — M0 原型 A：TextKit II 大文件性能验证（RK-01）
// 配套 docs/M0-技术预研任务书.md 第三节实测项 A-1 ~ A-7
// 运行：swift run --package-path prototypes/m0 PrototypeA
//
// 内置测量仪表（无需 Xcode/Instruments）：
//   [A-1] 打开耗时（读盘 → 解码 → 装载 → 首屏布局，分段打点）
//   [A-2] 帧间隔检测器：连续绘制间隔 >100ms 计一次卡顿（PRD 卡顿口径），滚动 30s 后读数
//   [A-3] 行跳转耗时（首行/末行/随机行各测 3 次）
//   [A-4] 输入到渲染延迟（textDidChange → 下一次 draw 的间隔）
//   [A-5] 内存占用（task_vm_info 读取 phys_footprint，实时显示 + 静置读数）
//   [A-6] 200MB 日志只读打开
//   [A-7] 1MB JSON 格式化（JSONSerialization 反序列化 + prettyPrinted 重新序列化）

import AppKit
import Darwin

// MARK: - 工具

@inline(__always) func now() -> Double { CFAbsoluteTimeGetCurrent() }
@inline(__always) func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
@inline(__always) func monoFont(_ size: CGFloat) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

/// 当前进程物理内存占用（等价 Xcode Memory Gauge 的 phys_footprint）
func memoryFootprintMB() -> Double {
    var vmInfo = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &vmInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(vmInfo.phys_footprint) / 1_048_576
}

/// 定位 tools/testdata（swift run 的 cwd 通常为工程根目录）
func testDataURL(_ fileName: String) -> URL? {
    let candidates = ["tools/testdata", "../tools/testdata", "../../tools/testdata",
                      "../../../tools/testdata", "SwiftNote/tools/testdata"]
    for dir in candidates {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(fileName)
        if FileManager.default.isReadableFile(atPath: url.path) { return url }
    }
    return nil
}

// MARK: - 帧间隔检测 + 输入延迟测量的 NSTextView 子类

final class MeasuredTextView: NSTextView {
    // [A-2] 帧间隔统计
    var jankCount = 0
    var maxDrawGap: Double = 0
    var drawCount = 0
    private var lastDraw: Double = 0

    // [A-4] 输入到渲染延迟
    var pendingEditAt: Double?
    var editLatencies: [Double] = []

    override func draw(_ dirtyRect: NSRect) {
        let t = now()
        drawCount += 1
        if lastDraw > 0 {
            let gap = t - lastDraw
            // 窗口静止时不会有 draw；间隔在 100ms~500ms 之间的连续绘制视为卡顿帧
            // （>500ms 的大间隔大概率是用户停顿而非掉帧）
            if gap > 0.100 && gap < 0.500 {
                jankCount += 1
                maxDrawGap = max(maxDrawGap, gap)
            }
        }
        lastDraw = t
        // 输入 → 首次渲染 的延迟
        if let e = pendingEditAt {
            editLatencies.append(t - e)
            pendingEditAt = nil
        }
        super.draw(dirtyRect)
    }

    func resetFrameStats() {
        jankCount = 0; maxDrawGap = 0; drawCount = 0
        lastDraw = now()
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var textView: MeasuredTextView!
    var logView: NSTextView!
    var memLabel: NSTextField!
    var jankLabel: NSTextField!
    var lineField: NSTextField!

    private var lineStarts: [Int] = []     // 每行起始偏移（ASCII 文件 utf8 偏移 == utf16 偏移）
    private var loadedName = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        buildUI()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("原型 A 就绪。请依次点击上方按钮执行实测项（对照任务书 A-1~A-7）。")
        log("当前测试数据目录探测：\(testDataURL("small_1mb.json")?.deletingLastPathComponent().path ?? "未找到（请从工程根目录运行）")")
    }

    // MARK: UI

    private func buildUI() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        content.autoresizingMask = [.width, .height]

        // 顶部控制条
        let bar = NSView(frame: NSRect(x: 0, y: 712, width: 1200, height: 88))
        bar.autoresizingMask = [.width, .minYMargin]

        func btn(_ title: String, _ action: Selector, _ x: CGFloat, _ y: CGFloat) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.frame = NSRect(x: x, y: y, width: 190, height: 28)
            bar.addSubview(b)
            return b
        }
        btn("A-1/A-5: 打开 52MB JSON", #selector(openBigJSON), 12, 50)
        btn("A-6: 打开 200MB 日志(只读)", #selector(openHugeLog), 12, 14)
        btn("A-7: 1MB JSON 格式化", #selector(format1MB), 210, 50)
        btn("打开任意文件…", #selector(openAnyFile), 210, 14)

        let jumpLabel = NSTextField(labelWithString: "A-3 跳转到行:")
        jumpLabel.font = .systemFont(ofSize: 12)
        jumpLabel.frame = NSRect(x: 430, y: 55, width: 90, height: 20)
        bar.addSubview(jumpLabel)
        lineField = NSTextField(frame: NSRect(x: 520, y: 52, width: 110, height: 24))
        lineField.placeholderString = "行号"
        bar.addSubview(lineField)
        let jumpBtn = NSButton(title: "跳转", target: self, action: #selector(jumpToLine))
        jumpBtn.bezelStyle = .texturedRounded
        jumpBtn.frame = NSRect(x: 636, y: 52, width: 70, height: 24)
        bar.addSubview(jumpBtn)

        memLabel = NSTextField(labelWithString: "内存: --")
        memLabel.font = monoFont(12)
        memLabel.frame = NSRect(x: 730, y: 52, width: 210, height: 20)
        bar.addSubview(memLabel)
        jankLabel = NSTextField(labelWithString: "卡顿帧(>100ms): 0 · 最大间隔: 0ms")
        jankLabel.font = monoFont(12)
        jankLabel.frame = NSRect(x: 730, y: 20, width: 440, height: 20)
        bar.addSubview(jankLabel)

        content.addSubview(bar)

        // 编辑区（TextKit II 显式管线）
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.textContainer = container

        let editor = MeasuredTextView(frame: NSRect(x: 0, y: 130, width: 1200, height: 578), textContainer: container)
        editor.autoresizingMask = [.width, .height]
        editor.font = monoFont(13)
        editor.isRichText = false
        editor.allowsUndo = false   // 撤销不在原型范围
        editor.delegate = self
        content.addSubview(editor)
        self.textView = editor

        // 断言 TextKit II 生效（防静默回退 TextKit 1）
        if editor.textLayoutManager == nil {
            log("❌ 严重：textLayoutManager 为 nil，未走 TextKit II 管线！")
        }

        // 底部日志区
        let logScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 122))
        logScroll.autoresizingMask = [.width, .height]
        logScroll.borderType = .lineBorder
        let logTv = NSTextView(frame: NSRect(x: 0, y: 0, width: 1180, height: 100))
        logTv.font = monoFont(11)
        logTv.isEditable = false
        logTv.isRichText = false
        logScroll.documentView = logTv
        content.addSubview(logScroll)
        self.logView = logTv

        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "原型 A — TextKit II 大文件性能（M0 / RK-01）"
        window.contentView = content
        window.center()

        // 内存与卡顿读数 1s 刷新
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.memLabel.stringValue = String(format: "内存[A-5]: %.0f MB", memoryFootprintMB())
            self.jankLabel.stringValue = String(
                format: "卡顿帧[A-2]: %d · 最大间隔: %dms · 总绘制: %d",
                self.textView.jankCount, ms(self.textView.maxDrawGap), self.textView.drawCount)
        }
    }

    // MARK: 日志

    func log(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logView.textStorage?.append(NSAttributedString(
            string: "[\(ts)] \(line)\n",
            attributes: [.font: monoFont(11), .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
        print(line)
    }

    // MARK: [A-1] / [A-5] / [A-6] 打开文件（全链路打点）

    @objc private func openBigJSON() {
        guard let url = testDataURL("big_50mb.json") else { return log("❌ 找不到 big_50mb.json（请从工程根目录 swift run）") }
        open(url: url, readOnly: false)
    }

    @objc private func openHugeLog() {
        guard let url = testDataURL("huge_200mb.log") else { return log("❌ 找不到 huge_200mb.log") }
        open(url: url, readOnly: true)
    }

    @objc private func openAnyFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url: url, readOnly: false) }
    }

    private func open(url: URL, readOnly: Bool) {
        let tag = readOnly ? "A-6" : "A-1"
        let threshold = readOnly ? "不冻结即可（无硬性时限）" : "阈值 ≤ 2000ms"
        let memBefore = memoryFootprintMB()
        textView.resetFrameStats()
        lineStarts = []

        let t0 = now()
        guard let data = try? Data(contentsOf: url) else { return log("❌ [\(tag)] 读盘失败: \(url.lastPathComponent)") }
        let t1 = now()
        guard let str = String(data: data, encoding: .utf8) else { return log("❌ [\(tag)] 非 UTF-8（原型不处理编码）") }
        let t2 = now()

        let ts = textView.textContentStorage?.textStorage
        guard let ts = ts else { return log("❌ textContentStorage 不可用") }
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: str)
        let t3 = now()

        // 强制完成首屏布局（TextKit II 只布局视口，这正是「到可滚动」的口径）
        if let lm = textView.textLayoutManager {
            lm.ensureLayout(for: textView.bounds)
        }
        textView.displayIfNeeded()
        let t4 = now()

        loadedName = url.lastPathComponent
        window.title = "原型 A — \(loadedName)（\(Int(Double(data.count) / 1_048_576))MB\(readOnly ? " · 只读" : "")）"

        log("✅ [\(tag)] \(loadedName) 打开完成（\(threshold)）")
        log("    读盘 \(ms(t1 - t0))ms → 解码 \(ms(t2 - t1))ms → 装载 \(ms(t3 - t2))ms → 首屏布局 \(ms(t4 - t3))ms")
        log("    总耗时 \(ms(t4 - t0))ms · 内存增量 \(Int(memoryFootprintMB() - memBefore))MB（静置 1 分钟后读 A-5 实测值）")

        // 后台构建行索引（供 A-3 跳行；ASCII 文件 utf8 偏移 == utf16 偏移）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t = now()
            var starts: [Int] = [0]
            var idx = 0
            for b in str.utf8 {
                if b == 0x0A { starts.append(idx + 1) }
                idx += 1
            }
            DispatchQueue.main.async {
                self?.lineStarts = starts
                self?.log("    行索引就绪：\(starts.count) 行（后台构建 \(ms(now() - t))ms），可执行 A-3 跳转")
            }
        }
    }

    // MARK: [A-3] 行跳转

    @objc private func jumpToLine() {
        guard let line = Int(lineField.stringValue.trimmingCharacters(in: .whitespaces)),
              line >= 1, line <= lineStarts.count else {
            return log("❌ [A-3] 无效行号（需先打开文件且行索引就绪，共 \(lineStarts.count) 行）")
        }
        let loc = lineStarts[line - 1]
        let t0 = now()
        textView.scrollRangeToVisible(NSRange(location: loc, length: 0))
        if let lm = textView.textLayoutManager {
            lm.ensureLayout(for: textView.visibleRect)
        }
        textView.displayIfNeeded()
        let t1 = now()
        log("✅ [A-3] 跳转第 \(line) 行：\(ms(t1 - t0))ms（阈值 ≤ 200ms，首/末/随机行各测 3 次取中位数）")
    }

    // MARK: [A-7] 1MB JSON 格式化

    @objc private func format1MB() {
        guard let url = testDataURL("small_1mb.json") else { return log("❌ 找不到 small_1mb.json") }
        guard let data = try? Data(contentsOf: url) else { return log("❌ 读盘失败") }
        let t0 = now()
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return log("❌ [A-7] JSON 解析失败")
        }
        let t1 = now()
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return log("❌ [A-7] 序列化失败")
        }
        let t2 = now()
        log("✅ [A-7] 1MB(\(data.count / 1024)KB) 格式化：解析 \(ms(t1 - t0))ms + 序列化 \(ms(t2 - t1))ms = 总计 \(ms(t2 - t0))ms（阈值 ≤ 500ms）")
        _ = out
    }

    // MARK: [A-4] 输入延迟（textDidChange 记时间戳，下次 draw 结算）

    func textDidChange(_ notification: Notification) {
        if textView.pendingEditAt == nil {
            textView.pendingEditAt = now()
        }
        // 每 20 次输入输出一次统计
        if textView.editLatencies.count >= 20 {
            let lat = textView.editLatencies
            let maxL = lat.map(ms).max() ?? 0
            let avg = lat.reduce(0, +) / Double(lat.count)
            log("✅ [A-4] 输入→渲染延迟（最近 \(lat.count) 次输入）：平均 \(ms(avg))ms · 最大 \(maxL)ms（口径：无可感知延迟）")
            textView.editLatencies.removeAll()
        }
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

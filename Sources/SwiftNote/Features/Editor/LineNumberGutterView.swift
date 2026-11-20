import AppKit
import SwiftNoteKit

/// 自绘行号栏（不用 NSRulerView：其内部 NSVisualEffectView 在非全图层窗口里
/// 一旦参与绘制会把整窗内容冲掉，M1 实测结论）。
/// 按 TextKit II 的布局片段逐段绘制，只处理视口附近，不测量全文。
final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    /// 字符偏移 → 1-based 行号
    var lineNumberProvider: ((Int) -> Int)?

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private(set) var contentWidth: CGFloat = 40

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        // 父视图是 layer-backed，这里显式自持图层并声明重绘策略：
        // 否则滚动时图层缓存会残留上一帧的行号（Design D-26 的同类问题）
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateWidth(lineCount: Int) {
        // 按最大行号的实际字宽算，比「位数 × 7」更贴近真实排版
        let widest = NSAttributedString(string: String(max(1, lineCount)),
                                        attributes: [.font: numberFont]).size().width
        let width = max(36, CGFloat(max(2, widest + 18)))
        if abs(width - contentWidth) > 0.5 {
            contentWidth = width
            superview?.needsLayout = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 这里刻意不用 dynamic NSColor（controlBackgroundColor / tertiaryLabelColor）：
        // 父视图 layer-backed 时，即便套了 performAsCurrentDrawingAppearance，
        // 解析失败的动态色仍会静默变成透明 —— 表现为「draw 跑了、像素没变」（D-25）。
        // 改成按 appearance 手工取固定 RGB，和 SyntaxTheme 的做法一致。
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        drawContent(isDark: isDark)
    }

    private func drawContent(isDark: Bool) {
        let background = isDark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        let numberColor = isDark ? NSColor(srgbRed: 0.58, green: 0.58, blue: 0.58, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1)
        let separator = isDark ? NSColor(srgbRed: 0.28, green: 0.28, blue: 0.28, alpha: 1) : NSColor(srgbRed: 0.84, green: 0.84, blue: 0.84, alpha: 1)

        background.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let provider = lineNumberProvider else { return }

        let start = layoutManager.textViewportLayoutController.viewportRange?.location
            ?? layoutManager.documentRange.location
        let originInGutter = convert(NSPoint.zero, from: textView)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor
        ]

        // 必须带 .ensuresLayout：否则 TextKit 只返回「未排版」的片段，
        // layoutFragmentFrame 全是 0，几十个行号会叠在同一个 y 上（M1 实测 bug）
        //
        // 而且必须「先收集、后绘制」：在枚举闭包里直接 draw 的结果上不了屏
        // （实测枚举 19 次、draw 全部调用，屏幕上仍然一片空白）。
        var rows: [(text: String, y: CGFloat)] = []
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            // 用坐标转换而非 scrollY 反算：排版原点/内边距变化时不会错行
            let y = frame.minY + textView.textContainerOrigin.y + originInGutter.y
            if y > self.bounds.height + 40 {
                return false          // 已经越过视口底部，停止枚举
            }
            if y > -30, frame.height > 0 {
                let charOffset = layoutManager.offset(from: layoutManager.documentRange.location,
                                                      to: fragment.rangeInElement.location)
                rows.append(("\(provider(charOffset))", y))
            }
            return true
        }

        if ProcessInfo.processInfo.environment["SWIFTNOTE_GUTTER_DEBUG"] != nil {
            let ys = rows.map { Int($0.y) }
            NSLog("[gutter] rows=%d y=%d…%d bounds=%@ cw=%.1f fn=%@",
                  rows.count, ys.first ?? -1, ys.last ?? -1,
                  NSStringFromRect(bounds), contentWidth,
                  rows.first?.text ?? "-")
        }

        for row in rows {
            let label = NSAttributedString(string: row.text, attributes: attributes)
            let size = label.size()
            // 行号位数变多时 contentWidth 可能滞后一帧，夹住 x 避免被左边缘切掉
            let x = max(1, contentWidth - size.width - 7)
            label.draw(at: NSPoint(x: x, y: row.y + 1))
        }

        separator.setFill()
        NSRect(x: contentWidth - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

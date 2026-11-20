import AppKit
import SwiftNoteKit

/// 滚动条命中刻度（FR-08 / 设计 5.4 的 MatchMarkersOverlay）
///
/// 只按「命中偏移 ÷ 文本总长」画短横线，不读文本内容；
/// 命中数多于可用像素时按「每像素是否命中」聚合，避免上万条时画爆。
final class MatchMarkersView: NSView {
    static let width: CGFloat = 8

    /// 0~1 的相对位置（升序）
    var positions: [Double] = [] {
        didSet { needsDisplay = true }
    }
    var currentIndex: Int? {
        didSet { needsDisplay = true }
    }

    /// 点击刻度：回传 0~1 的相对位置
    var onClick: ((Double) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !positions.isEmpty else { return }
        let rows = Int(bounds.height)
        guard rows > 0 else { return }

        var flags = [Bool](repeating: false, count: rows)
        for position in positions {
            let row = min(rows - 1, max(0, Int(position * Double(rows - 1))))
            flags[row] = true
        }

        let color = SyntaxTheme.searchMarker
        let barWidth = bounds.width - 2
        color.setFill()

        // 连续命中的行合并成一个矩形，减少 fill 次数
        var row = 0
        while row < rows {
            guard flags[row] else { row += 1; continue }
            var end = row
            while end + 1 < rows && flags[end + 1] { end += 1 }
            let height = CGFloat(end - row) + 1
            NSRect(x: bounds.width - barWidth - 1, y: CGFloat(row),
                   width: barWidth, height: height).fill()
            row = end + 1
        }

        // 当前命中用更深的色块强调
        if let current = currentIndex, positions.indices.contains(current) {
            let row = min(rows - 1, max(0, Int(positions[current] * Double(rows - 1))))
            NSColor.controlAccentColor.setFill()
            NSRect(x: bounds.width - barWidth - 1, y: CGFloat(row) - 0.5,
                   width: barWidth, height: 2.5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.height > 0 else { return }
        onClick?(min(1, max(0, Double(point.y / bounds.height))))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

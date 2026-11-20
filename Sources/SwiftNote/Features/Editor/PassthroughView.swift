import AppKit

/// 纯背景装饰视图：不参与命中测试。
///
/// 当前行高亮带铺在文本视图**下面**（`positioned: .below`），
/// 如果不重写 `hitTest`，它会把正文的点击、拖选、双击选词全部吃掉。
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

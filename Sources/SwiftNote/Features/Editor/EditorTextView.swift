import AppKit
import SwiftNoteKit

/// 编辑器文本视图工厂：走 TextKit II 管线（设计说明书 D-1 / 5.1）
///
/// 注意（M1 实测坑）：`init(usingTextLayoutManager:)` 是 AppKit 的便捷初始化器，
/// 子类无法调用它，因此这里不做子类化，改为「工厂 + 委托」的方式配置视图；
/// 若改用 `NSTextView(frame:textContainer:)` 手工拼 TextKit II 栈，会出现
/// 「有布局片段但完全不渲染」的空视图。
enum EditorTextViewFactory {
    static func make(editable: Bool) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.font = SyntaxTheme.font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.typingAttributes = SyntaxTheme.baseAttributes
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        return textView
    }
}

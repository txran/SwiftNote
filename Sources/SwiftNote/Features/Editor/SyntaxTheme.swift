import AppKit
import SwiftNoteKit

/// 深浅主题自适应配色（设计说明书 5.2）
enum SyntaxTheme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    static let font: NSFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    static let key = dynamic(light: NSColor(srgbRed: 0.04, green: 0.32, blue: 0.65, alpha: 1),
                             dark: NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1))
    static let stringValue = dynamic(light: NSColor(srgbRed: 0.64, green: 0.13, blue: 0.09, alpha: 1),
                                     dark: NSColor(srgbRed: 0.98, green: 0.60, blue: 0.52, alpha: 1))
    static let number = dynamic(light: NSColor(srgbRed: 0.04, green: 0.52, blue: 0.35, alpha: 1),
                                dark: NSColor(srgbRed: 0.55, green: 0.90, blue: 0.70, alpha: 1))
    static let boolean = dynamic(light: NSColor(srgbRed: 0.42, green: 0.15, blue: 0.75, alpha: 1),
                                 dark: NSColor(srgbRed: 0.80, green: 0.65, blue: 1.00, alpha: 1))
    static let nullLiteral = boolean
    static let punctuation = dynamic(light: NSColor.secondaryLabelColor,
                                     dark: NSColor.secondaryLabelColor)
    static let tagName = dynamic(light: NSColor(srgbRed: 0.50, green: 0.13, blue: 0.55, alpha: 1),
                                 dark: NSColor(srgbRed: 0.92, green: 0.66, blue: 1.00, alpha: 1))
    static let attrName = dynamic(light: NSColor(srgbRed: 0.60, green: 0.35, blue: 0.02, alpha: 1),
                                  dark: NSColor(srgbRed: 0.95, green: 0.80, blue: 0.50, alpha: 1))
    static let attrValue = stringValue
    static let comment = dynamic(light: NSColor(srgbRed: 0.24, green: 0.48, blue: 0.24, alpha: 1),
                                 dark: NSColor(srgbRed: 0.55, green: 0.72, blue: 0.52, alpha: 1))
    static let cdata = dynamic(light: NSColor(srgbRed: 0.45, green: 0.35, blue: 0.25, alpha: 1),
                               dark: NSColor(srgbRed: 0.80, green: 0.70, blue: 0.55, alpha: 1))
    static let propKey = key
    /// .properties 的值占正文七成以上，用 stringValue 的砖红会整屏发红；
    /// 单独降到低饱和褐：仍与键（蓝）区分，但不抢注意力
    static let propValue = dynamic(light: NSColor(srgbRed: 0.54, green: 0.35, blue: 0.27, alpha: 1),
                                   dark: NSColor(srgbRed: 0.79, green: 0.63, blue: 0.56, alpha: 1))
    static let section = tagName

    // MARK: - 搜索高亮（FR-08，走 NSTextLayoutManager 渲染属性，不污染 textStorage）

    static let searchMatch = dynamic(light: NSColor(srgbRed: 1.00, green: 0.92, blue: 0.45, alpha: 1),
                                     dark: NSColor(srgbRed: 0.62, green: 0.48, blue: 0.05, alpha: 1))
    static let searchCurrent = dynamic(light: NSColor(srgbRed: 1.00, green: 0.63, blue: 0.25, alpha: 1),
                                       dark: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.15, alpha: 1))
    /// 滚动条刻度：命中密度色
    static let searchMarker = dynamic(light: NSColor(srgbRed: 0.55, green: 0.42, blue: 0.05, alpha: 0.85),
                                      dark: NSColor(srgbRed: 0.95, green: 0.80, blue: 0.35, alpha: 0.85))

    // MARK: - 双屏对比（FR-09）
    //
    // 三色必须「浅色主题可读」：底色浅、饱和度低，正文（textColor）压得住；
    // 行内差异用同色系加深一档，落在行底色上仍能分辨。

    static let diffInsert = dynamic(light: NSColor(srgbRed: 0.84, green: 0.95, blue: 0.86, alpha: 1),
                                    dark: NSColor(srgbRed: 0.10, green: 0.31, blue: 0.16, alpha: 1))
    static let diffDelete = dynamic(light: NSColor(srgbRed: 0.99, green: 0.87, blue: 0.88, alpha: 1),
                                    dark: NSColor(srgbRed: 0.40, green: 0.13, blue: 0.15, alpha: 1))
    static let diffChange = dynamic(light: NSColor(srgbRed: 1.00, green: 0.95, blue: 0.75, alpha: 1),
                                    dark: NSColor(srgbRed: 0.36, green: 0.29, blue: 0.06, alpha: 1))
    static let diffInline = dynamic(light: NSColor(srgbRed: 0.97, green: 0.75, blue: 0.55, alpha: 1),
                                    dark: NSColor(srgbRed: 0.62, green: 0.40, blue: 0.10, alpha: 1))
    /// 相同行不做任何着色（保持 textBackgroundColor）

    static func diffColor(for kind: DiffLineKind) -> NSColor? {
        switch kind {
        case .equal: return nil
        case .inserted: return diffInsert
        case .deleted: return diffDelete
        case .changed: return diffChange
        }
    }

    static func color(for type: TokenType) -> NSColor {
        switch type {
        case .key: return key
        case .stringValue, .attrValue, .propValue: return stringValue
        case .number: return number
        case .boolean: return boolean
        case .nullLiteral: return nullLiteral
        case .punctuation: return punctuation
        case .tagName, .section: return tagName
        case .attrName: return attrName
        case .comment: return comment
        case .cdata: return cdata
        case .propKey: return propKey
        }
    }
}

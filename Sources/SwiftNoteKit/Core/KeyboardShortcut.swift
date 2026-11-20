import Foundation

/// 快捷键的修饰键集合（Core 层不依赖 AppKit，自己在 App 层做 `NSEvent.ModifierFlags` 转换）
public struct ShortcutModifiers: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option  = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift   = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// 序列化顺序固定为 ctrl+opt+shift+cmd，保证同一组合只有一种写法
    var serializedTokens: [String] {
        var tokens: [String] = []
        if contains(.control) { tokens.append("ctrl") }
        if contains(.option) { tokens.append("opt") }
        if contains(.shift) { tokens.append("shift") }
        if contains(.command) { tokens.append("cmd") }
        return tokens
    }
}

/// 一个按键组合：`key` 是规范化后的键名（小写字母/数字/符号，或 `return`/`left` 这类具名键）
public struct KeyCombo: Equatable, Hashable {
    public var key: String
    public var modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// 持久化形式，例如 `shift+cmd+d`
    public var serialized: String {
        (modifiers.serializedTokens + [key]).joined(separator: "+")
    }

    public init?(serialized: String) {
        let parts = serialized.split(separator: "+").map(String.init)
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods: ShortcutModifiers = []
        for token in parts.dropLast() {
            switch token {
            case "ctrl": mods.insert(.control)
            case "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "cmd": mods.insert(.command)
            default: return nil
            }
        }
        self.init(key: key, modifiers: mods)
    }

    /// 设置界面与菜单里显示的样子，例如 `⇧⌘D`
    public var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.displayName(for: key)
    }

    private static let displayNames: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "␣", "delete": "⌫", "escape": "⎋",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    static func displayName(for key: String) -> String {
        if let name = displayNames[key] { return name }
        if key.count == 1 { return key.uppercased() }
        return key.uppercased()
    }

    /// 组合是否可用：必须至少带一个 ⌘/⌃/⌥，否则会抢走正常输入
    public var isAcceptable: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

/// 可自定义的快捷键动作（菜单项的稳定标识，别随便改 rawValue——它就是持久化键）
public enum ShortcutAction: String, CaseIterable {
    case newDocument
    case openDocument
    case quickOpenRecent
    case saveDocument
    case saveDocumentAs
    case reloadFromDisk
    case closeTab
    case compareFiles
    case revealInFinder
    case formatJSON
    case validateJSON
    case formatSelection
    case formatWholeDocument
    case find
    case findAndReplace
    case findNext
    case findPrevious
    case nextTab
    case previousTab
    case nextDifference
    case previousDifference
    case showSettings

    public var title: String {
        switch self {
        case .newDocument: return "新建"
        case .openDocument: return "打开…"
        case .quickOpenRecent: return "快速打开最近文件…"
        case .saveDocument: return "保存"
        case .saveDocumentAs: return "另存为…"
        case .reloadFromDisk: return "从磁盘重新加载"
        case .closeTab: return "关闭标签"
        case .compareFiles: return "对比文件…"
        case .revealInFinder: return "在 Finder 中显示"
        case .formatJSON: return "格式化 JSON"
        case .validateJSON: return "校验 JSON"
        case .formatSelection: return "格式化选中片段"
        case .formatWholeDocument: return "格式化整篇报文"
        case .find: return "查找…"
        case .findAndReplace: return "查找并替换…"
        case .findNext: return "查找下一个"
        case .findPrevious: return "查找上一个"
        case .nextTab: return "下一个标签"
        case .previousTab: return "上一个标签"
        case .nextDifference: return "下一处差异"
        case .previousDifference: return "上一处差异"
        case .showSettings: return "设置…"
        }
    }

    /// 分组，仅用于设置界面排版
    public var group: String {
        switch self {
        case .newDocument, .openDocument, .quickOpenRecent, .saveDocument, .saveDocumentAs,
             .reloadFromDisk, .closeTab, .compareFiles, .revealInFinder:
            return "文件"
        case .formatJSON, .validateJSON, .formatSelection, .formatWholeDocument:
            return "格式"
        case .find, .findAndReplace, .findNext, .findPrevious:
            return "查找"
        case .nextTab, .previousTab:
            return "标签"
        case .nextDifference, .previousDifference:
            return "对比"
        case .showSettings:
            return "应用"
        }
    }

    public var defaultCombo: KeyCombo? {
        switch self {
        case .newDocument: return KeyCombo(key: "n", modifiers: [.command])
        case .openDocument: return KeyCombo(key: "o", modifiers: [.command])
        case .quickOpenRecent: return KeyCombo(key: "o", modifiers: [.command, .shift])
        case .saveDocument: return KeyCombo(key: "s", modifiers: [.command])
        case .saveDocumentAs: return KeyCombo(key: "s", modifiers: [.command, .shift])
        case .reloadFromDisk: return KeyCombo(key: "r", modifiers: [.command])
        case .closeTab: return KeyCombo(key: "w", modifiers: [.command])
        case .compareFiles: return KeyCombo(key: "d", modifiers: [.command, .shift])
        case .revealInFinder: return nil
        case .formatJSON: return KeyCombo(key: "f", modifiers: [.command, .shift])
        case .validateJSON: return nil
        // ⌘⌥F 已被「查找并替换」占用，这里不设默认键位：右键菜单是主入口
        case .formatSelection: return nil
        case .formatWholeDocument: return nil
        case .find: return KeyCombo(key: "f", modifiers: [.command])
        case .findAndReplace: return KeyCombo(key: "f", modifiers: [.command, .option])
        case .findNext: return KeyCombo(key: "g", modifiers: [.command])
        case .findPrevious: return KeyCombo(key: "g", modifiers: [.command, .shift])
        case .nextTab: return KeyCombo(key: "]", modifiers: [.command, .shift])
        case .previousTab: return KeyCombo(key: "[", modifiers: [.command, .shift])
        // 不用 ⌘↓/⌘↑：那是 NSTextView 的「到文末/文首」，抢走会让编辑区失去通用按键
        case .nextDifference: return KeyCombo(key: "down", modifiers: [.command, .option])
        case .previousDifference: return KeyCombo(key: "up", modifiers: [.command, .option])
        case .showSettings: return KeyCombo(key: ",", modifiers: [.command])
        }
    }
}

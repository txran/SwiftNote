import AppKit
import SwiftNoteKit

/// Core 层的 `KeyCombo` 与 AppKit 之间的桥：只做格式转换，不含业务判断。
///
/// 有两条容易踩的规矩：
/// 1. `NSMenuItem.keyEquivalent` 要「**未按 shift 的字符** + shift 掩码」，
///    所以从事件取键位必须用 `characters(byApplyingModifiers: [])`，
///    不能用 `charactersIgnoringModifiers`（后者会把 ⇧] 变成 `}`）。
/// 2. 具名键（回车/方向键/F 键）在菜单里要用 AppKit 的功能键字符，不能写 `"return"`。
extension KeyCombo {

    var nsModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// 菜单里可直接使用的 keyEquivalent
    var menuKeyEquivalent: String {
        switch key {
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case "escape": return "\u{1b}"
        case "left": return Self.functionKey(NSLeftArrowFunctionKey)
        case "right": return Self.functionKey(NSRightArrowFunctionKey)
        case "up": return Self.functionKey(NSUpArrowFunctionKey)
        case "down": return Self.functionKey(NSDownArrowFunctionKey)
        case "home": return Self.functionKey(NSHomeFunctionKey)
        case "end": return Self.functionKey(NSEndFunctionKey)
        case "pageup": return Self.functionKey(NSPageUpFunctionKey)
        case "pagedown": return Self.functionKey(NSPageDownFunctionKey)
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) {
                return Self.functionKey(NSF1FunctionKey + n - 1)
            }
            return key
        }
    }

    private static func functionKey(_ scalar: Int) -> String {
        guard let value = UnicodeScalar(UInt32(scalar)) else { return "" }
        return String(Character(value))
    }

    /// 从按键事件解析组合；只带 shift（或没有任何 ⌘/⌃/⌥）时返回 nil
    static func from(event: NSEvent) -> KeyCombo? {
        let modifiers = modifiers(from: event.modifierFlags)
        let key: String
        if let named = namedKeys[event.keyCode] {
            key = named
        } else if let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty {
            key = chars.lowercased()
        } else {
            return nil
        }
        let combo = KeyCombo(key: key, modifiers: modifiers)
        return combo.isAcceptable ? combo : nil
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    private static let namedKeys: [UInt16: String] = [
        36: "return", 76: "return",          // Return / 小键盘 Enter
        48: "tab", 49: "space",
        51: "delete", 117: "delete",         // Delete / Forward Delete
        53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
}

import Foundation

/// 偏好设置单一入口（设计说明书 4.4）。只存用户选择，不存会话状态。
public final class AppSettings {
    public static let shared = AppSettings()
    /// 偏好变更广播（maxTabRows 变更需触发标签栏重排，不重启生效）
    public static let didChangeNotification = Notification.Name("SwiftNote.AppSettingsDidChange")
    /// 变更项在 userInfo 中的键
    public static let changedKeysKey = "changedKeys"

    private let defaults: UserDefaults

    public enum Key {
        public static let maxTabRows = "maxTabRows"
        public static let minTabWidth = "minTabWidth"
        public static let tabInsertsSpaces = "tabInsertsSpaces"
        public static let largeFileThresholdMB = "largeFileThresholdMB"
        public static let draftSnapshotDelaySec = "draftSnapshotDelaySec"
        public static let searchIsRegex = "searchIsRegex"
        public static let searchIsCaseSensitive = "searchIsCaseSensitive"
        public static let searchIsWholeWord = "searchIsWholeWord"
        public static let wrapLines = "wrapLines"
        public static let highlightCurrentLine = "highlightCurrentLine"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 标签栏

    /// 标签行数上限：1~6，默认 5
    public var maxTabRows: Int {
        get { clampedInt(Key.maxTabRows, def: 5, range: 1...6) }
        set { setInt(newValue, key: Key.maxTabRows, def: 5, range: 1...6) }
    }

    /// 标签最小宽度（M0 校准项 P-3，默认 160）
    public var minTabWidth: CGFloat {
        get { CGFloat(clampedDouble(Key.minTabWidth, def: 160, range: 120...220)) }
        set { setDouble(Double(newValue), key: Key.minTabWidth, def: 160, range: 120...220) }
    }

    // MARK: - 编辑

    public var tabInsertsSpaces: Bool {
        get {
            guard defaults.object(forKey: Key.tabInsertsSpaces) != nil else { return true }
            return defaults.bool(forKey: Key.tabInsertsSpaces)
        }
        set {
            defaults.set(newValue, forKey: Key.tabInsertsSpaces)
            postChange([Key.tabInsertsSpaces])
        }
    }

    /// 自动换行（FR-10 必须支持开关），默认开
    public var wrapLines: Bool {
        get {
            guard defaults.object(forKey: Key.wrapLines) != nil else { return true }
            return defaults.bool(forKey: Key.wrapLines)
        }
        set {
            guard newValue != wrapLines else { return }
            defaults.set(newValue, forKey: Key.wrapLines)
            postChange([Key.wrapLines])
        }
    }

    /// 当前行高亮，默认开
    public var highlightCurrentLine: Bool {
        get {
            guard defaults.object(forKey: Key.highlightCurrentLine) != nil else { return true }
            return defaults.bool(forKey: Key.highlightCurrentLine)
        }
        set {
            guard newValue != highlightCurrentLine else { return }
            defaults.set(newValue, forKey: Key.highlightCurrentLine)
            postChange([Key.highlightCurrentLine])
        }
    }

    // MARK: - 搜索（FR-08：记忆上次的开关状态）
    public var searchIsRegex: Bool {
        get { defaults.bool(forKey: Key.searchIsRegex) }
        set {
            guard newValue != defaults.bool(forKey: Key.searchIsRegex) else { return }
            defaults.set(newValue, forKey: Key.searchIsRegex)
            postChange([Key.searchIsRegex])
        }
    }

    public var searchIsCaseSensitive: Bool {
        get { defaults.bool(forKey: Key.searchIsCaseSensitive) }
        set {
            guard newValue != defaults.bool(forKey: Key.searchIsCaseSensitive) else { return }
            defaults.set(newValue, forKey: Key.searchIsCaseSensitive)
            postChange([Key.searchIsCaseSensitive])
        }
    }

    public var searchIsWholeWord: Bool {
        get { defaults.bool(forKey: Key.searchIsWholeWord) }
        set {
            guard newValue != defaults.bool(forKey: Key.searchIsWholeWord) else { return }
            defaults.set(newValue, forKey: Key.searchIsWholeWord)
            postChange([Key.searchIsWholeWord])
        }
    }

    // MARK: - 大文件与会话


    /// 大文件只读阈值的可调范围（1MB ~ 2GB）
    public static let largeFileThresholdRange = 1...2048

    /// 大文件只读阈值（P-6，默认 10MB）。
    /// 超过该体积的文件以「纯文本模式」打开：只读、不排版、不折行，
    /// 只绘制可见行，因此打开百万行日志也不卡。
    ///
    /// 下限给到 1MB（有人不想让 3MB 的日志进 TextKit），上限给到 2GB。
    /// **setter 主动钳制**：这个值可以直接在设置里输入，写 5000 应该变成 2048，
    /// 而不是按「越界回落默认」把他填的 5000 悄悄改成 10（其余数值设置仍走回落默认）
    public var largeFileThresholdMB: Int {
        get { clampedInt(Key.largeFileThresholdMB, def: 10, range: Self.largeFileThresholdRange) }
        set {
            let range = Self.largeFileThresholdRange
            let value = min(max(newValue, range.lowerBound), range.upperBound)
            setInt(value, key: Key.largeFileThresholdMB, def: 10, range: range)
        }
    }

    /// 编辑停止后写草稿快照的延迟（秒）
    public var draftSnapshotDelaySec: Double {
        get { clampedDouble(Key.draftSnapshotDelaySec, def: 2.0, range: 0.5...10) }
        set { setDouble(newValue, key: Key.draftSnapshotDelaySec, def: 2.0, range: 0.5...10) }
    }

    public var largeFileThresholdBytes: Int64 { Int64(largeFileThresholdMB) * 1024 * 1024 }

    // MARK: - 快捷键（FR-13 自定义快捷键）

    /// 快捷键持久化键统一前缀：`shortcut.<action rawValue>`，值为 `KeyCombo.serialized`
    public static let shortcutKeyPrefix = "shortcut."

    /// 取某动作当前生效的组合：未改过 → 默认值；显式清空过 → nil
    public func shortcut(_ action: ShortcutAction) -> KeyCombo? {
        let key = Self.shortcutKeyPrefix + action.rawValue
        guard let raw = defaults.string(forKey: key) else { return action.defaultCombo }
        if raw.isEmpty { return nil }
        return KeyCombo(serialized: raw) ?? action.defaultCombo
    }

    /// 写入组合；传 nil 表示清除该动作的快捷键
    public func setShortcut(_ combo: KeyCombo?, for action: ShortcutAction) {
        let key = Self.shortcutKeyPrefix + action.rawValue
        defaults.set(combo?.serialized ?? "", forKey: key)
        postChange([key])
    }

    /// 是否被用户改过（设置界面用来标「已自定义」）
    public func isShortcutCustomized(_ action: ShortcutAction) -> Bool {
        defaults.string(forKey: Self.shortcutKeyPrefix + action.rawValue) != nil
    }

    /// 查冲突：返回已经占用该组合的另一个动作
    public func conflictingAction(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && shortcut($0) == combo }
    }

    /// 变更通知里是否含快捷键项（菜单需要重建）
    public static func containsShortcutChange(_ keys: [String]) -> Bool {
        keys.contains { $0.hasPrefix(shortcutKeyPrefix) }
    }

    // MARK: - 恢复默认（设置窗口「恢复默认值」）

    public func resetToDefaults() {
        let keys = [Key.maxTabRows, Key.minTabWidth, Key.tabInsertsSpaces,
                    Key.largeFileThresholdMB, Key.draftSnapshotDelaySec,
                    Key.searchIsRegex, Key.searchIsCaseSensitive, Key.searchIsWholeWord,
                    Key.wrapLines, Key.highlightCurrentLine]
        for key in keys { defaults.removeObject(forKey: key) }
        var changed = keys
        // 快捷键是动态键，按前缀扫一遍一起清掉
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.shortcutKeyPrefix) {
            defaults.removeObject(forKey: key)
            changed.append(key)
        }
        postChange(changed)
    }

    // MARK: - 内部

    private func clampedInt(_ key: String, def: Int, range: ClosedRange<Int>) -> Int {
        guard defaults.object(forKey: key) != nil else { return def }
        let raw = defaults.integer(forKey: key)
        if range.contains(raw) { return raw }
        AppLogger.warn("偏好 \(key)=\(raw) 越界 \(range)，回落默认 \(def)")
        return def
    }

    private func clampedDouble(_ key: String, def: Double, range: ClosedRange<Double>) -> Double {
        guard defaults.object(forKey: key) != nil else { return def }
        let raw = defaults.double(forKey: key)
        if range.contains(raw) { return raw }
        AppLogger.warn("偏好 \(key)=\(raw) 越界 \(range)，回落默认 \(def)")
        return def
    }

    private func setInt(_ value: Int, key: String, def: Int, range: ClosedRange<Int>) {
        let clamped = range.contains(value) ? value : def
        guard clamped != clampedInt(key, def: def, range: range) else { return }
        defaults.set(clamped, forKey: key)
        postChange([key])
    }

    private func setDouble(_ value: Double, key: String, def: Double, range: ClosedRange<Double>) {
        let clamped = range.contains(value) ? value : def
        defaults.set(clamped, forKey: key)
        postChange([key])
    }

    private func postChange(_ keys: [String]) {
        NotificationCenter.default.post(name: Self.didChangeNotification,
                                        object: self,
                                        userInfo: [Self.changedKeysKey: keys])
    }
}

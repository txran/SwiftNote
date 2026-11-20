import Foundation

/// 日志（轻量，统一前缀，便于 Console.app 过滤）
public enum AppLogger {
    public static func info(_ message: String) { emit("INFO", message) }
    public static func warn(_ message: String) { emit("WARN", message) }
    public static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        NSLog("[SwiftNote][\(level)] %@", message)
    }
}

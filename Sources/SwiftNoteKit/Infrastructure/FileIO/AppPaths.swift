import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SwiftNote", isDirectory: true)
    }

    public static var draftsDirectory: URL {
        supportDirectory.appendingPathComponent("drafts", isDirectory: true)
    }

    public static var sessionFile: URL {
        supportDirectory.appendingPathComponent("session.json")
    }

    public static func ensureDirectories() {
        for dir in [supportDirectory, draftsDirectory] {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}

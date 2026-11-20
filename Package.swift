// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftNote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SwiftNote", targets: ["SwiftNote"]),
        .library(name: "SwiftNoteKit", targets: ["SwiftNoteKit"])
    ],
    targets: [
        // Core + Infrastructure：零 UI 依赖，可单元测试
        .target(
            name: "SwiftNoteKit",
            path: "Sources/SwiftNoteKit"
        ),
        // App + Features：纯 AppKit（本机 CLT 无 SwiftUI 宏插件，见设计说明书 D-10）
        .executableTarget(
            name: "SwiftNote",
            dependencies: ["SwiftNoteKit"],
            path: "Sources/SwiftNote"
        ),
        // 本机只有 CLT（XCTest 不可用），用自带断言的测试可执行文件代替测试目标
        .executableTarget(
            name: "CoreTests",
            dependencies: ["SwiftNoteKit"],
            path: "Tests/CoreTests"
        )
    ]
)

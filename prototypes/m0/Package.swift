// swift-tools-version:6.0
// M0 技术预研原型包（配套 docs/M0-技术预研任务书.md）
// 运行方式：swift run --package-path prototypes/m0 PrototypeA / PrototypeB
import PackageDescription

let package = Package(
    name: "m0-prototypes",
    targets: [
        // 原型 A：TextKit II 大文件性能（验证 RK-01）
        .executableTarget(
            name: "PrototypeA",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 原型 B：多行标签自绘控件（验证 RK-02）
        .executableTarget(
            name: "PrototypeB",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

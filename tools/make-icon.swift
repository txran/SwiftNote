#!/usr/bin/env swift
// 生成 SwiftNote 图标（AppIcon.iconset 与 AppIcon.icns 的母版）
//
// 设计语言：与姊妹项目 SwiftDown 同族（家族一致性）
//   - 全出血 1024 方形画布：macOS 11+ 由系统套 squircle 蒙版；
//     自带透明边距 + 自画圆角会被系统二次裁剪，Dock 里显得比邻居小一圈
//   - 对角线米白纸感渐变 #FDFBF6 → #E8DEC9
//   - 内缩 62px 的 n=5 超椭圆（squircle）描边 #E3B29A，宽 8
//   - 圆体字母组合 "Sn" #BE3F19（Arial Rounded MT Bold）
//   - 小尺寸（≤64px）字标放大 ~9%，笔画更耐缩
//
// 为什么不用 Assets.car：本机只有 CLT，没有 actool 资源编译流程，
// 图标必须走传统 .icns（见 mac应用开发注意事项 P-03）。
// 用法: swift tools/make-icon.swift <输出目录>
//
// 注意：这里显式创建 NSBitmapImageRep + NSGraphicsContext，不用 NSImage.lockFocus()。
// 后者依赖 window server 上下文，无 GUI 的 CLI 进程里 tiffRepresentation 会返回 nil。

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "build/icon")

let fm = FileManager.default
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// ── 设计 token（与 SwiftDown Assets/icon.svg 逐项对齐）─────────────────────
let bgTop = NSColor(srgbRed: 0xFD / 255.0, green: 0xFB / 255.0, blue: 0xF6 / 255.0, alpha: 1)
let bgBottom = NSColor(srgbRed: 0xE8 / 255.0, green: 0xDE / 255.0, blue: 0xC9 / 255.0, alpha: 1)
let borderColor = NSColor(srgbRed: 0xE3 / 255.0, green: 0xB2 / 255.0, blue: 0x9A / 255.0, alpha: 1)
let markColor = NSColor(srgbRed: 0xBE / 255.0, green: 0x3F / 255.0, blue: 0x19 / 255.0, alpha: 1)

// 几何（以 1024 母版为基准，按 scale 缩放）
let inset: CGFloat = 62        // 描边内缩
let squircleN: Double = 5.0    // 超椭圆指数（从 SwiftDown 描边路径拟合：误差 < 1e-3）
let halfSide: CGFloat = 450    // 1024/2 - 62
let strokeW: CGFloat = 8
let markSize: CGFloat = 450    // "Sn" 字号（SwiftDown "Md"=414；"Sn" 更窄，加大补偿）
let smallBoost: CGFloat = 1.09 // 小尺寸字标放大系数（SwiftDown: 449/414）

func makeBitmap(_ px: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("无法创建 \(px)×\(px) 位图")
    }
    return rep
}

/// n=5 超椭圆路径（连续曲率圆角，比 NSBezierPath 圆角矩形更贴近系统 squircle）
func squirclePath(center: NSPoint, half: CGFloat, n: Double, segments: Int = 96) -> NSBezierPath {
    let path = NSBezierPath()
    let exp = 2.0 / n
    var first = true
    for i in 0..<segments {
        let t = Double(i) / Double(segments) * 2 * Double.pi
        let ct = cos(t), st = sin(t)
        let x = center.x + half * CGFloat(Foundation.copysign(pow(abs(ct), exp), ct))
        let y = center.y + half * CGFloat(Foundation.copysign(pow(abs(st), exp), st))
        if first { path.move(to: NSPoint(x: x, y: y)); first = false }
        else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// 在指定位图上绘制图标
/// - Parameter small: 小尺寸精简稿（字标放大，笔画更耐缩）
func drawIcon(into rep: NSBitmapImageRep, small: Bool) {
    let side = CGFloat(rep.pixelsWide)
    let scale = side / 1024.0

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    defer { NSGraphicsContext.restoreGraphicsState() }

    // 1. 全出血渐变底：左上 → 右下对角（SwiftDown: (0.15,0)→(0.85,1)，约 -55°）
    let full = NSRect(x: 0, y: 0, width: side, height: side)
    NSGradient(starting: bgTop, ending: bgBottom)?.draw(in: full, angle: -55)

    // 2. 超椭圆描边
    let border = squirclePath(center: NSPoint(x: side / 2, y: side / 2),
                              half: halfSide * scale, n: squircleN)
    borderColor.setStroke()
    border.lineWidth = strokeW * scale
    border.stroke()

    // 3. 字标 "Sn"（光学居中：基线 = 中心 + capHeight/2，S/n 均无降部）
    //    用 CoreText 以基线原点绘制——draw(at:) 在非翻转上下文里行盒方向不可靠
    let fontSize = markSize * scale * (small ? smallBoost : 1)
    guard let font = NSFont(name: "ArialRoundedMTBold", size: fontSize) else {
        fatalError("缺少字体 ArialRoundedMTBold（macOS 系统自带，请检查系统字体）")
    }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: markColor
    ]
    let attrText = CFAttributedStringCreate(nil, "Sn" as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrText)

    let lineW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let baseline = side / 2 - font.capHeight / 2 - 6 * scale // 字形在基线上方；-6px 光学修正
    ctx.cgContext.textPosition = CGPoint(x: (side - lineW) / 2, y: baseline)
    CTLineDraw(line, ctx.cgContext)
}

// iconutil 要求的固定尺寸清单（1x / 2x）；≤64px 用精简稿
let sizes: [(name: String, px: Int, small: Bool)] = [
    ("icon_16x16.png", 16, true), ("icon_16x16@2x.png", 32, true),
    ("icon_32x32.png", 32, true), ("icon_32x32@2x.png", 64, true),
    ("icon_128x128.png", 128, false), ("icon_128x128@2x.png", 256, false),
    ("icon_256x256.png", 256, false), ("icon_256x256@2x.png", 512, false),
    ("icon_512x512.png", 512, false), ("icon_512x512@2x.png", 1024, false)
]

for item in sizes {
    let rep = makeBitmap(item.px)
    drawIcon(into: rep, small: item.small)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败 \(item.name)")
    }
    try! png.write(to: iconset.appendingPathComponent(item.name))
}

print(iconset.path)

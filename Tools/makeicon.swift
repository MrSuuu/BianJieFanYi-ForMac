import CoreGraphics
import CoreText
import Foundation
import ImageIO

// 生成 AppIcon.iconset：渐变圆角方块 + 白色「译」字
//
// 刻意只用 CoreGraphics / CoreText，不用 NSImage.lockFocus()：
// 后者依赖窗口服务（NSGraphicsContext.current 在无 GUI 会话里是 nil），
// 而 CGContext 自己开一块内存画就行，任何环境都能跑。
//
// 用法: swiftc makeicon.swift -o makeicon && ./makeicon <输出目录>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(pixel px: Int) -> CGImage? {
    let s = CGFloat(px)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let ctx = CGContext(data: nil,
                              width: px,
                              height: px,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // 注意：CGContext 原点在左下角，跟 AppKit 相反
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // 背板
    let inset = s * 0.05
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.23
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    let colors = [
        CGColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),
        CGColor(red: 0.48, green: 0.31, blue: 0.92, alpha: 1),
    ]
    guard let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1])
    else { return nil }

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.minX, y: rect.minY),
                           end: CGPoint(x: rect.maxX, y: rect.maxY),
                           options: [])
    ctx.restoreGState()

    // 汉字（CoreText 本身就是左下原点，跟 CGContext 一致，不用翻转）
    // 用 CoreText 的属性键（kCTFontAttributeName 等），不依赖 AppKit 给 NSAttributedString 加的扩展
    let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, s * 0.52, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ]
    let attrStr = CFAttributedStringCreate(nil, "译" as CFString, attrs as CFDictionary)
    let line = CTLineCreateWithAttributedString(attrStr!)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    ctx.textPosition = CGPoint(x: (s - lineWidth) / 2,
                               y: (s - (ascent + descent)) / 2 + descent)
    CTLineDraw(line, ctx)

    return ctx.makeImage()
}

// iconset 命名规范：icon_<pt>x<pt>.png 与 icon_<pt>x<pt>@2x.png
let specs: [(pt: Int, px: Int, retina: Bool)] = [
    (16, 16, false), (16, 32, true),
    (32, 32, false), (32, 64, true),
    (128, 128, false), (128, 256, true),
    (256, 256, false), (256, 512, true),
    (512, 512, false), (512, 1024, true),
]

var ok = 0
for spec in specs {
    guard let cg = drawIcon(pixel: spec.px) else {
        print("  ✗ \(spec.px)px 渲染失败")
        continue
    }
    let name = spec.retina ? "icon_\(spec.pt)x\(spec.pt)@2x.png" : "icon_\(spec.pt)x\(spec.pt).png"
    let url = URL(fileURLWithPath: "\(outDir)/\(name)")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        continue
    }
    CGImageDestinationAddImage(dest, cg, nil)
    if CGImageDestinationFinalize(dest) { ok += 1 }
}

print("生成 \(ok)/\(specs.count) 张 → \(outDir)")
exit(ok == specs.count ? 0 : 1)

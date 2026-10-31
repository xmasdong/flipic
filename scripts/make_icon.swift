// swift scripts/make_icon.swift <iconset目录> [商店图标输出路径]
// 生成 Photoview 应用图标的各尺寸 PNG（设计：深色画布上堆叠的照片卡片，呼应「翻文件夹看图」）
import CoreGraphics
import Foundation
import ImageIO

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"

func draw(_ ctx: CGContext) {
    let w: CGFloat = 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // 画布：深色垂直渐变，铺满全画布（圆角由系统套壳裁切）
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: w, height: w))
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.155, green: 0.165, blue: 0.20, alpha: 1),
        CGColor(red: 0.055, green: 0.06, blue: 0.085, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: w), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    func card(_ cx: CGFloat, _ cy: CGFloat, _ cw: CGFloat, _ ch: CGFloat,
              _ angle: CGFloat, _ fill: CGColor, shadow: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: angle)
        let r = CGRect(x: -cw / 2, y: -ch / 2, width: cw, height: ch)
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 42,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 后面两张斜靠的卡片（露出边缘，营造「一摞照片」的景深）
    card(352, 618, 430, 345, 0.11, CGColor(red: 0.585, green: 0.595, blue: 0.65, alpha: 1), shadow: false)
    card(672, 622, 430, 345, -0.10, CGColor(red: 0.70, green: 0.71, blue: 0.76, alpha: 1), shadow: false)

    // 正面主卡片：白边 + 日落风景照
    let cw: CGFloat = 668, ch: CGFloat = 520
    let ccx: CGFloat = 512, ccy: CGFloat = 470
    card(ccx, ccy, cw, ch, 0, CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1), shadow: true)

    let photo = CGRect(x: ccx - cw / 2 + 26, y: ccy - ch / 2 + 26, width: cw - 52, height: ch - 52)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: photo, cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.clip()

    let horizon = photo.minY + photo.height * 0.66
    // 天空：紫夜 → 玫瑰 → 琥珀
    let sky = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.16, green: 0.15, blue: 0.33, alpha: 1),
        CGColor(red: 0.62, green: 0.30, blue: 0.44, alpha: 1),
        CGColor(red: 0.96, green: 0.66, blue: 0.36, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: horizon), options: [])

    // 太阳 + 光晕
    let sunX = photo.minX + photo.width * 0.66
    let sunY = horizon + photo.height * 0.16
    let sunR: CGFloat = photo.width * 0.085
    for (k, a) in [(3.1, 0.06), (2.1, 0.10), (1.45, 0.16)] {
        ctx.setFillColor(CGColor(red: 1.0, green: 0.85, blue: 0.55, alpha: a))
        ctx.fillEllipse(in: CGRect(x: sunX - sunR * k, y: sunY - sunR * k, width: sunR * 2 * k, height: sunR * 2 * k))
    }
    ctx.setFillColor(CGColor(red: 1.0, green: 0.90, blue: 0.68, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2))

    // 两层山：远山李子色、近山深蓝紫
    func ridge(_ baseY: CGFloat, _ peak: CGFloat, _ c: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: photo.minX, y: baseY))
        p.addLine(to: CGPoint(x: photo.minX + photo.width * 0.22, y: baseY + peak))
        p.addLine(to: CGPoint(x: photo.minX + photo.width * 0.46, y: baseY + peak * 0.35))
        p.addLine(to: CGPoint(x: photo.minX + photo.width * 0.68, y: baseY + peak * 0.75))
        p.addLine(to: CGPoint(x: photo.maxX, y: baseY + peak * 0.28))
        p.addLine(to: CGPoint(x: photo.maxX, y: baseY - 200))
        p.addLine(to: CGPoint(x: photo.minX, y: baseY - 200))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    ridge(horizon + photo.height * 0.02, photo.height * 0.16, CGColor(red: 0.44, green: 0.28, blue: 0.46, alpha: 1))
    ridge(horizon - photo.height * 0.02, photo.height * 0.10, CGColor(red: 0.22, green: 0.18, blue: 0.33, alpha: 1))

    // 水面 + 地平线余晖
    ctx.setFillColor(CGColor(red: 0.14, green: 0.12, blue: 0.24, alpha: 1))
    ctx.fill(CGRect(x: photo.minX, y: photo.minY, width: photo.width, height: horizon - photo.minY))
    let afterglow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.96, green: 0.62, blue: 0.38, alpha: 0.38),
        CGColor(red: 0.96, green: 0.62, blue: 0.38, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(afterglow, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: horizon - photo.height * 0.16), options: [])

    // 太阳倒影：一串渐短的横向光斑（避免生硬的光柱）
    let streaks: [(CGFloat, CGFloat, CGFloat)] = [
        (0.05, 225, 0.55), (0.115, 165, 0.42), (0.19, 115, 0.30),
        (0.28, 74, 0.20), (0.38, 44, 0.13), (0.50, 24, 0.08),
    ]
    for (dy, halfW, a) in streaks {
        let y = horizon - photo.height * dy
        let r = CGRect(x: sunX - halfW, y: y - 6, width: halfW * 2, height: 12)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(CGColor(red: 1.0, green: 0.80, blue: 0.42, alpha: a))
        ctx.fillPath()
    }
    // 水面细纹（全宽，极淡）
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
    ctx.setLineWidth(3)
    for dy in [0.33, 0.56] {
        let y = photo.minY + (horizon - photo.minY) * dy
        ctx.addLines(between: [CGPoint(x: photo.minX + 30, y: y), CGPoint(x: photo.maxX - 30, y: y)])
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)
    draw(ctx)
    return ctx.makeImage()!
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in specs {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("cannot create destination for \(name)")
    }
    CGImageDestinationAddImage(dest, render(size), nil)
    CGImageDestinationFinalize(dest)
}

// App Store 提交用 1024 图标：铺满画布、无 alpha 通道
if CommandLine.arguments.count > 2 {
    let storePath = CommandLine.arguments[2]
    let storeDir = (storePath as NSString).deletingLastPathComponent
    try? fm.createDirectory(atPath: storeDir, withIntermediateDirectories: true)
    let opaque = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(opaque)
    if let img = opaque.makeImage(),
       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: storePath) as CFURL,
                                                  "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("appstore icon written to \(storePath)")
    }
}
print("iconset written to \(outDir)")

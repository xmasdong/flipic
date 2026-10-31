// swift scripts/make_screenshots.swift <输出目录>
// 生成 App Store 截图（2880×1800，无 alpha，忠实现 Photoview 实际界面布局）
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let outBase = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppStore/screenshots/2880x1800"
let lang = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "zh-Hans"
let outDir = "\(outBase)/\(lang == "en" ? "en-US" : "zh-Hans")"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let STR: [String: String] = lang == "en" ? [
    "exif.title": "Photo Info", "exif.camera": "Camera", "exif.lens": "Lens",
    "exif.params": "Exposure", "exif.date": "Date Taken", "exif.size": "Dimensions",
    "exif.file": "File",
    "slideshow.hint": "Slideshow playing · 3s per photo",
    "exp.title": "Export Compressed Image", "exp.name": "01-mountain-compressed.jpg",
    "exp.format": "Format", "exp.quality": "Quality 85", "exp.estimate": "Estimated size: 358 KB",
    "exp.cancel": "Cancel", "exp.go": "Export",
] : [
    "exif.title": "照片信息", "exif.camera": "相机", "exif.lens": "镜头",
    "exif.params": "拍摄参数", "exif.date": "拍摄时间", "exif.size": "尺寸",
    "exif.file": "文件",
    "slideshow.hint": "幻灯片放映中 · 每张 3 秒",
    "exp.title": "导出压缩图片", "exp.name": "01-mountain-compressed.jpg",
    "exp.format": "格式", "exp.quality": "质量 85", "exp.estimate": "预计大小： 358 KB",
    "exp.cancel": "取消", "exp.go": "导出",
]
func S(_ k: String) -> String { STR[k]! }

let W: CGFloat = 2880, H: CGFloat = 1800
let STRIP: CGFloat = 152
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - 场景照片渲染

func scene(_ w: Int, _ h: Int, hue: CGFloat, night: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let fw = CGFloat(w), fh = CGFloat(h)
    // 天空
    let top = night
        ? [CGColor(srgbRed: 0.03, green: 0.04, blue: 0.10, alpha: 1), CGColor(srgbRed: 0.10, green: 0.09, blue: 0.22, alpha: 1)]
        : [NSColor(hue: hue, saturation: 0.45, brightness: 0.92, alpha: 1).cgColor,
           NSColor(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.98, alpha: 1).cgColor]
    ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: top as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: fh), end: CGPoint(x: 0, y: fh * 0.45), options: [])
    ctx.fill(CGRect(x: 0, y: 0, width: fw, height: fh * 0.55))
    // 太阳 / 月亮
    let sunY = fh * (night ? 0.72 : 0.62)
    let sunColor = night ? CGColor(srgbRed: 0.92, green: 0.94, blue: 1.0, alpha: 1)
                         : CGColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1)
    ctx.setFillColor(night ? sunColor : CGColor(srgbRed: 1.0, green: 0.85, blue: 0.5, alpha: 0.35))
    ctx.fillEllipse(in: CGRect(x: fw * 0.68 - fh * 0.13, y: sunY - fh * 0.13, width: fh * 0.26, height: fh * 0.26))
    ctx.setFillColor(sunColor)
    ctx.fillEllipse(in: CGRect(x: fw * 0.68 - fh * 0.06, y: sunY - fh * 0.06, width: fh * 0.12, height: fh * 0.12))
    if night {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        for (dx, dy, s) in [(0.12, 0.85, 5), (0.3, 0.9, 3), (0.45, 0.8, 4), (0.85, 0.88, 3), (0.6, 0.92, 2)] {
            ctx.fillEllipse(in: CGRect(x: fw * dx, y: fh * dy, width: CGFloat(s), height: CGFloat(s)))
        }
    }
    // 远山 / 近山 / 地面（保持足够亮度，避免大面积暗部）
    func mountains(_ baseY: CGFloat, _ peak: CGFloat, _ c: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: baseY))
        p.addLine(to: CGPoint(x: fw * 0.16, y: baseY + peak))
        p.addLine(to: CGPoint(x: fw * 0.34, y: baseY + peak * 0.42))
        p.addLine(to: CGPoint(x: fw * 0.55, y: baseY + peak * 0.85))
        p.addLine(to: CGPoint(x: fw * 0.74, y: baseY + peak * 0.3))
        p.addLine(to: CGPoint(x: fw * 0.9, y: baseY + peak * 0.62))
        p.addLine(to: CGPoint(x: fw, y: baseY + peak * 0.2))
        p.addLine(to: CGPoint(x: fw, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    let farC = night ? color(0.16, 0.18, 0.30) : NSColor(hue: (hue + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.72, alpha: 1).cgColor
    let nearC = night ? color(0.09, 0.10, 0.18) : NSColor(hue: (hue + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.5, alpha: 1).cgColor
    let groundC = night ? color(0.05, 0.06, 0.10) : NSColor(hue: (hue + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.3, alpha: 1).cgColor
    mountains(fh * 0.30, fh * 0.26, farC)
    mountains(fh * 0.18, fh * 0.18, nearC)
    // 水面反光带
    ctx.setFillColor(night ? color(0.10, 0.12, 0.22) : NSColor(hue: (hue + 0.52).truncatingRemainder(dividingBy: 1), saturation: 0.4, brightness: 0.62, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: fw, height: fh * 0.08))
    ctx.setFillColor(groundC)
    ctx.fill(CGRect(x: 0, y: 0, width: fw, height: fh * 0.035))
    return ctx.makeImage()!
}

let photos = [
    ("mountain", scene(2200, 1500, hue: 0.55)),
    ("sunset", scene(1600, 1200, hue: 0.05)),
    ("forest", scene(1800, 1350, hue: 0.32)),
    ("night", scene(1600, 1600, hue: 0.6, night: true)),
    ("panorama", scene(2400, 1200, hue: 0.5)),
    ("dusk", scene(1400, 1100, hue: 0.72)),
]

// MARK: - 绘制工具

func font(_ size: CGFloat, bold: Bool = false, cjk: Bool = false) -> CTFont {
    if cjk {
        return CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    }
    return CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
}

func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
}

func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat,
          _ size: CGFloat, color: CGColor, bold: Bool = false) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
        .font: font(size, bold: bold, cjk: hasCJK(s)),
        .foregroundColor: color,
    ]))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func roundRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, _ fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

func stroke(_ ctx: CGContext, _ pts: [CGPoint], _ width: CGFloat, _ color: CGColor) {
    guard let first = pts.first else { return }
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addLines(between: pts)
    ctx.strokePath()
}

// MARK: - 界面元素（忠实于应用实际布局）

func drawPhoto(_ ctx: CGContext, _ img: CGImage, scale: CGFloat = 1) {
    let areaY = STRIP, areaH = H - STRIP
    let iw = CGFloat(img.width) * scale, ih = CGFloat(img.height) * scale
    let s = min((W - 80) / iw, (areaH - 60) / ih)
    let w = iw * s, h = ih * s
    ctx.draw(img, in: CGRect(x: (W - w) / 2, y: areaY + (areaH - h) / 2, width: w, height: h))
}

func drawZoomed(_ ctx: CGContext, _ img: CGImage, zoom: CGFloat) {
    let areaY = STRIP, areaH = H - STRIP
    let s = min((W - 80) / CGFloat(img.width), (areaH - 60) / CGFloat(img.height)) * zoom
    let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
    // 裁剪到可视区域，中心对准画面 45% 高度处的细节
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: areaY, width: W, height: areaH))
    ctx.draw(img, in: CGRect(x: (W - w) / 2, y: areaY + (areaH - h) / 2 - h * 0.08, width: w, height: h))
    ctx.restoreGState()
}

func drawTrafficLights(_ ctx: CGContext) {
    let colors = [color(1.0, 0.37, 0.34), color(1.0, 0.74, 0.18), color(0.16, 0.78, 0.25)]
    for (i, c) in colors.enumerated() {
        let x = 40 + CGFloat(i) * 36
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: x - 9, y: H - 49, width: 18, height: 18))
    }
}

func drawInfoCard(_ ctx: CGContext, _ lines: [(String, Bool)]) {
    let cardW: CGFloat = 680, lineH: CGFloat = 44, pad: CGFloat = 26
    let cardH = CGFloat(lines.count) * lineH + pad * 2 - 8
    roundRect(ctx, CGRect(x: 36, y: H - 128 - cardH, width: cardW, height: cardH), 16,
              color(0.11, 0.11, 0.125, 0.94))
    for (i, line) in lines.enumerated() {
        let y = H - 128 - cardH + pad + 30 + CGFloat(lines.count - 1 - i) * lineH
        text(ctx, line.0, 36 + pad, y, 26,
             color: line.1 ? color(1, 1, 1, 0.95) : color(1, 1, 1, 0.62), bold: i == 0)
    }
}

func drawToolbar(_ ctx: CGContext, y: CGFloat, slideshowPlaying: Bool = false) {
    let tw: CGFloat = 1060, th: CGFloat = 92
    let tx = (W - tw) / 2
    roundRect(ctx, CGRect(x: tx, y: y, width: tw, height: th), 26, color(0.11, 0.11, 0.125, 0.92))
    let cy = y + th / 2
    let white = color(1, 1, 1, 0.92)
    let glyph: (String, CGFloat) -> Void = { name, cx in
        switch name {
        case "prev":
            stroke(ctx, [CGPoint(x: cx + 8, y: cy + 16), CGPoint(x: cx - 8, y: cy), CGPoint(x: cx + 8, y: cy - 16)], 7, white)
        case "next":
            stroke(ctx, [CGPoint(x: cx - 8, y: cy + 16), CGPoint(x: cx + 8, y: cy), CGPoint(x: cx - 8, y: cy - 16)], 7, white)
        case "zoomIn", "zoomOut":
            ctx.setStrokeColor(white)
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: cx - 16, y: cy - 14, width: 24, height: 24))
            stroke(ctx, [CGPoint(x: cx + 8, y: cy + 2), CGPoint(x: cx + 20, y: cy + 14)], 7, white)
            stroke(ctx, [CGPoint(x: cx - 12, y: cy - 2), CGPoint(x: cx + 0, y: cy - 2)], 5, white)
            if name == "zoomIn" {
                stroke(ctx, [CGPoint(x: cx - 6, y: cy + 4), CGPoint(x: cx - 6, y: cy - 8)], 5, white)
            }
        case "fit":
            stroke(ctx, [CGPoint(x: cx - 16, y: cy + 12), CGPoint(x: cx - 4, y: cy), CGPoint(x: cx - 16, y: cy - 12)], 6, white)
            stroke(ctx, [CGPoint(x: cx + 16, y: cy + 12), CGPoint(x: cx + 4, y: cy), CGPoint(x: cx + 16, y: cy - 12)], 6, white)
        case "actual":
            text(ctx, "1:1", cx - 21, cy - 10, 30, color: white, bold: true)
        case "rotL", "rotR":
            let dir: CGFloat = name == "rotR" ? -1 : 1
            ctx.setStrokeColor(white)
            ctx.setLineWidth(5)
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: 16,
                       startAngle: dir * .pi * 0.15, endAngle: dir * .pi * 1.25, clockwise: dir < 0)
            ctx.strokePath()
            ctx.setFillColor(white)
            let tip = CGPoint(x: cx + dir * 15, y: cy + 9)
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: tip.x + dir * 12, y: tip.y + 2))
            tri.addLine(to: CGPoint(x: tip.x - dir * 4, y: tip.y + 14))
            tri.addLine(to: CGPoint(x: tip.x - dir * 2, y: tip.y - 10))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        case "slideshow":
            ctx.setFillColor(white)
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: cx - 10, y: cy + 16))
            tri.addLine(to: CGPoint(x: cx - 10, y: cy - 16))
            tri.addLine(to: CGPoint(x: cx + 18, y: cy))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        case "info":
            ctx.setStrokeColor(white)
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: cx - 17, y: cy - 17, width: 34, height: 34))
            text(ctx, "i", cx - 5, cy - 12, 30, color: white, bold: true)
        case "strip":
            for k in 0..<3 {
                roundRect(ctx, CGRect(x: cx - 24 + CGFloat(k) * 18, y: cy - 7, width: 14, height: 14), 3, white)
            }
        case "export":
            stroke(ctx, [CGPoint(x: cx, y: cy + 16), CGPoint(x: cx, y: cy - 8)], 6, white)
            stroke(ctx, [CGPoint(x: cx - 9, y: cy), CGPoint(x: cx, y: cy + 9), CGPoint(x: cx + 9, y: cy)], 6, white)
            stroke(ctx, [CGPoint(x: cx - 15, y: cy - 16), CGPoint(x: cx + 15, y: cy - 16)], 6, white)
        case "rename":
            stroke(ctx, [CGPoint(x: cx - 13, y: cy - 13), CGPoint(x: cx + 9, y: cy + 9)], 7, white)
            stroke(ctx, [CGPoint(x: cx + 9, y: cy + 9), CGPoint(x: cx + 15, y: cy + 15)], 4, white)
        case "trash":
            stroke(ctx, [CGPoint(x: cx - 14, y: cy + 13), CGPoint(x: cx + 14, y: cy + 13)], 6, white)
            stroke(ctx, [CGPoint(x: cx - 4, y: cy + 16), CGPoint(x: cx + 4, y: cy + 16)], 4, white)
            roundRect(ctx, CGRect(x: cx - 10, y: cy - 16, width: 20, height: 27), 4, white)
        default:
            break
        }
    }
    let names = ["zoomIn", "zoomOut", "fit", "actual", "rotL", "rotR", "slideshow", "info", "strip", "export", "rename", "trash"]
    let separatorsAfter: Set<Int> = [3, 5, 6, 8]   // 分组边界：缩放|旋转|放映|信息|操作
    let slot: CGFloat = 68
    var cx = tx + 42
    for (i, name) in names.enumerated() {
        glyph(name, cx)
        cx += slot
        if separatorsAfter.contains(i) && i + 1 < names.count {
            stroke(ctx, [CGPoint(x: cx - 14, y: cy - 22), CGPoint(x: cx - 14, y: cy + 22)], 2,
                   color(1, 1, 1, 0.25))
            cx += 18
        }
    }
}

func drawArrows(_ ctx: CGContext) {
    let aw: CGFloat = 88, ah: CGFloat = 128
    for (x, dir) in [(CGFloat(36), CGFloat(-1)), (W - 36 - aw, CGFloat(1))] {
        let cy = STRIP + (H - STRIP) / 2
        roundRect(ctx, CGRect(x: x, y: cy - ah / 2, width: aw, height: ah), 22, color(0.11, 0.11, 0.125, 0.8))
        stroke(ctx, [CGPoint(x: x + aw / 2 - dir * 14, y: cy + 30),
                     CGPoint(x: x + aw / 2 + dir * 14, y: cy),
                     CGPoint(x: x + aw / 2 - dir * 14, y: cy - 30)], 9, color(1, 1, 1, 0.95))
    }
}

func drawFilmstrip(_ ctx: CGContext, active: Int) {
    roundRect(ctx, CGRect(x: 0, y: 0, width: W, height: STRIP), 0, color(0.05, 0.05, 0.06, 0.96))
    let size: CGFloat = 120
    for i in 0..<photos.count {
        let x = 48 + CGFloat(i) * (size + 24)
        let y = (STRIP - size) / 2
        roundRect(ctx, CGRect(x: x - 5, y: y - 5, width: size + 10, height: size + 10), 12,
                  i == active ? color(1, 1, 1, 1) : color(1, 1, 1, 0.08))
        let img = photos[i].1
        let s = min(size / CGFloat(img.width), size / CGFloat(img.height))
        let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: size, height: size), cornerWidth: 9,
                           cornerHeight: 9, transform: nil))
        ctx.clip()
        ctx.draw(img, in: CGRect(x: x + (size - w) / 2, y: y + (size - h) / 2, width: w, height: h))
        ctx.restoreGState()
    }
}

func drawExifPanel(_ ctx: CGContext) {
    let pw: CGFloat = 640, ph: CGFloat = 780
    let px = W - pw - 36, py = H - 128 - ph
    roundRect(ctx, CGRect(x: px, y: py, width: pw, height: ph), 24, color(0.11, 0.11, 0.125, 0.94))
    text(ctx, S("exif.title"), px + 34, py + ph - 66, 30, color: color(1, 1, 1, 0.6), bold: true)
    let rows: [(String, String)] = [
        (S("exif.camera"), "Apple iPhone 15 Pro"),
        (S("exif.lens"), "主摄 24 mm ƒ/1.78"),
        (S("exif.params"), "ƒ/1.78 · 1/120 s · ISO 64"),
        (S("exif.date"), "2026-08-30 17:42"),
        (S("exif.size"), "8064 × 6048"),
        (S("exif.file"), "IMG_4032.HEIC · 3.8 MB"),
    ]
    var y = py + ph - 150
    for (k, v) in rows {
        text(ctx, k, px + 34, y + 40, 24, color: color(1, 1, 1, 0.5))
        text(ctx, v, px + 34, y, 28, color: color(1, 1, 1, 0.95))
        y -= 96
    }
}

// MARK: - 组装四张截图

func newCanvas() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(color(0.04, 0.04, 0.05))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    return ctx
}

func save(_ ctx: CGContext, _ name: String) {
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("cannot create \(name)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("✓ \(name)")
}

// 1. 主视觉：浏览视图
var ctx = newCanvas()
drawPhoto(ctx, photos[4].1)
drawFilmstrip(ctx, active: 4)
drawToolbar(ctx, y: STRIP + 24)
drawArrows(ctx)
drawTrafficLights(ctx)
drawInfoCard(ctx, [("5 / 6 · 05-panorama.png", true),
                   ("6000 × 3000 · 16.3 MB · PNG · 38%", false),
                   ("NIKON Z 6II · 24 mm ƒ/2.8", false),
                   ("1/250 s · ISO 100 · 2026-08-14 09:30", false)])
save(ctx, "01-browse.png")

// 2. EXIF 信息面板
ctx = newCanvas()
drawPhoto(ctx, photos[1].1)
drawFilmstrip(ctx, active: 1)
drawToolbar(ctx, y: STRIP + 24)
drawArrows(ctx)
drawTrafficLights(ctx)
drawInfoCard(ctx, [("2 / 6 · 02-sunset.jpg", true),
                   ("1600 × 1200 · 820 KB · JPEG · 100%", false)])
drawExifPanel(ctx)
save(ctx, "02-exif.png")

// 3. 100% 细节 + 信息卡
ctx = newCanvas()
drawZoomed(ctx, photos[0].1, zoom: 2.5)
drawFilmstrip(ctx, active: 0)
drawToolbar(ctx, y: STRIP + 24)
drawArrows(ctx)
drawTrafficLights(ctx)
drawInfoCard(ctx, [("1 / 6 · 01-mountain.jpg", true),
                   ("2200 × 1500 · 2.4 MB · JPEG · 250%", false),
                   ("NIKON Z 6II · 24 mm ƒ/2.8", false),
                   ("1/250 s · ISO 100 · 2026-08-14 09:30", false)])
save(ctx, "03-zoom.png")

func drawExportPanel(_ ctx: CGContext) {
    let pw: CGFloat = 1240, ph: CGFloat = 560
    let px = (W - pw) / 2, py = (H - ph) / 2 + 60
    // 真实 NSSavePanel 的深色样式
    roundRect(ctx, CGRect(x: px, y: py, width: pw, height: ph), 22, color(0.16, 0.16, 0.175, 0.99))
    roundRect(ctx, CGRect(x: px + 28, y: py + ph - 110, width: pw - 56, height: 58), 10, color(0.10, 0.10, 0.11))
    text(ctx, S("exp.name"), px + 48, py + ph - 92, 28, color: color(1, 1, 1, 0.92))

    text(ctx, S("exp.format"), px + 28, py + ph - 190, 26, color: color(1, 1, 1, 0.6))
    roundRect(ctx, CGRect(x: px + 170, y: py + ph - 222, width: 240, height: 52), 10, color(0.25, 0.25, 0.27))
    text(ctx, "JPEG", px + 192, py + ph - 204, 26, color: color(1, 1, 1, 0.92))
    stroke(ctx, [CGPoint(x: px + 374, y: py + ph - 190), CGPoint(x: px + 386, y: py + ph - 202),
                 CGPoint(x: px + 398, y: py + ph - 190)], 5, color(1, 1, 1, 0.7))

    text(ctx, S("exp.quality"), px + 28, py + ph - 268, 26, color: color(1, 1, 1, 0.6))
    let tx = px + 170, tw: CGFloat = 480, ty = py + ph - 244
    roundRect(ctx, CGRect(x: tx, y: ty, width: tw, height: 8), 4, color(1, 1, 1, 0.18))
    roundRect(ctx, CGRect(x: tx, y: ty, width: tw * 0.5, height: 8), 4, color(0.35, 0.55, 1.0))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: tx + tw * 0.5 - 13, y: ty - 9, width: 26, height: 26))

    text(ctx, S("exp.estimate"), px + 28, py + ph - 336, 28, color: color(1, 1, 1, 0.85), bold: true)

    // 按钮：取消 / 导出（蓝色主按钮）
    let bw: CGFloat = 170, bh: CGFloat = 56
    roundRect(ctx, CGRect(x: px + pw - 28 - bw * 2 - 16, y: py + 28, width: bw, height: bh), 12, color(0.30, 0.30, 0.32))
    text(ctx, S("exp.cancel"), px + pw - 28 - bw * 2 - 16 + (bw - 60) / 2, py + 46, 27, color: color(1, 1, 1, 0.9))
    roundRect(ctx, CGRect(x: px + pw - 28 - bw, y: py + 28, width: bw, height: bh), 12, color(0.15, 0.40, 0.95))
    text(ctx, S("exp.go"), px + pw - 28 - bw + (bw - 56) / 2, py + 46, 27, color: color(1, 1, 1, 1))
}

// 5. 导出面板（格式 / 质量 / 预估大小）
var ctx5 = newCanvas()
drawPhoto(ctx5, photos[0].1)
drawFilmstrip(ctx5, active: 0)
drawToolbar(ctx5, y: STRIP + 24)
drawArrows(ctx5)
drawTrafficLights(ctx5)
ctx5.setFillColor(color(0, 0, 0, 0.45))
ctx5.fill(CGRect(x: 0, y: 0, width: W, height: H))
drawExportPanel(ctx5)
save(ctx5, "05-export.png")

// 4. 幻灯片播放（全屏、控件淡出）
ctx = newCanvas()
drawPhoto(ctx, photos[3].1)
drawTrafficLights(ctx)
text(ctx, S("slideshow.hint"), W / 2 - 480, STRIP + 40, 30, color: color(1, 1, 1, 0.55))
save(ctx, "04-slideshow.png")

print("done → \(outDir)")

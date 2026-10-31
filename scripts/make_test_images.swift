// swift scripts/make_test_images.swift <目录>
// 生成多格式、多尺寸的测试图片（带文件名水印，便于核对翻页）
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "TestImages"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ width: Int, _ height: Int, label: String, hue: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    let night = hue > 0.65
    if night {
        let top = [CGColor(srgbRed: 0.03, green: 0.04, blue: 0.10, alpha: 1),
                   CGColor(srgbRed: 0.12, green: 0.11, blue: 0.25, alpha: 1)] as CFArray
        ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: top, locations: [0, 1])!,
                               start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        let moonX = w * (0.3 + hue * 0.4), moonY = h * 0.7
        ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.94, blue: 1.0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: moonX - h * 0.05, y: moonY - h * 0.05, width: h * 0.1, height: h * 0.1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        for (dx, dy, sz) in [(0.15, 0.85, 4.0), (0.35, 0.9, 3.0), (0.55, 0.82, 4.0), (0.8, 0.9, 3.0), (0.9, 0.75, 2.0)] {
            ctx.fillEllipse(in: CGRect(x: w * dx, y: h * dy, width: sz, height: sz))
        }
        ridge(h * 0.28, h * 0.24, CGColor(srgbRed: 0.11, green: 0.12, blue: 0.22, alpha: 1))
        ridge(h * 0.16, h * 0.16, CGColor(srgbRed: 0.06, green: 0.07, blue: 0.13, alpha: 1))
    } else {
        let horizon = h * 0.62
        let sky = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.16, green: 0.15, blue: 0.33, alpha: 1),
            CGColor(srgbRed: 0.62, green: 0.30, blue: 0.44, alpha: 1),
            CGColor(srgbRed: 0.96, green: 0.66, blue: 0.36, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: horizon), options: [])
        let sunX = w * (0.3 + hue * 0.4), sunY = h * 0.55
        let sunR = h * 0.09
        for (k, a) in [(2.6, 0.08), (1.7, 0.14), (1.25, 0.2)] {
            ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.85, blue: 0.55, alpha: a))
            ctx.fillEllipse(in: CGRect(x: sunX - sunR * k, y: sunY - sunR * k, width: sunR * 2 * k, height: sunR * 2 * k))
        }
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.90, blue: 0.68, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2))
        ridge(horizon - h * 0.02, h * 0.2, CGColor(srgbRed: 0.44, green: 0.28, blue: 0.46, alpha: 1))
        ridge(horizon - h * 0.05, h * 0.13, CGColor(srgbRed: 0.22, green: 0.18, blue: 0.33, alpha: 1))
        ctx.setFillColor(CGColor(srgbRed: 0.14, green: 0.12, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: horizon))
        let refl = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.96, green: 0.66, blue: 0.36, alpha: 0.4),
            CGColor(srgbRed: 0.96, green: 0.66, blue: 0.36, alpha: 0.0),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(refl, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 0), options: [])
    }
    return ctx.makeImage()!

    func ridge(_ baseY: CGFloat, _ peak: CGFloat, _ c: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: baseY))
        p.addLine(to: CGPoint(x: w * 0.2, y: baseY + peak))
        p.addLine(to: CGPoint(x: w * 0.44, y: baseY + peak * 0.35))
        p.addLine(to: CGPoint(x: w * 0.66, y: baseY + peak * 0.8))
        p.addLine(to: CGPoint(x: w * 0.86, y: baseY + peak * 0.3))
        p.addLine(to: CGPoint(x: w, y: baseY + peak * 0.55))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(c)
        ctx.fillPath()
    }
}

func save(_ image: CGImage, name: String, uti: UTType) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(name)")
    }
    // 注入真实感的 EXIF（JPEG/HEIC），让信息面板有内容可展示
    let props: [CFString: Any] = uti == .png ? [:] : [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 15 Pro",
        ] as [CFString: Any],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifExposureTime: 1.0 / 120.0,
            kCGImagePropertyExifFNumber: 1.78,
            kCGImagePropertyExifISOSpeedRatings: [64],
            kCGImagePropertyExifFocalLength: 24.0,
            kCGImagePropertyExifDateTimeOriginal: "2026:08:30 17:42:00",
            kCGImagePropertyExifLensModel: "iPhone 15 Pro back triple camera 24mm f/1.78",
        ] as [CFString: Any],
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let specs: [(name: String, w: Int, h: Int, uti: UTType, hue: CGFloat)] = [
    ("01-sunset.jpg", 800, 600, .jpeg, 0.05),
    ("02-forest.png", 1920, 1080, .png, 0.35),
    ("03-ocean.heic", 4032, 3024, .heic, 0.55),
    ("04-portrait.jpg", 1200, 1800, .jpeg, 0.8),
    ("05-panorama.png", 6000, 3000, .png, 0.62),
    ("06-night.heic", 2500, 2500, .heic, 0.7),
]
for (i, s) in specs.enumerated() {
    save(render(s.w, s.h, label: s.name, hue: s.hue), name: s.name, uti: s.uti)
    print("(\(i + 1)/\(specs.count)) \(s.name) \(s.w)x\(s.h)")
}
print("test images written to \(dir)")

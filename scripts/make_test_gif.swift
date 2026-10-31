// swift scripts/make_test_gif.swift <输出目录>
// 生成测试动图：6 帧 400×300，小球移动，0.1s/帧，无限循环
import AppKit
import CoreGraphics
import Foundation
import ImageIO

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let url = URL(fileURLWithPath: dir).appendingPathComponent("sample.gif")

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 6, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

for i in 0..<6 {
    let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let hue = CGFloat(i) / 6
    ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.25, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    ctx.setFillColor(NSColor(hue: hue, saturation: 0.8, brightness: 1, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: CGFloat(40 + i * 56), y: 110, width: 80, height: 80))
    text(ctx, "FRAME \(i + 1)/6", 20, 260, size: 28)
    let img = ctx.makeImage()!
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("test gif → \(url.path)")

func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat) {
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
    ]))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

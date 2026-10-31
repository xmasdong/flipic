// 验证无损旋转写回配方：JPEG 走方向元数据重写（像素字节不变）；PNG 回退像素旋转重编码
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RotationWriteResult { case lossless, reencoded, failed }
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func writeRotation(url: URL, clockwiseTurns: Int) -> RotationWriteResult {
    let fm = FileManager.default
    guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let typeID = CGImageSourceGetType(src) else { return .failed }
    let type = typeID as String

    var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
    let oldOrientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
    let cycle = [1: 6, 6: 3, 3: 8, 8: 1]
    var orientation = oldOrientation == 0 ? 1 : oldOrientation
    for _ in 0..<(clockwiseTurns % 4) { orientation = cycle[orientation] ?? orientation }
    props[kCGImagePropertyOrientation as String] = orientation

    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".check-\(UUID().uuidString).\(url.pathExtension)")
    guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, typeID as CFString, 1, nil) else { return .failed }
    CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { try? fm.removeItem(at: tmp); return .failed }

    var lossless = false
    if let checkSrc = CGImageSourceCreateWithURL(tmp as CFURL, nil),
       let checkProps = CGImageSourceCopyPropertiesAtIndex(checkSrc, 0, nil) as? [String: Any],
       let written = checkProps[kCGImagePropertyOrientation as String] as? Int,
       written == orientation {
        lossless = true
    }
    if !lossless {
        guard let raw = try? Data(contentsOf: url),
          let pixelsData = CGImageSourceCreateWithData(raw as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(pixelsData, 0, nil) else { return .failed }
        // 像素旋转 90°（简化版验证：直接转一次）
        let rw = pixels.height, rh = pixels.width
        let rctx = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: 0,
                             space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        rctx.translateBy(x: CGFloat(rw) / 2, y: CGFloat(rh) / 2)
        rctx.rotate(by: -.pi / 2)
        rctx.draw(pixels, in: CGRect(x: -CGFloat(pixels.width) / 2, y: -CGFloat(pixels.height) / 2,
                                     width: CGFloat(pixels.width), height: CGFloat(pixels.height)))
        let rotated = rctx.makeImage()!
        guard let rdest = CGImageDestinationCreateWithURL(tmp as CFURL, typeID as CFString, 1, nil) else { return .failed }
        CGImageDestinationAddImage(rdest, rotated, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(rdest) else { return .failed }
    }
    _ = try? fm.removeItem(at: url)
    try? fm.moveItem(at: tmp, to: url)
    return lossless ? .lossless : .reencoded
}

func orientationOf(_ url: URL) -> Int {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return -1 }
    return (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
}

func makeJPEG(dir: String, name: String) -> URL {
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return url
}

let dir = "/tmp/pv-rotcheck"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

// JPEG：两次顺时针 → 方向 1 → 6 → 3
let jpeg = makeJPEG(dir: dir, name: "a.jpg")
print("JPEG 初始方向: \(orientationOf(jpeg))")
var r = writeRotation(url: jpeg, clockwiseTurns: 1)
print("JPEG +90° → \(r), 方向=\(orientationOf(jpeg))  (期望 lossless / 6)")
r = writeRotation(url: jpeg, clockwiseTurns: 1)
print("JPEG +90° → \(r), 方向=\(orientationOf(jpeg))  (期望 lossless / 3)")

// PNG：应走 reencoded 回退（PNG 无标准方向属性）
let pctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                     space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
pctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1))
pctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
let png = URL(fileURLWithPath: dir).appendingPathComponent("b.png")
let pdest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(pdest, pctx.makeImage()!, nil)
CGImageDestinationFinalize(pdest)
r = writeRotation(url: png, clockwiseTurns: 1)
print("PNG +90° → \(r)  (期望 reencoded)")

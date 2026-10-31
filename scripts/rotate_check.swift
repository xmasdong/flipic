// 旋转方向终极验证：源图与结果都直接读 CGImage 原始字节（第 0 行 = 顶部，PNG 标准）
// 源图 4×2：第 0 行（顶）第 0 列 = 红，其余蓝。
// 顺时针 90° → 红应出现在结果（2×4）的第 0 行第 1 列（右上角）
import CoreGraphics
import Foundation

func rotated(_ src: CGImage, quarterTurns: Int, sign: Double) -> CGImage {
    let k = ((quarterTurns % 4) + 4) % 4
    guard k != 0 else { return src }
    let swap = (k == 1 || k == 3)
    let dw = swap ? src.height : src.width
    let dh = swap ? src.width : src.height
    let ctx = CGContext(data: nil, width: dw, height: dh, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: CGFloat(dw) / 2, y: CGFloat(dh) / 2)
    ctx.rotate(by: sign * .pi / 2 * CGFloat(k))
    ctx.draw(src, in: CGRect(x: -CGFloat(src.width) / 2, y: -CGFloat(src.height) / 2,
                             width: CGFloat(src.width), height: CGFloat(src.height)))
    return ctx.makeImage()!
}

// 直接用字节构造 4×2 图：第 0 行（= 图片顶部）第 0 列（= 左）是红
func makeSource() -> CGImage {
    var bytes = [UInt8](repeating: 0, count: 4 * 2 * 4)
    for i in 0..<(4 * 2) {
        bytes[i * 4 + 2] = 255 // 蓝
        bytes[i * 4 + 3] = 255 // alpha
    }
    bytes[0] = 255 // 红
    bytes[2] = 0
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

func printGrid(_ img: CGImage, label: String) {
    guard let provider = img.dataProvider,
          let data = provider.data as Data? else { return }
    let bytes = [UInt8](data)
    let w = img.width, h = img.height
    let bpp = img.bitsPerPixel / 8
    let rowBytes = img.bytesPerRow
    print("\(label) \(w)×\(h) bpp=\(img.bitsPerPixel):")
    for r in 0..<h {
        var line = ""
        for c in 0..<w {
            let o = r * rowBytes + c * bpp
            let rC = bytes[o], gC = bytes[o + 1], bC = bytes[o + 2], aC = bpp == 4 ? bytes[o + 3] : 255
            if aC < 50 { line += "." }
            else if rC > 200 && gC < 100 && bC < 100 { line += "R" }
            else if bC > 200 && rC < 100 { line += "B" }
            else { line += "?" }
        }
        print("  \(line)")
    }
}

let src = makeSource()
printGrid(src, label: "源图")
for k in [1, 2, 3] {
    for sign in [1.0, -1.0] {
        let out = rotated(src, quarterTurns: k, sign: sign)
        printGrid(out, label: "turns=\(k) sign=\(sign)")
    }
}

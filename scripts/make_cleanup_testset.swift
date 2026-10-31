// 生成清理模式测试集：原图、模糊副本、完全重复、相似连拍，全部去掉 EXIF，修改时间按 1 秒递增
// 用法：swift scripts/make_cleanup_testset.swift <源图文件夹> <输出文件夹>
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let ctx = CIContext()
let files = try! FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
    .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var t = Date(timeIntervalSince1970: 1_700_000_000)
var labels: [String] = []
func write(_ img: CIImage, _ name: String, _ label: String) {
    let url = out.appendingPathComponent(name)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    try! ctx.writeJPEGRepresentation(of: img, to: url, colorSpace: cs,
                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    try! FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: url.path)
    t += 1
    labels.append("\(name)\t\(label)")
}

for (i, f) in files.enumerated() {
    var img = CIImage(contentsOf: f, options: [.applyOrientationProperty: true])!
    // 缩到 3000 长边，接近常见相机 JPG 的像素量
    let s = 3000 / max(img.extent.width, img.extent.height)
    img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
    let ext = img.extent
    let base = String(format: "%02d", i + 1)
    write(img, "\(base)-a.jpg", "sharp")
    // 连拍：同一场景小幅平移裁切 + 微调曝光，模拟连按快门
    for k in 1...2 {
        let dx = CGFloat(k) * ext.width * 0.015
        let crop = img.cropped(to: CGRect(x: ext.minX + dx, y: ext.minY, width: ext.width * 0.95, height: ext.height * 0.95))
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: Double(k) * 0.1])
        write(crop.transformed(by: CGAffineTransform(translationX: -crop.extent.minX, y: -crop.extent.minY)),
              "\(base)-b\(k).jpg", "burst-of-\(base)-a")
    }
    if i % 2 == 0 {
        // 虚焦：高斯模糊
        let r: Double = i % 4 == 0 ? 4 : 8
        write(img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: ext),
              "\(base)-blur\(Int(r)).jpg", "blurry-gauss-\(Int(r))")
    } else {
        // 手抖：运动模糊
        write(img.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 18, kCIInputAngleKey: 0.3]).cropped(to: ext),
              "\(base)-shake.jpg", "blurry-motion-18")
    }
}
// 完全重复：复制两份
for name in ["01-a.jpg", "04-a.jpg"] {
    let copy = name.replacingOccurrences(of: ".jpg", with: " 副本.jpg")
    try! FileManager.default.copyItem(at: out.appendingPathComponent(name), to: out.appendingPathComponent(copy))
    try! FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: out.appendingPathComponent(copy).path)
    t += 1
    labels.append("\(copy)\tduplicate-of-\(name)")
}
try! labels.joined(separator: "\n").write(to: out.appendingPathComponent("labels.tsv"), atomically: true, encoding: .utf8)
print("wrote \(labels.count) files to \(out.path)")

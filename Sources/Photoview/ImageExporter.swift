import CoreGraphics
import Foundation
import ImageIO

enum ImageExporter {
    /// 将图片编码写入目标位置，返回写出文件的字节数（失败返回 nil）
    static func write(_ image: CGImage, to url: URL, uti: String, quality: Double) -> Int64? {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64)
    }
}

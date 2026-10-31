import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片的基本信息：原图尺寸（已按 EXIF 方向校正）与是否动图，只读文件头
struct ImageInfo {
    let pixelSize: CGSize
    let isAnimated: Bool
}

final class ImageLoader {
    static let shared = ImageLoader()

    private let previewCache = NSCache<NSURL, CGBox>()
    private let fullCache = NSCache<NSURL, CGBox>()
    private let thumbCache = NSCache<NSURL, CGBox>()
    private let infoCache = NSCache<NSURL, InfoBox>()
    private var pressureSource: DispatchSourceMemoryPressure?

    /// 屏幕显示用全图的最长边上限：超过 GPU 纹理上限的部分 Core Animation 也显示不出来
    static let displayMaxPixel: CGFloat = 16384

    private init() {
        // 内存天花板按物理内存取比例：预览 1/32（128~320MB）；全图只留当前与上一张
        let mem = Int(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max)))
        previewCache.countLimit = 12
        previewCache.totalCostLimit = min(max(mem / 32, 128 << 20), 320 << 20)
        fullCache.countLimit = 2
        fullCache.totalCostLimit = min(max(mem / 12, 256 << 20), 640 << 20)
        thumbCache.countLimit = 800
        infoCache.countLimit = 4000

        // 系统内存吃紧时主动让出：屏幕上的图由图层持有，清缓存不影响当前显示
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.purge() }
        source.resume()
        pressureSource = source
    }

    func purge() {
        previewCache.removeAllObjects()
        fullCache.removeAllObjects()
        thumbCache.removeAllObjects()
    }

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "webp", "gif", "bmp",
        "tif", "tiff", "jp2", "jxl", "avif", "ico", "icns",
        "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
    ]

    static func isSupportedExtension(_ name: String) -> Bool {
        supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// ImageIO 降采样解码：maxPixel 是需要的最大边长像素
    /// allowEmbedded：允许直接用文件内嵌的 EXIF 缩略图（胶片条用，免去整图解码）
    static func renderThumbnail(url: URL, maxPixel: CGFloat, allowEmbedded: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            allowEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    func cachedFull(for url: URL) -> CGImage? {
        fullCache.object(forKey: url as NSURL)?.image
    }

    func cachedInfo(for url: URL) -> ImageInfo? {
        infoCache.object(forKey: url as NSURL)?.info
    }

    /// 只读文件头拿原图尺寸与动图标记，不解码像素
    func info(for url: URL) -> ImageInfo? {
        if let hit = infoCache.object(forKey: url as NSURL) { return hit.info }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        let info = ImageInfo(pixelSize: swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h),
                             isAnimated: Self.isAnimated(source: src, props: props))
        infoCache.setObject(InfoBox(info), forKey: url as NSURL)
        return info
    }

    /// 已缓存且分辨率够用的预览图（不触发解码，可在主线程调用）
    func cachedPreview(for url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let hit = previewCache.object(forKey: url as NSURL) else { return nil }
        if hit.px >= maxPixel - 1 { return hit.image }
        // 原图本身比目标还小时，缓存里的就是原图分辨率
        if let info = cachedInfo(for: url), hit.px >= max(info.pixelSize.width, info.pixelSize.height) - 1 { return hit.image }
        return nil
    }

    /// 适配窗口用的快速预览图
    func preview(for url: URL, maxPixel: CGFloat) -> CGImage? {
        if let hit = cachedPreview(for: url, maxPixel: maxPixel) { return hit }
        guard let img = Self.renderThumbnail(url: url, maxPixel: maxPixel) else { return nil }
        previewCache.setObject(CGBox(image: img, px: CGFloat(max(img.width, img.height))),
                               forKey: url as NSURL, cost: pixelBytes(img))
        return img
    }

    /// 全分辨率解码（带 EXIF 方向校正），不写缓存；maxPixel 给出时最长边不超过它
    static func decodedFull(url: URL, maxPixel: CGFloat? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        var maxSide = max(props?["PixelWidth"] as? Int ?? 0, props?["PixelHeight"] as? Int ?? 0)
        if let maxPixel { maxSide = min(maxSide, Int(maxPixel)) }
        if maxSide > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 全分辨率图（带 EXIF 方向校正），供放大查看；只在预览分辨率不够时才解码
    func fullImage(for url: URL) -> CGImage? {
        if let hit = fullCache.object(forKey: url as NSURL) { return hit.image }
        guard let image = Self.decodedFull(url: url, maxPixel: Self.displayMaxPixel) else { return nil }
        fullCache.setObject(CGBox(image: image, px: CGFloat(max(image.width, image.height))),
                            forKey: url as NSURL, cost: pixelBytes(image))
        return image
    }

    /// 旋转 90° 的整数倍。quarterTurns 为正 = 顺时针（方向已经像素级测试验证）
    static func rotated(_ src: CGImage, quarterTurns: Int) -> CGImage {
        let k = ((quarterTurns % 4) + 4) % 4
        guard k != 0 else { return src }
        let swap = (k == 1 || k == 3)
        let dw = swap ? src.height : src.width
        let dh = swap ? src.width : src.height
        guard let ctx = CGContext(data: nil, width: dw, height: dh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
        ctx.translateBy(x: CGFloat(dw) / 2, y: CGFloat(dh) / 2)
        ctx.rotate(by: -.pi / 2 * CGFloat(k))
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: -CGFloat(src.width) / 2, y: -CGFloat(src.height) / 2,
                                 width: CGFloat(src.width), height: CGFloat(src.height)))
        return ctx.makeImage() ?? src
    }

    func cachedThumb(for url: URL) -> CGImage? {
        thumbCache.object(forKey: url as NSURL)?.image
    }

    func thumb(for url: URL) -> CGImage? {
        if let hit = thumbCache.object(forKey: url as NSURL) { return hit.image }
        guard let img = Self.renderThumbnail(url: url, maxPixel: 128, allowEmbedded: true) else { return nil }
        thumbCache.setObject(CGBox(image: img, px: 128), forKey: url as NSURL, cost: pixelBytes(img))
        return img
    }

    /// 判断文件是否为可播放的动图（ImageIO 动画 API 支持 GIF 与 APNG）
    private static func isAnimated(source src: CGImageSource, props: [String: Any]) -> Bool {
        guard let typeID = CGImageSourceGetType(src) else { return false }
        let type = typeID as String
        if type == UTType.gif.identifier { return CGImageSourceGetCount(src) > 1 }
        if type == UTType.png.identifier,
           let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any],
           png[kCGImagePropertyAPNGLoopCount as String] != nil {
            return true
        }
        return false
    }

    enum RotationWriteResult {
        case lossless      // 仅重写方向元数据，像素零损伤
        case reencoded     // 格式不支持方向属性，已像素旋转后重编码
        case failed
    }

    /// 把视图旋转（顺时针 turns 个 90°）无损写回文件。
    /// JPEG/HEIC/TIFF 走方向元数据重写；PNG 等回退为像素旋转重编码（PNG 无损）
    static func writeRotation(url: URL, clockwiseTurns: Int) -> RotationWriteResult {
        let fm = FileManager.default
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeID = CGImageSourceGetType(src) else { return .failed }
        let type = typeID as String

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let oldOrientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        let cycle = [1: 6, 6: 3, 3: 8, 8: 1]   // 顺时针 90° 的 EXIF 方向链
        var orientation = oldOrientation == 0 ? 1 : oldOrientation
        for _ in 0..<(clockwiseTurns % 4) { orientation = cycle[orientation] ?? orientation }
        props[kCGImagePropertyOrientation as String] = orientation

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".photoview-rotate-\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, typeID as CFString, 1, nil) else {
            return .failed
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tmp)
            return .failed
        }

        // 校验方向是否真正写入（PNG 等格式可能不支持方向属性）
        var lossless = false
        if let checkSrc = CGImageSourceCreateWithURL(tmp as CFURL, nil),
           let checkProps = CGImageSourceCopyPropertiesAtIndex(checkSrc, 0, nil) as? [String: Any],
           let written = checkProps[kCGImagePropertyOrientation as String] as? Int,
           written == orientation {
            lossless = true
        }
        if !lossless {
            // 回退：按显示方向旋转像素后重编码（PNG 无损；其余 0.95 质量）
            guard let pixels = decodedFull(url: url) else {
                try? fm.removeItem(at: tmp)
                return .failed
            }
            let rotated = ImageLoader.rotated(pixels, quarterTurns: clockwiseTurns % 4)
            guard let rdest = CGImageDestinationCreateWithURL(tmp as CFURL, typeID as CFString, 1, nil) else {
                return .failed
            }
            CGImageDestinationAddImage(rdest, rotated,
                                       [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(rdest) else {
                try? fm.removeItem(at: tmp)
                return .failed
            }
        }
        do {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: tmp, to: url)
        } catch {
            try? fm.removeItem(at: tmp)
            return .failed
        }
        ImageLoader.shared.evict(url: url)
        return lossless ? .lossless : .reencoded
    }

    func evict(url: URL) {
        previewCache.removeObject(forKey: url as NSURL)
        fullCache.removeObject(forKey: url as NSURL)
        thumbCache.removeObject(forKey: url as NSURL)
        infoCache.removeObject(forKey: url as NSURL)
    }

    /// 滑动窗口淘汰用：只清预览/全图，保留缩略图
    func evictPreview(url: URL) { previewCache.removeObject(forKey: url as NSURL) }
    func evictFull(url: URL) { fullCache.removeObject(forKey: url as NSURL) }

    /// 按真实行字节计成本（16 位/HDR 图每像素 8 字节）
    private func pixelBytes(_ image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }
}

final class CGBox: NSObject {
    let image: CGImage
    let px: CGFloat

    init(image: CGImage, px: CGFloat) {
        self.image = image
        self.px = px
        super.init()
    }
}

final class InfoBox: NSObject {
    let info: ImageInfo

    init(_ info: ImageInfo) {
        self.info = info
        super.init()
    }
}

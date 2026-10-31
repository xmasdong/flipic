import AppKit
import CoreGraphics
import IOSurface
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
        // 内存天花板按物理内存取比例：预览 1/48（96~320MB），全图 1/24（192~640MB），全图只留当前与上一张。
        // 8GB 的 Mac 上约 170MB + 340MB，16GB 起才到上限
        let mem = Int(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max)))
        previewCache.countLimit = 12
        previewCache.totalCostLimit = min(max(mem / 48, 96 << 20), 320 << 20)
        fullCache.countLimit = 2
        fullCache.totalCostLimit = min(max(mem / 24, 192 << 20), 640 << 20)
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
        "psd", "tga", "exr", "hdr",
    ]

    /// 常见格式直接按扩展名认；其余只要系统把它归为图片、且 ImageIO 能解码（PSD、TGA、OpenEXR、Radiance HDR、DICOM 等）也收进来。
    /// 结果按扩展名缓存，几千个文件的文件夹也不用每个都查一遍
    static func isSupportedExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if supportedExtensions.contains(ext) { return true }
        extensionLock.lock()
        defer { extensionLock.unlock() }
        if let hit = extensionCache[ext] { return hit }
        var ok = false
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            ok = imageIOTypes.contains { type.conforms(to: $0) }
        }
        extensionCache[ext] = ok
        return ok
    }

    private static let imageIOTypes: [UTType] = ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []).compactMap { UTType($0) }
    private static var extensionCache: [String: Bool] = [:]
    private static let extensionLock = NSLock()

    /// ImageIO 降采样解码：maxPixel 是需要的最大边长像素
    /// allowEmbedded：允许直接用文件内嵌的 EXIF 缩略图（胶片条用，免去整图解码）
    static func renderThumbnail(url: URL, maxPixel: CGFloat, allowEmbedded: Bool = false, hdr: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var options: [CFString: Any] = [
            allowEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if hdr { addHDRRequest(&options) }
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
        guard let decoded = Self.rawEmbeddedPreview(url: url, maxPixel: maxPixel)
                ?? Self.renderThumbnail(url: url, maxPixel: maxPixel, hdr: Self.hdrActive) else { return nil }
        let img = Self.displayReady(decoded)
        previewCache.setObject(CGBox(image: img, px: CGFloat(max(img.width, img.height))),
                               forKey: url as NSURL, cost: pixelBytes(img))
        return img
    }

    /// RAW 先用相机内嵌的 JPEG 预览：4000 万像素的 RAF 冷启动解码要 4 秒，内嵌预览不到 0.1 秒。
    /// 内嵌预览太小（有的相机只存几百像素）就不用，照常解码 RAW；放大到需要细节时由 fullImage 解码 RAW 原图
    static func rawEmbeddedPreview(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard CleanupUnit.isRaw(url),
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        let full = CGFloat(max(props?["PixelWidth"] as? Int ?? 0, props?["PixelHeight"] as? Int ?? 0))
        let need = min(maxPixel, full > 0 ? full : maxPixel)
        return CGFloat(max(img.width, img.height)) >= need * 0.9 ? img : nil
    }

    /// 全分辨率解码（带 EXIF 方向校正），不写缓存；maxPixel 给出时最长边不超过它
    static func decodedFull(url: URL, maxPixel: CGFloat? = nil, hdr: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        var maxSide = max(props?["PixelWidth"] as? Int ?? 0, props?["PixelHeight"] as? Int ?? 0)
        if let maxPixel { maxSide = min(maxSide, Int(maxPixel)) }
        if maxSide > 0 {
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if hdr { addHDRRequest(&options) }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 全分辨率图（带 EXIF 方向校正），供放大查看；只在预览分辨率不够时才解码
    func fullImage(for url: URL) -> CGImage? {
        if let hit = fullCache.object(forKey: url as NSURL) { return hit.image }
        guard let decoded = Self.decodedFull(url: url, maxPixel: Self.displayMaxPixel, hdr: Self.hdrActive) else { return nil }
        let image = Self.displayReady(decoded)
        fullCache.setObject(CGBox(image: image, px: CGFloat(max(image.width, image.height))),
                            forKey: url as NSURL, cost: pixelBytes(image))
        return image
    }

    // MARK: - HDR

    /// 设置里的 HDR 开关，默认关：HDR 照片按 16 位浮点解码，内存是普通照片的两倍
    static var hdrEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "hdrEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "hdrEnabled") }
    }

    /// 系统和屏幕都支持时开关才生效：macOS 14 起 ImageIO 才能按 HDR 解码，屏幕要能把高光提到普通白以上
    static var hdrSupported: Bool {
        guard #available(macOS 14, *) else { return false }
        return NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    static var hdrActive: Bool { hdrEnabled && hdrSupported }

    private static func addHDRRequest(_ options: inout [CFString: Any]) {
        if #available(macOS 14, *) {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
    }

    /// 解出来的是带高光余量的 HDR 图（16 位以上、扩展范围或 PQ / HLG 色彩空间）
    static func isHDR(_ image: CGImage?) -> Bool {
        guard let image, image.bitsPerComponent > 8, let cs = image.colorSpace else { return false }
        if CGColorSpaceUsesExtendedRange(cs) { return true }
        if #available(macOS 11, *), CGColorSpaceUsesITUR_2100TF(cs) { return true }
        return false
    }

    // MARK: - 上屏前准备

    /// 后台把像素画进 IOSurface（显卡能直接读的内存），返回以同一块内存为底的 CGImage：
    /// 主线程设图层时直接交 IOSurface，Core Animation 不必再把几十 MB 像素拷一遍上传，
    /// 放大到 100% 换原图时的主线程卡顿主要就来自那次上传。像素只存一份，内存不增加
    private static let surfaces = NSMapTable<AnyObject, IOSurface>.weakToStrongObjects()
    private static let surfacesLock = NSLock()
    private static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    static func displayReady(_ src: CGImage) -> CGImage {
        // HDR 开着时 HDR 图原样交给图层，画进 8 位 surface 会把高光截掉；
        // 开关关着时（PQ 这类文件本身就是 HDR 编码）画进 8 位，按普通照片显示
        if isHDR(src) && hdrActive { return src }
        let w = src.width, h = src.height
        guard w > 0, h > 0,
              let surface = IOSurface(properties: [
                .width: w, .height: h, .bytesPerElement: 4,
                .pixelFormat: UInt32(0x42475241),   // 'BGRA'
              ]) else { return src }
        surface.lock(options: [], seed: nil)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: surface.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: displaySpace, bitmapInfo: bitmapInfo) else {
            surface.unlock(options: [], seed: nil)
            return src
        }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        surface.unlock(options: [], seed: nil)
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, CGColorSpace.displayP3)
        // CGImage 直接引用 IOSurface 的内存，数据提供者持有 surface，图在 surface 就在
        let length = surface.bytesPerRow * h
        let provider = CGDataProvider(dataInfo: Unmanaged.passRetained(surface).toOpaque(),
                                      data: surface.baseAddress, size: length) { info, _, _ in
            guard let info else { return }
            Unmanaged<IOSurface>.fromOpaque(info).release()
        }
        guard let provider,
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: surface.bytesPerRow, space: displaySpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return src }
        surfacesLock.lock()
        surfaces.setObject(surface, forKey: image)
        surfacesLock.unlock()
        return image
    }

    /// 图层能直接用的 IOSurface；旋转过的图等没有准备过的返回 nil，照常交 CGImage
    static func surface(for image: CGImage?) -> IOSurface? {
        guard let image else { return nil }
        surfacesLock.lock()
        defer { surfacesLock.unlock() }
        return surfaces.object(forKey: image)
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

    /// 缩略图按当前缩略图栏的格子大小解码（Retina 两倍像素）；格子调大后旧的小图不算命中
    func cachedThumb(for url: URL) -> CGImage? {
        guard let hit = thumbCache.object(forKey: url as NSURL), hit.px >= FilmstripView.thumbPixel else { return nil }
        return hit.image
    }

    func thumb(for url: URL) -> CGImage? {
        if let hit = cachedThumb(for: url) { return hit }
        let px = FilmstripView.thumbPixel
        guard let img = Self.renderThumbnail(url: url, maxPixel: px, allowEmbedded: px <= 160) else { return nil }
        thumbCache.setObject(CGBox(image: img, px: px), forKey: url as NSURL, cost: pixelBytes(img))
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

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

    private let previewCache = KeyedCache()
    private let fullCache = KeyedCache()
    private let thumbCache = KeyedCache()
    /// 快速连翻时先顶上的低清草图（JPEG 按 1/4、1/8 整数比例解，RAW 用内嵌预览），清晰预览到了就换掉
    private let draftCache = KeyedCache()
    private let infoCache = NSCache<NSURL, InfoBox>()
    private var pressureSource: DispatchSourceMemoryPressure?
    /// 各看图窗口当前看的照片和它的近邻：内存吃紧时只清离当前远的（主线程读写）
    private let focus = NSMapTable<AnyObject, FocusBox>.weakToStrongObjects()

    /// 屏幕显示用全图的最长边上限：超过 GPU 纹理上限的部分 Core Animation 也显示不出来
    static let displayMaxPixel: CGFloat = 16384

    private init() {
        // 内存天花板按物理内存取比例：预览 1/48（96~320MB），全图 1/24（192~640MB），全图只留当前与上一张。
        // 8GB 的 Mac 上约 170MB + 340MB，16GB 起才到上限；草图 1/160（48~96MB），一张 4500 万像素的草图约 11MB
        let mem = Int(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max)))
        previewCache.countLimit = 12
        previewCache.totalCostLimit = min(max(mem / 48, 96 << 20), 320 << 20)
        fullCache.countLimit = 2
        fullCache.totalCostLimit = min(max(mem / 24, 192 << 20), 640 << 20)
        thumbCache.countLimit = 800
        draftCache.countLimit = 8
        draftCache.totalCostLimit = min(max(mem / 160, 48 << 20), 96 << 20)
        infoCache.countLimit = 4000

        // 系统内存吃紧时主动让出，但不全清：警告时清原图和离当前远的预览，留缩略图和前后两张；
        // 严重时只留当前这张。忙碌的 16GB Mac 上警告会反复来，全清的话预取的邻居和缩略图一次次白解
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            self?.handleMemoryPressure(critical: source?.data.contains(.critical) ?? false)
        }
        source.resume()
        pressureSource = source
    }

    /// 看图窗口每次换图时报告当前照片、前后两张（near）、草图要留的范围（near 加上浏览方向前方，ahead）
    /// 和胶片条预热范围（wide）
    func setFocus(owner: AnyObject, current: URL, near: Set<URL>, ahead: Set<URL>, wide: Set<URL>) {
        focus.setObject(FocusBox(current: current, near: near, ahead: ahead, wide: wide), forKey: owner)
    }

    /// 停下来以后草图就用不上了（清晰预览接手），只留 keep 里的
    func trimDrafts(keeping keep: Set<URL>) {
        draftCache.removeAll(except: keep)
    }

    /// 屏幕上的图由图层持有，清缓存不影响当前显示
    func handleMemoryPressure(critical: Bool) {
        var current = Set<URL>(), near = Set<URL>(), ahead = Set<URL>(), wide = Set<URL>()
        for case let box? in focus.objectEnumerator()?.allObjects.map({ $0 as? FocusBox }) ?? [] {
            current.insert(box.current)
            near.formUnion(box.near)
            ahead.formUnion(box.ahead)
            wide.formUnion(box.wide)
        }
        near.formUnion(current)
        fullCache.removeAll(except: current)
        previewCache.removeAll(except: critical ? current : near)
        // 草图一张约 11MB、总共不超过 96MB，警告时留着快速连翻前方要用的
        draftCache.removeAll(except: critical ? current : near.union(ahead))
        if critical { thumbCache.removeAll(except: wide.union(near)) }
    }

    func purge() {
        previewCache.removeAll()
        fullCache.removeAll()
        thumbCache.removeAll()
        draftCache.removeAll()
    }

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "webp", "gif", "bmp",
        "tif", "tiff", "jp2", "jxl", "avif", "ico", "icns",
        "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
        "nrw", "crw", "sr2", "srf", "3fr", "fff", "iiq", "erf", "rwl", "mrw", "kdc", "dcr", "mef", "mos", "gpr", "x3f",
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

    /// 要整张解码的文件一次读进内存再交给 ImageIO。ImageIO 自己按页读文件会拆成几十上百次小 IO，
    /// 系统忙（别的程序在大量读写，或我们的后台队列被降级）时每次小 IO 都要排队节流，一张图能拖到一两秒；一次读完只排一次队。
    /// RAW（往往只用到内嵌预览那一段）和特别大的文件照旧按需读
    static func imageSource(url: URL) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if !CleanupUnit.isRaw(url),
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 << 20,
           let data = try? Data(contentsOf: url) {
            return CGImageSourceCreateWithData(data as CFData, options)
        }
        return CGImageSourceCreateWithURL(url as CFURL, options)
    }

    /// ImageIO 降采样解码：maxPixel 是需要的最大边长像素
    /// allowEmbedded：允许直接用文件内嵌的 EXIF 缩略图（胶片条用，免去整图解码）
    static func renderThumbnail(url: URL, maxPixel: CGFloat, allowEmbedded: Bool = false, hdr: Bool = false) -> CGImage? {
        if Video.isVideo(url) { return Video.poster(url, maxPixel: maxPixel) }
        // 用内嵌缩略图时只读文件头那一小段，不整个读
        let src = allowEmbedded
            ? CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            : imageSource(url: url)
        let simulateOld = debugIgnoreSystemRAW && !allowEmbedded && CleanupUnit.isRaw(url)
        if !simulateOld, let src, let img = renderThumbnail(source: src, maxPixel: maxPixel, allowEmbedded: allowEmbedded, hdr: hdr) { return img }
        // 系统还不支持这台相机的 RAW：用文件里的 JPEG 预览
        return CleanupUnit.isRaw(url) ? EmbeddedPreview.image(url, maxPixel: maxPixel) : nil
    }

    static func renderThumbnail(source src: CGImageSource, maxPixel: CGFloat, allowEmbedded: Bool = false, hdr: Bool = false) -> CGImage? {
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
        fullCache.object(url)?.image
    }

    func cachedInfo(for url: URL) -> ImageInfo? {
        infoCache.object(forKey: url as NSURL)?.info
    }

    /// 只读文件头拿原图尺寸与动图标记，不解码像素
    func info(for url: URL) -> ImageInfo? {
        if let hit = infoCache.object(forKey: url as NSURL) { return hit.info }
        if Video.isVideo(url) {
            guard let m = Video.meta(url) else { return nil }
            let info = ImageInfo(pixelSize: m.size, isAnimated: false)
            infoCache.setObject(InfoBox(info), forKey: url as NSURL)
            return info
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return embeddedInfo(for: url)
        }
        return info(for: url, source: src)
    }

    /// 系统读不出尺寸的 RAW：按内嵌 JPEG 预览的尺寸算
    private func embeddedInfo(for url: URL) -> ImageInfo? {
        guard CleanupUnit.isRaw(url), let f = EmbeddedPreview.locate(url) else { return nil }
        let info = ImageInfo(pixelSize: f.size, isAnimated: false)
        infoCache.setObject(InfoBox(info), forKey: url as NSURL)
        return info
    }

    private func info(for url: URL, source src: CGImageSource) -> ImageInfo? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return embeddedInfo(for: url) }
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        if w == 0 || h == 0, let e = embeddedInfo(for: url) { return e }
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        let info = ImageInfo(pixelSize: swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h),
                             isAnimated: Self.isAnimated(source: src, props: props))
        infoCache.setObject(InfoBox(info), forKey: url as NSURL)
        return info
    }

    /// 已缓存且分辨率够用的预览图（不触发解码，可在主线程调用）
    func cachedPreview(for url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let hit = previewCache.object(url) else { return nil }
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
        previewCache.set(CGBox(image: img, px: CGFloat(max(img.width, img.height))), for: url, cost: pixelBytes(img))
        draftCache.remove(url)
        return img
    }

    // MARK: - 草图

    func cachedDraft(for url: URL) -> CGImage? {
        draftCache.object(url)?.image
    }

    /// 草图的最长边：JPEG 按 DCT 整数比例（1/4，太大就 1/8）解码最快，
    /// 4500 万像素的图 1/4 是 2064 像素，约 30ms（屏幕尺寸预览要 75ms，弱机上翻倍）；比例对不上要多一轮缩放，反而更慢
    static func draftPixel(fullSide: CGFloat) -> CGFloat {
        let quarter = (fullSide / 4).rounded(.up)
        return quarter <= 2400 ? quarter : (fullSide / 8).rounded(.up)
    }

    /// 快速草图：JPEG 等按整数比例降采样，RAW 用相机内嵌的预览。动图不出草图（直接走正常加载）。
    /// 原图本身不比屏幕大多少时直接解清晰预览，返回 sharp = true
    func draft(for url: URL, previewPixel: CGFloat) -> (image: CGImage, sharp: Bool)? {
        if let hit = cachedPreview(for: url, maxPixel: previewPixel) { return (hit, true) }
        if let hit = cachedDraft(for: url) { return (hit, false) }
        // 视频只取一帧，没有更快的草图
        if Video.isVideo(url) { return preview(for: url, maxPixel: previewPixel).map { ($0, true) } }
        // 非 RAW 整个文件读一次，读文件头和解码共用，不再为文件头单独开一次文件
        let raw = CleanupUnit.isRaw(url)
        let src = raw ? nil : Self.imageSource(url: url)
        guard let info = cachedInfo(for: url) ?? src.flatMap({ info(for: url, source: $0) }) ?? info(for: url),
              !info.isAnimated else { return nil }
        let side = max(info.pixelSize.width, info.pixelSize.height)
        if side <= previewPixel * 1.6 {
            guard let pv = preview(for: url, maxPixel: previewPixel) else { return nil }
            return (pv, true)
        }
        let px = Self.draftPixel(fullSide: side)
        let decoded = src.map { Self.renderThumbnail(source: $0, maxPixel: px, hdr: Self.hdrActive) }
            ?? Self.rawEmbeddedPreview(url: url, maxPixel: px)
        guard let decoded else { return nil }
        // 顺手给胶片条出一张缩略图，省得它再把整张原图解一遍
        if cachedThumb(for: url) == nil { storeThumb(downscaling: decoded, for: url) }
        let img = Self.displayReady(decoded)
        draftCache.set(CGBox(image: img, px: CGFloat(max(img.width, img.height))), for: url, cost: pixelBytes(img))
        return (img, false)
    }

    private func storeThumb(downscaling src: CGImage, for url: URL) {
        let px = FilmstripView.thumbPixel
        let k = min(1, px / CGFloat(max(src.width, src.height)))
        let w = max(1, Int((CGFloat(src.width) * k).rounded())), h = max(1, Int((CGFloat(src.height) * k).rounded()))
        let space = src.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard !Self.isHDR(src),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return }
        thumbCache.set(CGBox(image: img, px: px), for: url, cost: pixelBytes(img))
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
        if Video.isVideo(url) { return Video.poster(url, maxPixel: maxPixel) }
        if !(debugIgnoreSystemRAW && CleanupUnit.isRaw(url)), let img = systemDecodedFull(url: url, maxPixel: maxPixel, hdr: hdr) { return img }
        return CleanupUnit.isRaw(url) ? EmbeddedPreview.image(url, maxPixel: maxPixel) : nil
    }

    /// 测试用：当作系统解不了 RAW（缩略图照常），在新系统上模拟老 macOS 打开新相机 RAW 的样子
    static let debugIgnoreSystemRAW = UserDefaults.standard.bool(forKey: "debugIgnoreSystemRAW")

    private static func systemDecodedFull(url: URL, maxPixel: CGFloat?, hdr: Bool) -> CGImage? {
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
        if let hit = fullCache.object(url) { return hit.image }
        guard let decoded = Self.decodedFull(url: url, maxPixel: Self.displayMaxPixel, hdr: Self.hdrActive) else { return nil }
        let image = Self.displayReady(decoded)
        fullCache.set(CGBox(image: image, px: CGFloat(max(image.width, image.height))), for: url, cost: pixelBytes(image))
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

    /// 文件本身带透明（PNG、GIF、HEIC、TIFF 的 alpha 通道）的图。上屏前统一画成带 alpha 的 BGRA，
    /// 光看上屏后的像素格式分不出来，所以在转换前按 ImageIO 解出的原始格式记下
    private static let transparentImages = NSHashTable<AnyObject>.weakObjects()

    static func hasAlphaChannel(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }

    static func isTransparent(_ img: CGImage?) -> Bool {
        guard let img else { return false }
        surfacesLock.lock(); defer { surfacesLock.unlock() }
        return transparentImages.contains(img)
    }

    static func displayReady(_ src: CGImage) -> CGImage {
        let out = makeDisplayReady(src)
        if hasAlphaChannel(src) {
            surfacesLock.lock(); transparentImages.add(out); surfacesLock.unlock()
        }
        return out
    }

    private static func makeDisplayReady(_ src: CGImage) -> CGImage {
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
        guard let hit = thumbCache.object(url), hit.px >= FilmstripView.thumbPixel else { return nil }
        return hit.image
    }

    func thumb(for url: URL) -> CGImage? {
        if let hit = cachedThumb(for: url) { return hit }
        let px = FilmstripView.thumbPixel
        guard let img = Self.renderThumbnail(url: url, maxPixel: px, allowEmbedded: px <= 160) else { return nil }
        // 顺带读文件头：快速连翻时缩略图能先顶上去，要知道原图尺寸才摆得对
        _ = info(for: url)
        thumbCache.set(CGBox(image: img, px: px), for: url, cost: pixelBytes(img))
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
        FolderWatcher.noteOwnWrite(url)
        ImageLoader.shared.evict(url: url)
        return lossless ? .lossless : .reencoded
    }

    func evict(url: URL) {
        Video.forget(url)
        previewCache.remove(url)
        fullCache.remove(url)
        thumbCache.remove(url)
        draftCache.remove(url)
        infoCache.removeObject(forKey: url as NSURL)
    }

    /// 滑动窗口淘汰用：只清预览/草图/全图，保留缩略图
    func evictPreview(url: URL) {
        previewCache.remove(url)
        draftCache.remove(url)
    }
    func evictFull(url: URL) { fullCache.remove(url) }

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

/// NSCache 不能列出键：另记一份写进去过的 URL，内存吃紧时才能只清离当前远的。
/// 被 NSCache 自己淘汰掉的键留在集合里无妨，清理时顺带去掉
final class KeyedCache {
    private let cache = NSCache<NSURL, CGBox>()
    private var keys = Set<URL>()
    private let lock = NSLock()

    var countLimit: Int {
        get { cache.countLimit }
        set { cache.countLimit = newValue }
    }
    var totalCostLimit: Int {
        get { cache.totalCostLimit }
        set { cache.totalCostLimit = newValue }
    }

    func object(_ url: URL) -> CGBox? { cache.object(forKey: url as NSURL) }

    func set(_ box: CGBox, for url: URL, cost: Int) {
        lock.lock()
        keys.insert(url)
        lock.unlock()
        cache.setObject(box, forKey: url as NSURL, cost: cost)
    }

    func remove(_ url: URL) {
        lock.lock()
        keys.remove(url)
        lock.unlock()
        cache.removeObject(forKey: url as NSURL)
    }

    func removeAll() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
        cache.removeAllObjects()
    }

    func removeAll(except keep: Set<URL>) {
        lock.lock()
        let drop = keys.subtracting(keep)
        keys.formIntersection(keep)
        lock.unlock()
        for url in drop { cache.removeObject(forKey: url as NSURL) }
    }
}

final class FocusBox: NSObject {
    let current: URL
    let near: Set<URL>
    let ahead: Set<URL>
    let wide: Set<URL>

    init(current: URL, near: Set<URL>, ahead: Set<URL>, wide: Set<URL>) {
        self.current = current
        self.near = near
        self.ahead = ahead
        self.wide = wide
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

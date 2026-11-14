import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 拷贝单张照片时，剪贴板上除了文件地址还答应给图片本身（TIFF）：预览的「从剪贴板新建」、浏览器、修图软件要的是像素。
/// 拷贝时不解码，对方来要的时候才解：原图分辨率、按 EXIF 方向转正。
/// RAW 先用相机内嵌的预览（看图界面先显示的也是它，解一张 JPEG 比解 RAW 快一个量级），
/// 内嵌预览长边不到 minEmbeddedSide 的才解 RAW。只给 TIFF：PNG 要压缩，4000 万像素要好几秒，收图的一方都认 TIFF
final class PhotoPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    static let types: [NSPasteboard.PasteboardType] = [.tiff]
    /// 内嵌预览长边至少这么多像素才拿来当图片数据，再小就不如解 RAW
    static let minEmbeddedSide = 2000

    /// 剪贴板还用得着的那些：剪贴板换了内容会通知，那时才放手
    private static var live: [PhotoPasteboardProvider] = []

    let url: URL
    /// 自测用：解码过几次（没人来要应该一直是 0）、用的哪条路、解码和编码各用了多少毫秒
    private(set) var debugDecodes = 0
    private(set) var debugSource = "-"
    private(set) var debugDecodeMs = 0.0
    private(set) var debugEncodeMs = 0.0
    /// 自测用：来要数据时打一行日志（看退出时系统会不会来要）
    static var debugLog = false

    init(url: URL) {
        self.url = url
        super.init()
        Self.live.append(self)
    }

    /// 文件地址加上「要的时候再给」的图片数据
    func makeItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setDataProvider(self, forTypes: Self.types)
        return item
    }

    private func decode() -> CGImage? {
        if CleanupUnit.isRaw(url) {
            // 和原图差不多大的内嵌预览（系统认得的 RAW）；没有就在文件里找最大的那张内嵌 JPEG
            if let img = ImageLoader.rawEmbeddedPreview(url: url, maxPixel: ImageLoader.displayMaxPixel),
               max(img.width, img.height) >= Self.minEmbeddedSide {
                debugSource = "embedded"
                return img
            }
            if let f = EmbeddedPreview.locate(url), Int(max(f.size.width, f.size.height)) >= Self.minEmbeddedSide,
               let img = EmbeddedPreview.image(url) {
                debugSource = "embedded-scan"
                return img
            }
        }
        debugSource = "full"
        return ImageLoader.decodedFull(url: url, maxPixel: ImageLoader.displayMaxPixel)
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let image = decode()
        debugDecodes += 1
        debugDecodeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard let image else { return }
        let t1 = CFAbsoluteTimeGetCurrent()
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) { item.setData(data as Data, forType: type) }
        debugEncodeMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        if Self.debugLog {
            NSLog("COPYIMG provide tiff %@ source=%@ decode=%.0fms encode=%.0fms bytes=%d", url.lastPathComponent, debugSource, debugDecodeMs, debugEncodeMs, data.length)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if Self.debugLog { NSLog("COPYIMG finished %@", url.lastPathComponent) }
        Self.live.removeAll { $0 === self }
    }

    static var debugLiveCount: Int { live.count }
    static var debugLast: PhotoPasteboardProvider? { live.last }
}

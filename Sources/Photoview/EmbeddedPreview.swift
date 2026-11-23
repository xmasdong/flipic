import Foundation
import ImageIO

/// 系统解不了的相机 RAW：新机型的 RAW 要等 macOS 更新才支持，没更新的系统上 ImageIO 解出来是空的。
/// 这时改读相机写进文件里的 JPEG 预览。几乎所有 RAW 都带一张全尺寸或接近全尺寸的 JPEG，挑片看它足够。
/// 不按各家格式逐个解析（CR3 是 ISO 媒体容器，CR2/NEF/ARW/DNG 是 TIFF，RAF 有自己的文件头），
/// 直接在文件里找 JPEG 的开头（FF D8 FF），让 ImageIO 只读文件头报尺寸，取像素最多的那张
enum EmbeddedPreview {
    struct Found {
        let offset: Int
        let size: CGSize        // 已按方向转正
        let orientation: Int    // EXIF 方向，1 = 不用转
    }

    private final class Box { let found: Found?; init(_ f: Found?) { found = f } }
    private static let cache = NSCache<NSURL, Box>()

    /// 文件里最大的那张内嵌 JPEG；没有返回 nil。结果按文件缓存（含「没找到」）
    static func locate(_ url: URL) -> Found? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.found }
        let found = scan(url)
        cache.setObject(Box(found), forKey: url as NSURL)
        return found
    }

    /// 文件改过（比如无损转了方向）后丢掉缓存的结果
    static func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }

    /// 解出内嵌 JPEG，按 RAW 记录的方向转正；maxPixel 给出时最长边不超过它。
    /// 冷读优化：如果尚未缓存定位信息，直接一次大块顺序读出前 4 MB，在内存中同时完成方向读取、JPEG 定位与解码，
    /// 绝大多数相机 RAW 只需 1 次顺序读即可出图（省去原先 scan + image 的 3 次独立打开）。
    static func image(_ url: URL, maxPixel: CGFloat? = nil) -> CGImage? {
        var found: Found?
        var prefixData: Data?
        if let hit = cache.object(forKey: url as NSURL) {
            found = hit.found
        } else {
            let res = scanRetainingPrefix(url)
            cache.setObject(Box(res.found), forKey: url as NSURL)
            found = res.found
            prefixData = res.prefix
        }
        guard let f = found else { return nil }

        // 若内嵌 JPEG 完整落在已读入内存的前 4 MB 缓冲中，直接原地解码，0 次额外磁盘打开
        if let prefix = prefixData, f.offset < prefix.count {
            let slice = prefix.subdata(in: f.offset..<prefix.count)
            if hasJPEGEndMarker(slice), let img = decodeJPEGSlice(slice, found: f, maxPixel: maxPixel) {
                return img
            }
        }

        let sliceData: Data
        if let chunk = DiskIO.readFileSlice(url, offset: f.offset, maxBytes: 16 << 20), !chunk.isEmpty {
            sliceData = chunk
        } else if let data = try? Data(contentsOf: url, options: .alwaysMapped), f.offset < data.count {
            sliceData = data.subdata(in: f.offset..<min(data.count, f.offset + (16 << 20)))
        } else {
            return nil
        }
        return decodeJPEGSlice(sliceData, found: f, maxPixel: maxPixel)
    }

    private static func decodeJPEGSlice(_ sliceData: Data, found f: Found, maxPixel: CGFloat?) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(sliceData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let side = max(f.size.width, f.size.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? side, side),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return oriented(img, f.orientation)
    }

    /// 检查内存切片里是否已包含完整 JPEG 尾标记（FF D9），确保截断的预览不会半张解码
    private static func hasJPEGEndMarker(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            var i = data.count - 2
            while i >= 2 {
                if base[i] == 0xFF && base[i + 1] == 0xD9 { return true }
                i -= 1
            }
            return false
        }
    }

    /// 测试用：这个文件是否走过内嵌预览
    static func debugUsed(_ url: URL) -> Bool { cache.object(forKey: url as NSURL)?.found != nil }

    // MARK: - 扫描

    /// 最多试这么多个疑似 JPEG 开头：压缩过的 RAW 数据里偶尔会碰巧出现 FF D8 FF
    private static let maxCandidates = 400
    /// 快速前缀扫描上限（4 MB）：绝大多数相机 RAW 的全尺寸内嵌 JPEG 预览都在前 4 MB 内，命中直接停，免去在慢盘上读完整个 60 MB 文件
    private static let fastPrefixBytes = 4 << 20

    private static func scanBytes(_ data: Data) -> (offset: Int, w: Int, h: Int, orientation: Int?)? {
        data.withUnsafeBytes { raw -> (offset: Int, w: Int, h: Int, orientation: Int?)? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let n = raw.count
            var best: (offset: Int, w: Int, h: Int, orientation: Int?)?
            var tried = 0
            var i = 0
            while i < n - 4, tried < maxCandidates {
                guard let p = memchr(base + i, 0xFF, n - 4 - i) else { break }
                i = UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self) - base
                if base[i + 1] == 0xD8, base[i + 2] == 0xFF,
                   (0xE0...0xEF).contains(base[i + 3]) || [0xDB, 0xC4, 0xC0, 0xFE].contains(base[i + 3]) {
                    tried += 1
                    let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + i), count: n - i, deallocator: .none)
                    if let src = CGImageSourceCreateWithData(slice as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                       CGImageSourceGetType(src) as String? == "public.jpeg",
                       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
                       let w = props[kCGImagePropertyPixelWidth as String] as? Int,
                       let h = props[kCGImagePropertyPixelHeight as String] as? Int, w >= 64, h >= 64,
                       w * h > (best.map { $0.w * $0.h } ?? 0) {
                        best = (i, w, h, props[kCGImagePropertyOrientation as String] as? Int)
                    }
                }
                i += 1
            }
            return best
        }
    }

    private static func scan(_ url: URL) -> Found? {
        scanRetainingPrefix(url).found
    }

    private static func scanRetainingPrefix(_ url: URL) -> (found: Found?, prefix: Data?) {
        let slow = Volumes.isSlowStorage(url)
        // 先一次大块顺序读出前 4 MB（开启 F_RDAHEAD）：同时用于方向解析与内嵌 JPEG 扫描，
        // 慢盘上不再先拿 CGImageSourceCreateWithURL 去触发几十次随机小读
        let prefix = DiskIO.readFileData(url, maxBytes: fastPrefixBytes)
        var rawOrientation: Int?
        if !RawOrientation.forceUnrecognised {
            if let prefix,
               let src = CGImageSourceCreateWithData(prefix as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                rawOrientation = props[kCGImagePropertyOrientation as String] as? Int
            }
            if rawOrientation == nil && !slow,
               let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                rawOrientation = props[kCGImagePropertyOrientation as String] as? Int
            }
        }

        var best: (offset: Int, w: Int, h: Int, orientation: Int?)?
        if let prefix, prefix.count > 16 {
            let candidate = scanBytes(prefix)
            if let candidate, max(candidate.w, candidate.h) >= 1024 { best = candidate }
            else if prefix.count < fastPrefixBytes { best = candidate }
        }
        if best == nil, let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16 {
            best = scanBytes(data)
        }
        guard let best else { return (nil, nil) }
        if rawOrientation == nil && best.orientation == nil {
            rawOrientation = RawOrientation.fileOrientation(url)
        }
        let o = rawOrientation ?? best.orientation ?? 1
        let swapped = (5...8).contains(o)
        let found = Found(offset: best.offset,
                          size: swapped ? CGSize(width: best.h, height: best.w) : CGSize(width: best.w, height: best.h),
                          orientation: o)
        return (found, prefix)
    }

    /// EXIF 方向转正：相机只会写 1、3、6、8（不翻转）；其余按不转处理
    private static func oriented(_ img: CGImage, _ o: Int) -> CGImage {
        switch o {
        case 3: return ImageLoader.rotated(img, quarterTurns: 2)
        case 6: return ImageLoader.rotated(img, quarterTurns: 1)
        case 8: return ImageLoader.rotated(img, quarterTurns: 3)
        default: return img
        }
    }
}

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
    /// 外接慢盘上只从 offset 开始读最多 16 MB，不再把整张 60–100 MB RAW 全映射进内存
    static func image(_ url: URL, maxPixel: CGFloat? = nil) -> CGImage? {
        guard let f = locate(url) else { return nil }
        let sliceData: Data
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: UInt64(f.offset))
            guard let chunk = try? fh.read(upToCount: 16 << 20), !chunk.isEmpty else { return nil }
            sliceData = chunk
        } else {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), f.offset < data.count else { return nil }
            sliceData = data.subdata(in: f.offset..<min(data.count, f.offset + (16 << 20)))
        }
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
        // RAW 自己的方向（TIFF 类 RAW 的 IFD0、CR3 的 CMT1）：ImageIO 解不了像素时通常还读得出元数据
        var rawOrientation: Int?
        if !RawOrientation.forceUnrecognised,
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            rawOrientation = props[kCGImagePropertyOrientation as String] as? Int
        }
        if rawOrientation == nil { rawOrientation = RawOrientation.fileOrientation(url) }

        // 先扫前 4 MB：如果已经找到清晰大图（≥ 1024px），不用把整张几十 MB 的 RAW 从外接盘读一遍
        var best: (offset: Int, w: Int, h: Int, orientation: Int?)?
        if let fh = try? FileHandle(forReadingFrom: url) {
            let prefix = (try? fh.read(upToCount: fastPrefixBytes)) ?? Data()
            try? fh.close()
            if prefix.count > 16 {
                let candidate = scanBytes(prefix)
                if let candidate, max(candidate.w, candidate.h) >= 1024 { best = candidate }
                else if prefix.count < fastPrefixBytes { best = candidate }
            }
        }
        if best == nil, let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16 {
            best = scanBytes(data)
        }
        guard let best else { return nil }
        let o = rawOrientation ?? best.orientation ?? 1
        let swapped = (5...8).contains(o)
        return Found(offset: best.offset,
                     size: swapped ? CGSize(width: best.h, height: best.w) : CGSize(width: best.w, height: best.h),
                     orientation: o)
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

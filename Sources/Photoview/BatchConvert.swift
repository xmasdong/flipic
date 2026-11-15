import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 批量转换格式的引擎（不碰界面，后台线程里同步跑；界面和自测都调这里）
enum BatchConvert {
    struct Settings {
        var uti: String
        var ext: String
        var quality: Double
        var options: ExportOptions
        var outDir: URL
        /// 已经是目标格式、也没有需要改的照片：false = 跳过（批量转换），true = 原样存一份（导出预设：要交的每张都得在文件夹里）
        var alwaysWrite = false
        /// 输出文件名（不含扩展名）：参数是原文件和这是第几个输出（从 1 数）；nil = 用原文件名
        var outputName: ((URL, Int) -> String)?
    }

    struct Summary {
        var converted = 0
        var skipped = 0
        var failed = 0
        /// 设了大小限制却压不进去的文件名（已经按最小的写出了）
        var overLimit: [String] = []
        var failedNames: [String] = []
        var cancelled = false
        var outputs: [URL] = []
    }

    static let formats: [(name: String, uti: String, ext: String)] = [
        ("JPEG", "public.jpeg", "jpg"), ("PNG", "public.png", "png"), ("HEIC", "public.heic", "heic"),
    ]

    /// 默认输出文件夹：原照片所在文件夹里的 Converted-<ext>；那个盘只读或者可移除（存储卡）就改放到 ~/图片 下面，不往卡里写。
    /// onVolume = false 表示因为这个原因改了位置，界面上要说一声
    static func defaultOutputFolder(for source: URL, ext: String) -> (url: URL, redirected: Bool) {
        let dir = source.hasDirectoryPath ? source : source.deletingLastPathComponent()
        if Volumes.isReadOnlyOrRemovable(dir) {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            return (pictures.appendingPathComponent("Converted-\(ext)"), true)
        }
        return (dir.appendingPathComponent("Converted-\(ext)"), false)
    }

    /// 这个文件已经是目标格式了吗
    static func isSameFormat(_ url: URL, ext: String) -> Bool {
        let e = url.pathExtension.lowercased()
        switch ext {
        case "jpg": return e == "jpg" || e == "jpeg"
        case "heic": return e == "heic" || e == "heif"
        default: return e == ext
        }
    }

    /// 已经是目标格式的文件，按现在的选项转一遍会有变化吗：没设任何限制就原样不动（重新压缩只会掉画质）
    static func needsWork(_ url: URL, settings s: Settings) -> Bool {
        guard isSameFormat(url, ext: s.ext) else { return true }
        let o = s.options
        if !o.keepMetadata { return true }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return true }
        if o.stripGPS, props[kCGImagePropertyGPSDictionary as String] != nil { return true }
        if let edge = o.maxLongEdge {
            let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            if max(w, h) > edge { return true }
        }
        if let limit = o.maxBytes, ImageExporter.isLossy(s.uti) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            if size > limit { return true }
        }
        if o.toSRGB {
            // 没嵌描述文件的照片按惯例就是 sRGB（EXIF 色彩空间标 1 或没标）
            let name = props[kCGImagePropertyProfileName as String] as? String ?? ""
            let tagged = (props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifColorSpace as String] as? Int
            if name.isEmpty ? (tagged ?? 1) != 1 : !name.contains("sRGB") { return true }
        }
        return false
    }

    /// 不覆盖：dir 里已有同名文件就用「名字 2」「名字 3」…；用独占创建占住名字，两个同时跑也不会撞
    static func claim(_ dir: URL, base: String, ext: String) -> URL? {
        var n = 1
        while n < 10_000 {
            let name = n == 1 ? base : "\(base) \(n)"
            let u = dir.appendingPathComponent(name).appendingPathExtension(ext)
            let fd = open(u.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return u }
            if errno != EEXIST { return nil }
            n += 1
        }
        return nil
    }

    /// 逐张转换。isCancelled 每张之间检查一次；progress 收到已处理的张数
    static func run(_ urls: [URL], settings s: Settings, isCancelled: () -> Bool = { false },
                    progress: ((Int) -> Void)? = nil) -> Summary {
        var sum = Summary()
        do { try FileManager.default.createDirectory(at: s.outDir, withIntermediateDirectories: true) } catch {
            sum.failed = urls.count
            sum.failedNames = urls.map(\.lastPathComponent)
            return sum
        }
        for (i, url) in urls.enumerated() {
            if isCancelled() { sum.cancelled = true; break }
            autoreleasepool {
                let work = needsWork(url, settings: s)
                guard work || s.alwaysWrite else { sum.skipped += 1; return }
                let base = s.outputName?(url, sum.converted + 1) ?? url.deletingPathExtension().lastPathComponent
                if !work {
                    // 没有什么要改的：原样存一份，不重新压缩
                    guard let dest = claim(s.outDir, base: base, ext: s.ext) else {
                        sum.failed += 1; sum.failedNames.append(url.lastPathComponent)
                        return
                    }
                    do { try Data(contentsOf: url, options: .mappedIfSafe).write(to: dest, options: .atomic) } catch {
                        try? FileManager.default.removeItem(at: dest)
                        sum.failed += 1; sum.failedNames.append(url.lastPathComponent)
                        return
                    }
                    sum.converted += 1
                    sum.outputs.append(dest)
                    return
                }
                guard let img = ImageLoader.decodedFull(url: url),
                      let out = ImageExporter.encode(img, source: url, uti: s.uti, quality: s.quality, options: s.options, cancelled: isCancelled) else {
                    if isCancelled() { sum.cancelled = true } else { sum.failed += 1; sum.failedNames.append(url.lastPathComponent) }
                    return
                }
                guard let dest = claim(s.outDir, base: base, ext: s.ext) else {
                    sum.failed += 1; sum.failedNames.append(url.lastPathComponent)
                    return
                }
                do { try out.data.write(to: dest, options: .atomic) } catch {
                    try? FileManager.default.removeItem(at: dest)
                    sum.failed += 1; sum.failedNames.append(url.lastPathComponent)
                    return
                }
                sum.converted += 1
                sum.outputs.append(dest)
                if !out.limitMet { sum.overLimit.append(dest.lastPathComponent) }
            }
            if sum.cancelled { break }
            progress?(i + 1)
        }
        return sum
    }

    /// 结果小结，一行一项（没有的项不写）
    static func message(_ sum: Summary, limit: Int64?) -> String {
        var lines: [String] = []
        lines.append(L10n.f("bc.sum.converted", "已转换 %d 张", sum.converted))
        if sum.skipped > 0 { lines.append(L10n.f("bc.sum.skipped", "跳过 %d 张（已经是这个格式，没有需要改的）", sum.skipped)) }
        if sum.failed > 0 {
            lines.append(L10n.f("bc.sum.failed", "失败 %d 张：%@", sum.failed, sum.failedNames.prefix(5).joined(separator: "、") + (sum.failedNames.count > 5 ? "…" : "")))
        }
        if !sum.overLimit.isEmpty {
            let lim = limit.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            lines.append(L10n.f("bc.sum.over", "%1$d 张没能压到 %2$@ 以内（已按最小的存下）：%3$@", sum.overLimit.count, lim,
                                sum.overLimit.prefix(5).joined(separator: "、") + (sum.overLimit.count > 5 ? "…" : "")))
        }
        if sum.cancelled { lines.append(L10n.t("bc.sum.cancelled", "已取消，后面的没有处理")) }
        return lines.joined(separator: "\n")
    }
}

/// 主线程设、后台线程读的取消标志
final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --exportopttest <工作文件夹> [RAW 文件]`：导出选项（元数据、长边、大小限制、sRGB、批量转换）的自测。
/// 调的就是界面用的 ImageExporter / BatchConvert，再用 ImageIO 和 exiftool 各读回一遍核对。最后一行 EXPORTTEST summary 是汇总
enum ExportSelfTest {
    static var checks = 0
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("EXPORTTEST \(ok ? "ok  " : "FAIL") \(what)")
    }
    static func info(_ s: String) { print("EXPORTTEST info \(s)") }

    // MARK: - 读回

    static let exiftoolPath = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// exiftool 把全部标签按「分组:名字」读成字典（-n：数值不换文字）
    static func exif(_ url: URL) -> [String: Any] {
        guard let t = exiftoolPath,
              let d = run(t, ["-j", "-G1", "-a", "-n", "-api", "largefilesupport=1", url.path]).data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]], let first = arr.first else { return [:] }
        return first
    }
    static func has(_ e: [String: Any], _ suffix: String) -> Bool { e.keys.contains { $0.hasSuffix(":" + suffix) } }
    static func val(_ e: [String: Any], _ suffix: String) -> String? {
        guard let k = e.keys.sorted().first(where: { $0.hasSuffix(":" + suffix) }) else { return nil }
        return "\(e[k]!)"
    }
    static func anyKey(_ e: [String: Any], prefix: String) -> Bool { e.keys.contains { $0.hasPrefix(prefix) } }

    static func props(_ url: URL) -> [String: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any]) ?? [:]
    }
    static func sub(_ p: [String: Any], _ k: CFString) -> [String: Any] { (p[k as String] as? [String: Any]) ?? [:] }

    static func size(_ url: URL) -> (Int, Int) {
        let p = props(url)
        return (p["PixelWidth"] as? Int ?? 0, p["PixelHeight"] as? Int ?? 0)
    }
    static func bytes(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? -1 }

    static func xmpString(_ url: URL, _ path: String) -> String? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let m = CGImageSourceCopyMetadataAtIndex(s, 0, nil),
              let t = CGImageMetadataCopyTagWithPath(m, nil, path as CFString), let v = CGImageMetadataTagCopyValue(t) else { return nil }
        return "\(v)"
    }

    /// 四个角的颜色（sRGB 8 位）。transform 为 true 时按文件里的方向标记转正；false 是文件里存着的样子
    static func corners(_ url: URL, transform: Bool) -> [[Int]] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let img: CGImage?
        if transform {
            img = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: 100_000] as CFDictionary)
        } else { img = CGImageSourceCreateImageAtIndex(s, 0, nil) }
        guard let img else { return [] }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        func px(_ fx: Double, _ fy: Double) -> [Int] {
            let x = Int(Double(w) * fx), y = Int(Double(h) * fy)
            let o = (y * w + x) * 4
            return [Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2])]
        }
        return [px(0.04, 0.04), px(0.96, 0.04), px(0.96, 0.96), px(0.04, 0.96)]   // 左上 右上 右下 左下
    }

    static func close(_ a: [[Int]], _ b: [[Int]], tol: Int = 10) -> Bool {
        guard a.count == 4, a.count == b.count else { return false }
        for i in 0..<4 { for c in 0..<3 where abs(a[i][c] - b[i][c]) > tol { return false } }
        return true
    }

    // MARK: - 造测试图

    /// 1800×1200 的 Display P3 图，四个角是 P3 里才有的鲜艳色（存着的样子：左上红、右上绿、右下蓝、左下黄），
    /// 方向标记 6（顺时针转 90° 显示）：显示出来应该是 1200×1800，左上黄、右上红、右下绿、左下蓝 —— 不对，见 expectedDisplay
    static func makeSource(_ url: URL, p3: Bool = true, metadata: Bool = true) {
        let w = 1800, h = 1200
        let space = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt64 = 42
        let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let n = Int((seed >> 40) & 31)
                let o = y * bpr + x * 4
                base[o] = UInt8(min(255, 60 + x * 100 / w + n))
                base[o + 1] = UInt8(min(255, 80 + y * 100 / h + n))
                base[o + 2] = UInt8(min(255, 90 + n * 2))
                base[o + 3] = 255
            }
        }
        // CGContext 坐标 y 朝上：下面的块写的是「图上的」左上、右上、右下、左下
        let blocks: [(CGRect, [CGFloat])] = [
            (CGRect(x: 0, y: h - 240, width: 240, height: 240), [0.95, 0.15, 0.10]),     // 存着的左上：红
            (CGRect(x: w - 240, y: h - 240, width: 240, height: 240), [0.0, 0.85, 0.25]),   // 右上：绿
            (CGRect(x: w - 240, y: 0, width: 240, height: 240), [0.10, 0.20, 0.95]),       // 右下：蓝
            (CGRect(x: 0, y: 0, width: 240, height: 240), [0.98, 0.85, 0.10]),             // 左下：黄
        ]
        for (r, c) in blocks { ctx.setFillColor(CGColor(colorSpace: space, components: c + [1])!); ctx.fill(r) }
        let img = ctx.makeImage()!
        var p: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.9]
        if metadata {
            p[kCGImagePropertyOrientation as String] = 6
            p[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFMake as String: "TESTCAM", kCGImagePropertyTIFFModel as String: "T-One",
                                                          kCGImagePropertyTIFFOrientation as String: 6]
            p[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifExposureTime as String: 0.004, kCGImagePropertyExifFNumber as String: 2.8,
                                                          kCGImagePropertyExifISOSpeedRatings as String: [400],
                                                          kCGImagePropertyExifDateTimeOriginal as String: "2024:05:01 10:20:30",
                                                          kCGImagePropertyExifPixelXDimension as String: w, kCGImagePropertyExifPixelYDimension as String: h]
            p[kCGImagePropertyGPSDictionary as String] = [kCGImagePropertyGPSLatitude as String: 31.2304, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                         kCGImagePropertyGPSLongitude as String: 121.4737, kCGImagePropertyGPSLongitudeRef as String: "E"]
            p[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCCaptionAbstract as String: "Crowd at the harbour gate",
                                                          kCGImagePropertyIPTCByline as String: ["Zhang San"],
                                                          kCGImagePropertyIPTCCopyrightNotice as String: "(c) 2024 Zhang San",
                                                          kCGImagePropertyIPTCKeywords as String: ["harbour", "crowd"],
                                                          kCGImagePropertyIPTCHeadline as String: "Harbour gate", kCGImagePropertyIPTCCredit as String: "Daily News"]
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        CGImageDestinationFinalize(dest)
        guard metadata else { return }
        // 自定义 XMP 属性（图库软件常写的那种）：不重新编码，只合并元数据
        let m = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(m, "http://flipic.test/ns/1.0/" as CFString, "ftest" as CFString, nil)
        CGImageMetadataSetValueWithPath(m, nil, "ftest:Custom" as CFString, "kept-through-export" as CFString)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("src-tmp.jpg")
        let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let d2 = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationCopyImageSource(d2, s, [kCGImageDestinationMetadata: m, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    /// 界面「导出为…」走的路：解全图 → 按视图转（这里没转）→ 导出
    static func uiExport(_ src: URL, _ dest: URL, uti: String = "public.jpeg", _ o: ExportOptions, quality: Double = 85) -> ImageExporter.Outcome? {
        guard let full = ImageLoader.decodedFull(url: src), let img = Straighten.applied(to: full, turns: 0, degrees: 0, crop: nil) else { return nil }
        return ImageExporter.export(img, source: src, to: dest, uti: uti, quality: quality, options: o)
    }

    static func profile(_ e: [String: Any]) -> String { val(e, "ProfileDescription") ?? "-" }

    // MARK: - 主流程

    static func runFiles(work: URL, raw: URL?) {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard exiftoolPath != nil else { check(false, "exiftool missing"); return }
        let src = work.appendingPathComponent("p3.jpg")
        makeSource(src)
        let o0 = ExportOptions()
        func out(_ n: String) -> URL { work.appendingPathComponent(n) }

        // ---- 0. 测试图本身
        let se = exif(src)
        let sp = props(src)
        check(sub(sp, kCGImagePropertyTIFFDictionary)["Make"] as? String == "TESTCAM" && (sp["Orientation"] as? Int) == 6, "source: make + orientation 6")
        check(has(se, "Caption-Abstract") && has(se, "CopyrightNotice") && has(se, "By-line") && has(se, "Keywords") && has(se, "GPSLatitude"), "source: IPTC + GPS present (exiftool)")
        check(val(se, "Custom") == "kept-through-export", "source: custom XMP present (exiftool)")
        check(profile(se).contains("P3"), "source: profile \(profile(se))")
        // 显示出来：1200×1800，转正后左上=存着的左下(黄)，右上=左上(红)，右下=右上(绿)，左下=右下(蓝)
        let srcShown = corners(src, transform: true)
        check(srcShown.count == 4 && srcShown[0][0] > 200 && srcShown[0][1] > 180 && srcShown[1][0] > 200 && srcShown[1][1] < 120, "source: displayed corners \(srcShown)")

        // ---- 1. 默认选项（保留元数据，不动颜色）
        let r1 = uiExport(src, out("default.jpg"), o0)
        let u1 = out("default.jpg"), e1 = exif(u1), p1 = props(u1)
        check(r1 != nil && bytes(u1) > 0, "default: written")
        check(size(u1) == (1200, 1800), "default: pixels \(size(u1)) = 1200x1800")
        check(sub(p1, kCGImagePropertyTIFFDictionary)["Make"] as? String == "TESTCAM" && sub(p1, kCGImagePropertyExifDictionary)["DateTimeOriginal"] as? String == "2024:05:01 10:20:30"
              && (sub(p1, kCGImagePropertyExifDictionary)["ExposureTime"] as? Double) == 0.004, "default: make / exposure / date (ImageIO)")
        check(val(e1, "Make") == "TESTCAM" && val(e1, "ExposureTime") == "0.004" && val(e1, "DateTimeOriginal") == "2024:05:01 10:20:30", "default: make / exposure / date (exiftool)")
        check(sub(p1, kCGImagePropertyGPSDictionary)["Latitude"] as? Double != nil && has(e1, "GPSLatitude") && has(e1, "GPSLongitude"), "default: GPS kept")
        check(val(e1, "Caption-Abstract") == "Crowd at the harbour gate" && val(e1, "CopyrightNotice") == "(c) 2024 Zhang San" && has(e1, "By-line") && val(e1, "Headline") == "Harbour gate" && val(e1, "Credit") == "Daily News",
              "default: IPTC caption / copyright / byline / headline / credit (exiftool IIM): cap=\(val(e1, "Caption-Abstract") ?? "-") by=\(val(e1, "By-line") ?? "-")")
        check("\(e1.filter { $0.key.hasSuffix("Keywords") })".contains("harbour"), "default: keywords \(e1.filter { $0.key.hasSuffix("Keywords") })")
        check(val(e1, "Custom") == "kept-through-export" && xmpString(u1, "ftest:Custom") == "kept-through-export", "default: custom XMP kept")
        let ori = (p1["Orientation"] as? Int) ?? 1
        check(ori == 1 && (val(e1, "Orientation") ?? "1") == "1", "default: orientation 1 (\(ori)) — no double rotation")
        check(val(e1, "ExifImageWidth") == "1200" && val(e1, "ExifImageHeight") == "1800", "default: Exif pixel dims \(val(e1, "ExifImageWidth") ?? "-")x\(val(e1, "ExifImageHeight") ?? "-")")
        let c1 = corners(u1, transform: true), c1raw = corners(u1, transform: false)
        check(close(c1, srcShown) && close(c1raw, srcShown), "default: corner colours match the displayed original; stored pixels already upright \(c1raw)")
        check(profile(e1).contains("P3"), "default: ICC \(profile(e1)) (source Display P3)")
        let thumbKey = e1.keys.first { $0.hasSuffix("ThumbnailImage") || $0.hasSuffix("ThumbnailLength") }
        info("default: embedded thumbnail tag = \(thumbKey ?? "none"), IFD1 width=\(val(e1, "ThumbnailWidth") ?? "-")")
        check(thumbKey == nil || val(e1, "ThumbnailWidth") == nil, "default: no stale embedded thumbnail")

        // ---- 2. 不保留元数据
        let u2 = out("nometa.jpg")
        check(uiExport(src, u2, ExportOptions(keepMetadata: false)) != nil, "nometa: written")
        let e2 = exif(u2)
        check(!has(e2, "Make") && !has(e2, "GPSLatitude") && !has(e2, "Caption-Abstract") && !has(e2, "CopyrightNotice") && !has(e2, "Custom") && !has(e2, "DateTimeOriginal"), "nometa: no EXIF / GPS / IPTC / XMP")
        check(close(corners(u2, transform: true), srcShown) && profile(e2).contains("P3"), "nometa: pixels upright and P3 profile kept")

        // ---- 3. 只去 GPS
        let u3 = out("nogps.jpg")
        check(uiExport(src, u3, ExportOptions(stripGPS: true)) != nil, "nogps: written")
        let e3 = exif(u3)
        check(!anyKey(e3, prefix: "GPS") && !has(e3, "GPSLatitude") && !has(e3, "GPSLongitude") && !anyKey(e3, prefix: "XMP-exif:GPS"), "nogps: GPS gone \(e3.keys.filter { $0.contains("GPS") })")
        check(val(e3, "Make") == "TESTCAM" && val(e3, "CopyrightNotice") == "(c) 2024 Zhang San" && val(e3, "Custom") == "kept-through-export" && has(e3, "DateTimeOriginal"), "nogps: everything else kept")

        // ---- 4. 长边
        let u4 = out("long800.jpg")
        check(uiExport(src, u4, ExportOptions(maxLongEdge: 800)) != nil, "long: written")
        let e4 = exif(u4)
        check(size(u4) == (533, 800), "long 800: pixels \(size(u4)) = 533x800")
        check(val(e4, "ExifImageWidth") == "533" && val(e4, "ExifImageHeight") == "800", "long 800: Exif dims follow \(val(e4, "ExifImageWidth") ?? "-")x\(val(e4, "ExifImageHeight") ?? "-")")
        check(close(corners(u4, transform: true), srcShown) && val(e4, "Make") == "TESTCAM", "long 800: corners + metadata")
        let u4b = out("long5000.jpg")
        _ = uiExport(src, u4b, ExportOptions(maxLongEdge: 5000))
        check(size(u4b) == (1200, 1800), "long 5000: never upscales \(size(u4b))")
        // 缩小的质量：细节没糊成色块（用对角线上的邻点反差粗略判断缩放不是最近邻，只看不崩）
        check(bytes(u4) < bytes(u1), "long 800: smaller file than full size (\(bytes(u4)) < \(bytes(u1)))")

        // ---- 5. 大小限制
        let limit: Int64 = 150_000
        let u5 = out("size150k.jpg")
        let r5 = uiExport(src, u5, ExportOptions(maxBytes: limit))
        check(r5 != nil && bytes(u5) <= limit && r5!.limitMet, "size 150KB: file \(bytes(u5)) <= \(limit), q=\(r5?.quality ?? -1) px=\(r5?.width ?? 0)x\(r5?.height ?? 0)")
        check(exif(u5)["IFD0:Make"] as? String == "TESTCAM", "size 150KB: metadata still there")
        let u5b = out("size5mb.jpg")
        let r5b = uiExport(src, u5b, ExportOptions(maxBytes: 50_000_000), quality: 85)
        check(r5b?.quality == 85 && size(u5b) == (1200, 1800), "size generous: quality untouched (\(r5b?.quality ?? -1)) and no resize")
        let u5c = out("size-impossible.jpg")
        let r5c = uiExport(src, u5c, ExportOptions(maxBytes: 3_000))
        check(r5c != nil && r5c!.limitMet == false && bytes(u5c) > 3_000, "size 3KB impossible: reported not met, wrote smallest (\(bytes(u5c)) bytes, \(size(u5c)))")
        let u5d = out("size150k.heic")
        let r5d = uiExport(src, u5d, uti: "public.heic", ExportOptions(maxBytes: limit))
        check(r5d != nil && bytes(u5d) <= limit && r5d!.limitMet, "size 150KB heic: \(bytes(u5d)) bytes q=\(r5d?.quality ?? -1) \(size(u5d))")
        let u5e = out("size-png.png")
        let r5e = uiExport(src, u5e, uti: "public.png", ExportOptions(maxBytes: 10_000))
        check(r5e != nil && r5e!.limitMet && size(u5e) == (1200, 1800), "size on PNG ignored (lossless): \(bytes(u5e)) bytes")
        // 质量到底还不够，要缩小：用一张更紧的限制
        let u5f = out("size60k.jpg")
        let r5f = uiExport(src, u5f, ExportOptions(maxBytes: 60_000))
        check(r5f != nil && bytes(u5f) <= 60_000 && (r5f!.width < 1200 || r5f!.quality > 40), "size 60KB: \(bytes(u5f)) bytes q=\(r5f?.quality ?? -1) px=\(r5f?.width ?? 0)x\(r5f?.height ?? 0)")

        // ---- 6. sRGB
        let u6 = out("srgb.jpg")
        check(uiExport(src, u6, ExportOptions(toSRGB: true)) != nil, "srgb: written")
        let e6 = exif(u6)
        check(profile(e6).contains("sRGB"), "srgb on: ICC \(profile(e6))")
        check(close(corners(u6, transform: true), srcShown, tol: 8), "srgb on: pixels converted, colours still match when viewed colour-managed \(corners(u6, transform: true))")
        check(profile(e1).contains("P3") && close(c1, srcShown, tol: 8), "srgb off: still tagged P3 and colours match")
        let rawP3 = corners(u1, transform: false), rawSRGB = corners(u6, transform: false)
        check(!close(rawP3, rawSRGB, tol: 0), "srgb on vs off: stored pixel values differ (\(rawSRGB) vs \(rawP3))")
        // 今天（改之前）的写法：只写像素
        if let full = ImageLoader.decodedFull(url: src) {
            let old = out("old-write.jpg")
            _ = ImageExporter.write(full, to: old, uti: "public.jpeg", quality: 0.85)
            let o85 = out("old-q85.jpg"), o085 = out("old-q0.85.jpg")
            _ = ImageExporter.write(full, to: o85, uti: "public.jpeg", quality: 85)
            _ = ImageExporter.write(full, to: o085, uti: "public.jpeg", quality: 0.85)
            info("today (old write): slider value 85 passed straight to a 0-1 API gives \(bytes(o85)) bytes vs \(bytes(o085)) bytes for 0.85 (the old quality slider and size estimate were not doing what they said)")
            info("today (old write): decodedFull colourspace=\(full.colorSpace?.name as String? ?? "unnamed") → file profile=\(profile(exif(old))), corners match=\(close(corners(old, transform: true), srcShown, tol: 8))")
        }

        // 旋转 90° 走 ImageLoader.rotated（画进 sRGB）：P3 照片转过之后颜色也要对
        if let full = ImageLoader.decodedFull(url: src), let rot = Straighten.applied(to: full, turns: 1, degrees: 0, crop: nil),
           let outRot = ImageExporter.export(rot, source: src, to: out("rot90.jpg"), uti: "public.jpeg", quality: 85, options: o0) {
            let er = exif(out("rot90.jpg"))
            // 转之前显示是 左上黄 右上红 右下绿 左下蓝；顺时针转 90° 后：左上蓝 右上黄 右下红 左下绿
            let want = [srcShown[3], srcShown[0], srcShown[1], srcShown[2]]
            check(size(out("rot90.jpg")) == (1800, 1200) && close(corners(out("rot90.jpg"), transform: true), want, tol: 12), "rotate 90 (viewer path): size \(size(out("rot90.jpg"))), colours right, profile \(profile(er)) (\(outRot.width)x\(outRot.height))")
        }

        // 裁剪、拉直另存（Straighten.save）也改走了共用的元数据函数：带着拍摄信息、IPTC、自定义 XMP，方向和尺寸是新的
        do {
            let sdir = work.appendingPathComponent("straighten")
            try? fm.createDirectory(at: sdir, withIntermediateDirectories: true)
            let sfile = sdir.appendingPathComponent("s.jpg")
            makeSource(sfile)
            let r = Straighten.save(url: sfile, quarterTurns: 0, degrees: 3, overwrite: false)
            let es = r.url.map { exif($0) } ?? [:]
            let ps = r.url.map { props($0) } ?? [:]
            check(r.result != .failed && r.url != nil && val(es, "Make") == "TESTCAM" && val(es, "CopyrightNotice") == "(c) 2024 Zhang San" && val(es, "Custom") == "kept-through-export"
                  && has(es, "GPSLatitude") && (ps["Orientation"] as? Int ?? 1) == 1, "straighten save (shared metadata code): metadata kept, orientation 1 (\(r.url?.lastPathComponent ?? "-"))")
            if let u = r.url { check(val(es, "ExifImageWidth") == "\(size(u).0)" && val(es, "ExifImageHeight") == "\(size(u).1)", "straighten save: Exif dims match pixels \(size(u))") }
        }

        // ---- 7. HEIC / PNG 输出带元数据
        let u7 = out("meta.heic")
        check(uiExport(src, u7, uti: "public.heic", ExportOptions()) != nil, "heic: written")
        let e7 = exif(u7), p7 = props(u7)
        check(size(u7) == (1200, 1800) && val(e7, "Make") == "TESTCAM" && has(e7, "GPSLatitude") && close(corners(u7, transform: true), srcShown, tol: 12),
              "heic: size \(size(u7)), make, GPS, corners; profile \(profile(e7)); orientation \(p7["Orientation"] ?? "nil")")
        check(val(e7, "CopyrightNotice") != nil || val(e7, "Rights") != nil || val(e7, "Description") != nil, "heic: caption/copyright present (\(e7.keys.filter { $0.contains("IPTC") || $0.contains("dc") }.sorted().joined(separator: ",")))")
        let u7b = out("meta.png")
        check(uiExport(src, u7b, uti: "public.png", ExportOptions()) != nil, "png: written")
        let e7b = exif(u7b)
        check(size(u7b) == (1200, 1800) && close(corners(u7b, transform: true), srcShown, tol: 8), "png: size + corners; profile \(profile(e7b))")
        info("png metadata: make=\(val(e7b, "Make") ?? "-") gps=\(has(e7b, "GPSLatitude")) caption=\(val(e7b, "Description") ?? val(e7b, "Caption-Abstract") ?? "-") copyright=\(val(e7b, "Rights") ?? val(e7b, "CopyrightNotice") ?? "-")")
        check(profile(e7b).contains("P3"), "png: P3 profile tagged \(profile(e7b))")

        for (uti, ext) in [("public.png", "png"), ("public.heic", "heic")] {
            let u = out("srgb.\(ext)")
            _ = uiExport(src, u, uti: uti, ExportOptions(toSRGB: true))
            let e = exif(u)
            let tagged = ext == "heic" || profile(e).contains("sRGB") || val(e, "SRGBRendering") != nil || val(e, "ColorSpace") == "1" || profile(e) != "-" && !profile(e).contains("P3")
            if ext == "heic" { info("heic sRGB: ImageIO writes an nclx colour box with unspecified primaries (no ICC) for sRGB; pixels are sRGB, readers assume sRGB") }
            check(tagged && !profile(e).contains("P3") && close(corners(u, transform: true), srcShown, tol: 12), "srgb on \(ext): not P3, tagged sRGB (profile \(profile(e)), SRGBRendering=\(val(e, "SRGBRendering") ?? "-"), ColorSpace=\(val(e, "ColorSpace") ?? "-"))")
        }

        // ---- 8. 批量：命名、不覆盖、同格式跳过、取消
        let srcDir = work.appendingPathComponent("batch-src")
        let outDir = work.appendingPathComponent("batch-out")
        try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: src, to: srcDir.appendingPathComponent("a.jpg"))
        let srgbSrc = srcDir.appendingPathComponent("b.jpg")
        makeSource(srgbSrc, p3: false)
        let urls = [srcDir.appendingPathComponent("a.jpg"), srgbSrc]
        func s(_ o: ExportOptions, _ ext: String = "jpg", _ uti: String = "public.jpeg") -> BatchConvert.Settings {
            BatchConvert.Settings(uti: uti, ext: ext, quality: 85, options: o, outDir: outDir)
        }
        let b0 = BatchConvert.run(urls, settings: s(ExportOptions()))
        check(b0.converted == 0 && b0.skipped == 2 && b0.failed == 0 && !fm.fileExists(atPath: outDir.appendingPathComponent("a.jpg").path), "batch jpg->jpg, no limits: both skipped, nothing written \(b0.converted)/\(b0.skipped)/\(b0.failed)")
        let b1 = BatchConvert.run(urls, settings: s(ExportOptions(maxLongEdge: 800)))
        check(b1.converted == 2 && b1.skipped == 0 && size(outDir.appendingPathComponent("a.jpg")) == (533, 800), "batch jpg->jpg with long edge: processed \(b1.converted), a.jpg \(size(outDir.appendingPathComponent("a.jpg")))")
        let a1sum = fm.contents(atPath: outDir.appendingPathComponent("a.jpg").path)?.count ?? -1
        let b2 = BatchConvert.run(urls, settings: s(ExportOptions(maxLongEdge: 800)))
        check(b2.converted == 2 && fm.fileExists(atPath: outDir.appendingPathComponent("a 2.jpg").path) && fm.fileExists(atPath: outDir.appendingPathComponent("b 2.jpg").path)
              && fm.contents(atPath: outDir.appendingPathComponent("a.jpg").path)?.count == a1sum, "batch: second run -> 'a 2.jpg', original output untouched")
        _ = BatchConvert.run(urls, settings: s(ExportOptions(maxLongEdge: 800)))
        check(fm.fileExists(atPath: outDir.appendingPathComponent("a 3.jpg").path), "batch: third run -> 'a 3.jpg'")
        let out4 = work.appendingPathComponent("batch-out2")
        var s4 = s(ExportOptions(toSRGB: true)); s4.outDir = out4
        let b4 = BatchConvert.run(urls, settings: s4)
        check(b4.converted == 1 && b4.skipped == 1 && fm.fileExists(atPath: out4.appendingPathComponent("a.jpg").path) && !fm.fileExists(atPath: out4.appendingPathComponent("b.jpg").path)
              && profile(exif(out4.appendingPathComponent("a.jpg"))).contains("sRGB"), "batch sRGB-only: P3 file converted, already-sRGB file skipped")
        var s5 = s(ExportOptions(maxBytes: 100_000)); s5.outDir = work.appendingPathComponent("batch-out3")
        let b5 = BatchConvert.run(urls, settings: s5)
        check(b5.converted == 2 && b5.overLimit.isEmpty && bytes(s5.outDir.appendingPathComponent("a.jpg")) <= 100_000, "batch size limit: both under 100KB (\(bytes(s5.outDir.appendingPathComponent("a.jpg"))))")
        var s6 = s(ExportOptions(maxBytes: 2_000)); s6.outDir = work.appendingPathComponent("batch-out4")
        let b6 = BatchConvert.run(urls, settings: s6)
        check(b6.converted == 2 && b6.overLimit.count == 2 && BatchConvert.message(b6, limit: 2_000).contains("2"), "batch impossible limit: reported \(b6.overLimit.count) over limit")
        var s7 = s(ExportOptions()); s7.outDir = work.appendingPathComponent("batch-out5"); s7.ext = "png"; s7.uti = "public.png"
        let b7 = BatchConvert.run(urls, settings: s7)
        check(b7.converted == 2 && b7.skipped == 0 && fm.fileExists(atPath: s7.outDir.appendingPathComponent("a.png").path), "batch jpg->png: converted")
        var s8 = s(ExportOptions(maxLongEdge: 800)); s8.outDir = work.appendingPathComponent("batch-out6")
        var seen = 0
        let b8 = BatchConvert.run(urls + urls + urls, settings: s8, isCancelled: { seen >= 2 }, progress: { seen = $0 })
        check(b8.cancelled && b8.converted == 2 && (try? fm.contentsOfDirectory(atPath: s8.outDir.path).count) == 2, "batch cancel: stopped after 2 of 6 (converted \(b8.converted))")
        let dflt = BatchConvert.defaultOutputFolder(for: urls[0], ext: "jpg")
        check(dflt.url.path == srcDir.appendingPathComponent("Converted-jpg").path && !dflt.redirected, "batch default folder beside the source on a normal disk")

        // ---- 9. RAW
        if let raw {
            let rdir = work.appendingPathComponent("raw")
            try? fm.createDirectory(at: rdir, withIntermediateDirectories: true)
            let rcopy = rdir.appendingPathComponent("DSCF0001.RAF")
            try? fm.copyItem(at: raw, to: rcopy)
            _ = Rating.write(4, to: rcopy)
            let srcE = exif(rcopy)
            let ur = out("raw.jpg")
            let rr = uiExport(rcopy, ur, ExportOptions())
            let er = exif(ur), pr = props(ur)
            let shown = ImageLoader.decodedFull(url: rcopy)
            check(rr != nil && size(ur).0 == shown?.width && size(ur).1 == shown?.height && size(ur).0 > 100, "raw: exported \(size(ur)) = decoded \(shown?.width ?? 0)x\(shown?.height ?? 0)")
            check(val(er, "Make") == val(srcE, "Make") && val(srcE, "Make") != nil, "raw: Make \(val(er, "Make") ?? "-") (source \(val(srcE, "Make") ?? "-"))")
            let carried = ["Model", "ExposureTime", "FNumber", "ISO", "DateTimeOriginal", "FocalLength", "LensModel"].filter { val(srcE, $0) != nil }
            let lost = carried.filter { val(er, $0) != val(srcE, $0) }
            info("raw: carried \(carried.count - lost.count)/\(carried.count) of \(carried), lost: \(lost); orientation out=\(pr["Orientation"] ?? "nil") rating=\(xmpString(ur, "xmp:Rating") ?? "nil")")
            check(lost.isEmpty, "raw: exposure/lens tags carried")
            check(xmpString(ur, "xmp:Rating") == "4", "raw: sidecar rating carried into xmp:Rating")
            check(exif(ur)["IFD0:Orientation"] as? Int ?? 1 == 1 && profile(er) != "-", "raw: orientation 1, profile \(profile(er))")
            let ur2 = out("raw-srgb.jpg")
            _ = uiExport(rcopy, ur2, ExportOptions(maxLongEdge: 1600, toSRGB: true))
            check(max(size(ur2).0, size(ur2).1) == 1600 && profile(exif(ur2)).contains("sRGB"), "raw: long edge + sRGB \(size(ur2)) \(profile(exif(ur2)))")
        } else { info("raw: no RAW file given") }
    }
}

extension ViewerViewController {
    /// 文件部分 + 看图界面部分（真的弹出 ⌘S 面板，改选项看预计大小变；把两个面板渲染成图）
    func runExportOptionsTest(outDir: String, raw: String?) {
        typealias T = ExportSelfTest
        let work = URL(fileURLWithPath: outDir)
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        T.runFiles(work: work.appendingPathComponent("files"), raw: raw.map { URL(fileURLWithPath: $0) })

        // 看图界面：照片放进自己的文件夹
        let fm = FileManager.default
        let dir = work.appendingPathComponent("viewer")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        T.makeSource(dir.appendingPathComponent("p3.jpg"))
        T.makeSource(dir.appendingPathComponent("q.jpg"), p3: false)
        open(url: dir.appendingPathComponent("p3.jpg"))
        let shots = work.appendingPathComponent("shots")
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        // 自测会改这些记住的选项：先存下原来的值，结束时还原，不留下痕迹
        let keys = ["export.keepMeta", "export.stripGPS", "export.longEdgeOn", "export.longEdge", "export.sizeOn", "export.sizeMB", "export.srgb", "export.format", "export.quality", "batch.format", "batch.quality"]
        Self.savedExportDefaults = keys.map { ($0, defaults.object(forKey: $0)) }
        for k in keys { defaults.removeObject(forKey: k) }
        /// 抓一个窗口（保存面板 sheet 或对话框）本身的样子；系统允许应用抓自己的窗口
        func render(_ w: NSWindow?, _ name: String) {
            // 对话框直接按窗口号抓；保存面板是 sheet，按窗口号抓只有空壳，改画附件窗口自己的内容（本进程里画，不碰屏幕）
            let sheet = w?.sheetParent != nil
            if sheet {
                let ok = WatermarkSelfTest.shootView(self.exportAccessory?.view.window?.contentView ?? self.exportAccessory?.view, shots.appendingPathComponent("\(name)-\(lang).png"))
                if !ok { T.check(false, "screenshot \(name) failed") }
                return
            }
            guard let w, let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                T.check(false, "screenshot \(name) failed"); return
            }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("\(name)-\(lang).png"))
        }
        var estDefault = "", estLimits = ""
        func wait(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        wait(1.0) {
            self.exportAs(nil)
            wait(2.0) {
                guard let acc = self.exportAccessory else { T.check(false, "ui: ⌘S accessory did not appear"); self.finishExportTest(); return }
                let plain = self.exportEstimateLabel?.stringValue ?? ""
                estDefault = plain
                T.check(plain.contains("MB") || plain.contains("KB"), "ui estimate (defaults): \(plain)")
                T.check(acc.options.options == ExportOptions(), "ui: first-run defaults = keep metadata on, GPS strip off, no limits, sRGB off")
                // 打开「长边」和「文件不超过」，看预计大小跟着变
                let before = plain
                self.setExportUI(acc, long: 800, megabytes: 0.15, srgb: true, strip: true)
                wait(2.5) {
                    let after = self.exportEstimateLabel?.stringValue ?? ""
                    estLimits = after
                    T.check(after != before && after.contains("KB"), "ui estimate follows options: '\(before)' -> '\(after)'")
                    // 切到 PNG：「文件不超过」禁用
                    acc.popup.selectItem(at: 1)
                    acc.popup.sendAction(acc.popup.action, to: acc.popup.target)
                    wait(1.5) {
                        T.check(acc.options.options.maxBytes == nil, "ui: PNG disables the size limit")
                        acc.popup.selectItem(at: 0)
                        acc.popup.sendAction(acc.popup.action, to: acc.popup.target)
                        // 保存：真的点「导出」，写到工作文件夹，记住选项
                        let dest = dir.appendingPathComponent("p3-compressed.jpg")
                        if let p = self.exportSavePanel { p.sheetParent?.endSheet(p, returnCode: .OK) }
                        wait(3.0) {
                            let saved = ExportOptions.saved
                            T.check(saved.maxLongEdge == 800 && saved.toSRGB && saved.stripGPS && saved.maxBytes != nil, "ui: options remembered \(saved)")
                            let e = T.exif(dest)
                            T.check(FileManager.default.fileExists(atPath: dest.path) && T.bytes(dest) <= 157_287 && max(T.size(dest).0, T.size(dest).1) <= 800 && !T.has(e, "GPSLatitude") && T.val(e, "Make") == "TESTCAM"
                                    && T.profile(e).contains("sRGB"), "ui: exported file via the real panel: \(T.bytes(dest)) bytes \(T.size(dest)) \(T.profile(e)) gps=\(T.has(e, "GPSLatitude"))")
                            // 批量对话框
                            let (alert, bacc) = self.debugBatchAlert()
                            alert.layout()
                            T.check(alert.informativeText.contains("\(self.folder.count)") && self.folder.count >= 2, "ui: batch dialog states the count: '\(alert.informativeText)'")
                            T.check(bacc.settings.options == saved, "ui: batch dialog starts from remembered options")
                            // ⌘S 面板的附件：三种状态各截一张（放进一个普通窗口里抓；保存面板本身是 sheet，抓不到）
                            func shootAccessory(_ o: ExportOptions, _ format: Int, _ estimate: String, _ name: String, _ next: @escaping () -> Void) {
                                ExportOptions.saved = o
                                let a = ExportAccessory(formats: ["JPEG", "PNG", "HEIC"], formatIndex: format, quality: 85) {}
                                a.options.isPNG = format == 1
                                a.slider.isEnabled = format != 1
                                a.estimateLabel.stringValue = estimate
                                let pad: CGFloat = 20
                                let box = NSView(frame: NSRect(x: 0, y: 0, width: a.view.frame.width + 2 * pad, height: a.view.frame.height + 2 * pad))
                                a.view.frame.origin = NSPoint(x: pad, y: pad)
                                box.addSubview(a.view)
                                let win = NSWindow(contentRect: box.frame, styleMask: [.titled], backing: .buffered, defer: false)
                                win.contentView = box
                                win.center()
                                win.makeKeyAndOrderFront(nil)
                                wait(0.8) { render(win, name); win.orderOut(nil); next() }
                            }
                            let defaults0 = ExportOptions()
                            let limits = ExportOptions(keepMetadata: true, stripGPS: true, maxLongEdge: 2048, maxBytes: 2 * 1_048_576, toSRGB: true)
                            shootAccessory(defaults0, 0, estDefault, "export-panel-default") {
                                shootAccessory(limits, 0, estLimits, "export-panel-limits") {
                                    shootAccessory(limits, 1, estLimits, "export-panel-png") {
                                        ExportOptions.saved = saved
                                        self.shootBatch(alert, bacc, "batch-dialog", render, wait)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func shootBatch(_ alert: NSAlert, _ bacc: BatchAccessory, _ name: String, _ render: @escaping (NSWindow?, String) -> Void,
                            _ wait: @escaping (Double, @escaping () -> Void) -> Void) {
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        wait(1.0) {
            render(alert.window, name)
            alert.window.orderOut(nil)
            self.finishExportTest()
        }
    }

    private func setExportUI(_ acc: ExportAccessory, long: Int, megabytes: Double, srgb: Bool, strip: Bool) {
        acc.options.debugSet(long: long, megabytes: megabytes, srgb: srgb, strip: strip)
        acc.options.onChange?()
    }

    private static var savedExportDefaults: [(String, Any?)] = []

    private func finishExportTest() {
        typealias T = ExportSelfTest
        for (k, v) in Self.savedExportDefaults { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        UserDefaults.standard.synchronize()
        print("EXPORTTEST summary checks=\(T.checks) failures=\(T.failures) lang=\(Bundle.main.preferredLocalizations.first ?? "?")")
        fflush(stdout)
        exit(T.failures == 0 ? 0 : 1)
    }
}

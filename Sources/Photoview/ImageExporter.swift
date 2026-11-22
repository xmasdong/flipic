import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// 导出选项：「导出为…」（⌘S）和「批量转换格式…」共用，上次的选择记在 UserDefaults 里
struct ExportOptions: Equatable {
    /// 带上拍摄信息（EXIF、GPS）、说明和版权（IPTC）、XMP
    var keepMetadata = true
    /// 只去掉 GPS 位置，其余照留
    var stripGPS = false
    /// 长边不超过多少像素（不放大）；nil = 不限
    var maxLongEdge: Int?
    /// 文件不超过多少字节（只对 JPEG、HEIC）；nil = 不限
    var maxBytes: Int64?
    /// 像素转成 sRGB 并标上 sRGB 描述文件；关着时保持原来的色彩空间并如实标出
    var toSRGB = false
    /// 出图前对像素再处理一遍（由 Pro 装上的 ExportEffect 认得）：不透明的一段文字，nil = 不处理。不记在偏好设置里
    var effect: String?
    /// 导出的副本上加水印：整份样式 + 这一次的文字（共用代码，免费功能）。nil = 不加。不记在偏好设置里；
    /// 原文件不会被改，水印只在导出、转换出来的副本里
    var watermark: WatermarkJob?
    /// 导出的副本加边框（照片 › 加边框… 的设置）。nil = 不加；不记在偏好设置里
    var border: BorderSpec?
    /// 去掉相机机身和镜头序列号及机主名（保留其余拍摄参数）
    var stripSerial = false

    private static let d = UserDefaults.standard

    static var saved: ExportOptions {
        get {
            var o = ExportOptions()
            o.keepMetadata = d.object(forKey: "export.keepMeta") as? Bool ?? true
            o.stripGPS = d.bool(forKey: "export.stripGPS")
            o.stripSerial = d.bool(forKey: "export.stripSerial")
            if d.bool(forKey: "export.longEdgeOn") { o.maxLongEdge = max(64, d.integer(forKey: "export.longEdge")) }
            if d.bool(forKey: "export.sizeOn") { o.maxBytes = Int64(max(0.05, d.double(forKey: "export.sizeMB")) * 1_048_576) }
            o.toSRGB = d.bool(forKey: "export.srgb")
            return o
        }
        set {
            d.set(newValue.keepMetadata, forKey: "export.keepMeta")
            // 证件水印会自动勾上「去掉位置信息」，这一次的勾选不记到以后的普通导出里
            if newValue.watermark?.style.id != WatermarkBuiltIn.id.fixedID { d.set(newValue.stripGPS, forKey: "export.stripGPS") }
            d.set(newValue.stripSerial, forKey: "export.stripSerial")
            d.set(newValue.maxLongEdge != nil, forKey: "export.longEdgeOn")
            if let e = newValue.maxLongEdge { d.set(e, forKey: "export.longEdge") }
            d.set(newValue.maxBytes != nil, forKey: "export.sizeOn")
            if let b = newValue.maxBytes { d.set(Double(b) / 1_048_576, forKey: "export.sizeMB") }
            d.set(newValue.toSRGB, forKey: "export.srgb")
        }
    }

    /// 勾着但填的数字没记下来时，输入框里显示的初始值
    static var savedLongEdge: Int { d.integer(forKey: "export.longEdge") > 0 ? d.integer(forKey: "export.longEdge") : 2048 }
    static var savedSizeMB: Double { d.double(forKey: "export.sizeMB") > 0 ? d.double(forKey: "export.sizeMB") : 2 }
}

/// 导出前对像素的额外处理：Pro 在启动时装上一个函数，参数是图、导出选项里的 effect 文字、原文件；返回处理后的图（尺寸不变），
/// 失败返回 nil（按没处理）。没装（开源版）就什么都不做
enum ExportEffect {
    static var apply: ((CGImage, String, URL?) -> CGImage?)?
}

enum ImageExporter {
    /// 只带像素的老写法（没有元数据、不限制）；保留给不需要选项的调用
    static func write(_ image: CGImage, to url: URL, uti: String, quality: Double) -> Int64? {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64)
    }

    // MARK: - 结果

    struct Outcome {
        var data: Data
        /// 最后用的质量（PNG 无意义）
        var quality: Int
        var width: Int
        var height: Int
        /// 设了大小限制时，是不是压到了限制以内；没设限制恒为 true
        var limitMet: Bool
    }

    static func isLossy(_ uti: String) -> Bool { uti == "public.jpeg" || uti == "public.heic" }

    /// 导出一张已经按视图渲染好（转过、裁过）的图：先转 sRGB / 缩小，再按选项编码；设了大小限制就自动降质量、必要时缩小。
    /// source 是原文件，用来带元数据；batchIndex 给批量导出的 {index} 水印占位符；cancelled 在耗时的编码之间检查
    static func encode(_ image: CGImage, source: URL?, uti: String, quality: Double, options: ExportOptions,
                       batchIndex: Int? = nil, cancelled: () -> Bool = { false }) -> Outcome? {
        // 有 effect 或水印时先缩小、再处理、最后才转 sRGB：处理在原来的色域里做，颗粒的粗细、水印的大小也跟着最终的像素尺寸走。
        // 顺序：缩小/加边框 → 胶片 → 水印 → 转 sRGB → 编码
        let hasStage = options.effect != nil || options.watermark != nil
        var base = image
        if !hasStage, options.toSRGB, let s = converted(base) { base = s }
        // 加边框：长边限制管的是整张画布
        if let b = options.border {
            let exif = b.showExif ? source.map(BorderExif.read) : nil
            if let r = b.render(base, choice: options.maxLongEdge.map { .preset($0) } ?? .original, exif: exif) { base = r }
        } else if let edge = options.maxLongEdge, edge < max(base.width, base.height), let s = scaled(base, longEdge: edge) { base = s }
        let plain = base
        let fileName = source?.deletingPathExtension().lastPathComponent
        var watermarkFailed = false
        func styled(_ img: CGImage) -> CGImage {
            guard hasStage else { return img }
            let r = applyStages(img, options: options, source: source, fileName: fileName, batchIndex: batchIndex)
            if r.watermarkFailed { watermarkFailed = true }
            return r.image
        }
        base = styled(plain)
        if watermarkFailed { return nil }
        let meta = options.keepMetadata ? source.flatMap { carriedMetadata(for: $0, width: base.width, height: base.height, options: options) } : nil
        // 元数据在缩小后要重写像素尺寸，所以每个尺寸各取一次
        func data(_ img: CGImage, _ q: Int) -> Data? {
            let m = (img.width == base.width && img.height == base.height) ? meta
                : options.keepMetadata ? source.flatMap { carriedMetadata(for: $0, width: img.width, height: img.height, options: options) } : nil
            return encodeData(img, metadata: m, source: options.keepMetadata ? source : nil, uti: uti, quality: q, options: options)
        }
        let q0 = Int(quality.rounded())
        guard let limit = options.maxBytes, isLossy(uti) else {
            guard let d = data(base, q0) else { return nil }
            return Outcome(data: d, quality: q0, width: base.width, height: base.height, limitMet: options.maxBytes == nil || !isLossy(uti) || Int64(d.count) <= options.maxBytes!)
        }
        let floorQ = 40
        var current = base
        var smallest: Outcome?
        var factor = 1.0
        let baseLong = Double(max(base.width, base.height))
        while true {
            if cancelled() { return nil }
            if let d = data(current, q0), Int64(d.count) <= limit {
                return Outcome(data: d, quality: q0, width: current.width, height: current.height, limitMet: true)
            }
            if q0 > floorQ {
                guard let dFloor = data(current, floorQ) else { return nil }
                if Int64(dFloor.count) <= limit {
                    // 质量二分：lo 一定装得下，hi 一定装不下
                    var lo = floorQ, hi = q0, best = dFloor
                    while hi - lo > 1 {
                        if cancelled() { return nil }
                        let mid = (lo + hi) / 2
                        if let d = data(current, mid), Int64(d.count) <= limit { lo = mid; best = d } else { hi = mid }
                    }
                    return Outcome(data: best, quality: lo, width: current.width, height: current.height, limitMet: true)
                }
                if smallest == nil || dFloor.count < smallest!.data.count {
                    smallest = Outcome(data: dFloor, quality: floorQ, width: current.width, height: current.height, limitMet: false)
                }
                // 质量到底了还是大：按大小和像素数大致成正比估一个缩小比例，再留 5% 余量
                let ratio = min(0.92, max(0.5, (Double(limit) / Double(dFloor.count)).squareRoot() * 0.95))
                factor *= ratio
            } else {
                guard let d = data(current, q0) else { return nil }
                if smallest == nil || d.count < smallest!.data.count {
                    smallest = Outcome(data: d, quality: q0, width: current.width, height: current.height, limitMet: false)
                }
                factor *= min(0.92, max(0.5, (Double(limit) / Double(d.count)).squareRoot() * 0.95))
            }
            let edge = Int((baseLong * factor).rounded())
            if edge < 200 { break }
            guard let s = scaled(plain, longEdge: edge) else { break }
            current = styled(s)
            if watermarkFailed { return nil }
        }
        return smallest
    }

    /// 缩小之后、编码之前的那几步：胶片 → 水印 → 转 sRGB。导出和导出面板里的预览共用这一份，预览才和真正导出的一致。
    /// 水印画不出来时 watermarkFailed 为 true（导出要整张失败；预览只是显示没有水印的图）
    static func applyStages(_ img: CGImage, options: ExportOptions, source: URL?, fileName: String?, batchIndex: Int? = nil) -> (image: CGImage, watermarkFailed: Bool) {
        var out = img
        var failed = false
        if let token = options.effect { out = ExportEffect.apply?(out, token, source) ?? out }
        if let wm = options.watermark {
            // 水印画不出来（文字是空的、logo 找不到）就整张导出失败，不能悄悄出一份没水印的副本
            if let marked = WatermarkRenderer.render(out, job: wm, fileName: fileName, index: batchIndex) { out = marked } else { failed = true }
        }
        if options.toSRGB, let s = converted(out) { out = s }
        return (out, failed)
    }

    /// 编码并写到 url（先写临时文件再换过去，不会留下写了一半的文件）。成功返回结果
    static func export(_ image: CGImage, source: URL?, to url: URL, uti: String, quality: Double, options: ExportOptions,
                       cancelled: () -> Bool = { false }) -> Outcome? {
        guard let out = encode(image, source: source, uti: uti, quality: quality, options: options, cancelled: cancelled) else { return nil }
        do { try out.data.write(to: url, options: .atomic) } catch { return nil }
        return out
    }

    private static func encodeData(_ image: CGImage, metadata: CGImageMetadata?, source: URL?, uti: String, quality: Int,
                                   options: ExportOptions) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        var opts: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: Double(quality) / 100]
        if let metadata {
            opts[kCGImagePropertyOrientation as String] = 1
            if options.stripGPS { opts[kCGImageMetadataShouldExcludeGPS as String] = true }
            CGImageDestinationAddImageAndMetadata(dest, image, metadata, opts as CFDictionary)
        } else {
            // 读不出完整元数据的格式：退回只带属性字典（EXIF、TIFF、GPS、IPTC 各一份）
            if let source, let props = carriedProperties(for: source, width: image.width, height: image.height, options: options) {
                opts.merge(props) { $1 }
            }
            CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        // 转 sRGB 的 JPEG：ImageIO 对 sRGB 只在 EXIF 里标色彩空间、不嵌描述文件；图片编辑部的软件要的是真有一份，这里补进去
        if options.toSRGB, uti == "public.jpeg", let icc = srgbProfileData { return withICCProfile(data as Data, icc) }
        return data as Data
    }

    private static let srgbProfileData = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"))

    /// 在 JPEG 的开头那串 APPn 段后面插入一段 ICC_PROFILE（APP2）；已经有就不动
    static func withICCProfile(_ jpeg: Data, _ icc: Data) -> Data {
        let tag = Array("ICC_PROFILE".utf8) + [0]
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8, icc.count < 65_000 else { return jpeg }
        var pos = 2
        while pos + 4 < jpeg.count, jpeg[pos] == 0xFF, (0xE0...0xEF).contains(jpeg[pos + 1]) {
            let len = Int(jpeg[pos + 2]) << 8 | Int(jpeg[pos + 3])
            if jpeg[pos + 1] == 0xE2, jpeg.count > pos + 4 + tag.count, Array(jpeg[(pos + 4)..<(pos + 4 + tag.count)]) == tag { return jpeg }
            pos += 2 + len
        }
        let segLen = 2 + tag.count + 2 + icc.count
        var seg = Data([0xFF, 0xE2, UInt8(segLen >> 8), UInt8(segLen & 0xFF)])
        seg.append(contentsOf: tag)
        seg.append(contentsOf: [1, 1])
        seg.append(icc)
        var out = jpeg
        out.insert(contentsOf: seg, at: pos)
        return out
    }

    // MARK: - 元数据

    /// 原文件的元数据（EXIF、TIFF、GPS、IPTC、XMP 都在里面），改成适合 width × height 这张已经转正的图：
    /// 方向恢复正常（像素已经转过了，不能再转一次）、像素尺寸写新的、原来的 XMP 日期写法规整。
    /// RAW 的星级在旁车 .xmp 里，顺手写进去。读不出元数据返回 nil
    static func carriedMetadata(for url: URL, width: Int, height: Int, options: ExportOptions) -> CGImageMetadata? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let fixed = fixedMetadata(from: src, width: width, height: height) else { return nil }
        if CleanupUnit.isRaw(url) {
            let (stars, label) = Rating.readBoth(url)
            if stars > 0, CGImageMetadataCopyTagWithPath(fixed, nil, "xmp:Rating" as CFString) == nil,
               CGImageMetadataRegisterNamespaceForPrefix(fixed, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil) {
                CGImageMetadataSetValueWithPath(fixed, nil, "xmp:Rating" as CFString, "\(stars)" as CFString)
            }
            if let label, CGImageMetadataCopyTagWithPath(fixed, nil, "xmp:Label" as CFString) == nil,
               CGImageMetadataRegisterNamespaceForPrefix(fixed, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil) {
                CGImageMetadataSetValueWithPath(fixed, nil, "xmp:Label" as CFString, label.xmpLabel as CFString)
            }
        }
        if options.stripGPS { removeGPS(from: fixed) }
        if options.stripSerial { removeSerial(from: fixed) }
        return fixed
    }

    private static let serialTagNames: Set<String> = [
        "BodySerialNumber", "LensSerialNumber", "CameraOwnerName", "SerialNumber", "InternalSerialNumber", "OwnerName",
    ]

    private static func carriedProperties(for url: URL, width: Int, height: Int, options: ExportOptions) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = width
            exif[kCGImagePropertyExifPixelYDimension as String] = height
            if options.stripSerial {
                for k in [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName] {
                    exif.removeValue(forKey: k as String)
                }
            }
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        if options.stripSerial, var aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] {
            for k in [kCGImagePropertyExifAuxSerialNumber, kCGImagePropertyExifAuxOwnerName] { aux.removeValue(forKey: k as String) }
            props[kCGImagePropertyExifAuxDictionary as String] = aux
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyHasAlpha,
                  kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyJFIFDictionary,
                  kCGImagePropertyFileContentsDictionary] {
            props.removeValue(forKey: k as String)
        }
        if options.stripGPS { props.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        return props
    }

    /// 裁剪、拉直（Straighten.swift）和导出共用：把原文件的元数据整份拿来，只改方向、像素尺寸和老式 IPTC 日期
    static func fixedMetadata(from src: CGImageSource, width: Int, height: Int) -> CGMutableImageMetadata? {
        guard let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let fixed = CGImageMetadataCreateMutableCopy(meta) else { return nil }
        CGImageMetadataSetValueMatchingImageProperty(fixed, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(fixed, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(fixed, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height as CFNumber)
        // 老式 IPTC 的创建日期：系统写文件时是从 XMP 的 photoshop:DateCreated 换算出来的，那里写得不标准（28 Jan 2016）
        // 就换算不了，整项丢掉。认得出来的先改成标准写法，日期就能留下
        let datePath = "photoshop:DateCreated" as CFString
        if let raw = CGImageMetadataCopyStringValueWithPath(fixed, nil, datePath) as String?, let iso = ExifReader.normalizedXMPDate(raw) {
            CGImageMetadataSetValueWithPath(fixed, nil, datePath, iso as CFString)
        }
        return fixed
    }

    /// 去掉全部 GPS 项（exif:GPSLatitude 之类）
    private static func removeGPS(from meta: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { _, tag in
            if let name = CGImageMetadataTagCopyName(tag) as String?, name.hasPrefix("GPS"),
               let prefix = CGImageMetadataTagCopyPrefix(tag) as String? { paths.append("\(prefix):\(name)") }
            return true
        }
        for p in paths { CGImageMetadataRemoveTagWithPath(meta, nil, p as CFString) }
    }

    /// 去掉机身、镜头序列号和机主名（BodySerialNumber / LensSerialNumber / aux:SerialNumber / CameraOwnerName 等）
    private static func removeSerial(from meta: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { path, tag in
            if let name = CGImageMetadataTagCopyName(tag) as String?, serialTagNames.contains(name) {
                paths.append(path as String)
            }
            return true
        }
        for p in paths { CGImageMetadataRemoveTagWithPath(meta, nil, p as CFString) }
    }

    // MARK: - 色彩与缩放

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 已经是 sRGB 吗：命名的 sRGB，或描述文件里写着 sRGB（相机和软件嵌入的 sRGB IEC61966-2.1）
    static func isSRGB(_ cs: CGColorSpace?) -> Bool {
        guard let cs else { return false }
        if cs.name as String? == CGColorSpace.sRGB as String { return true }
        guard cs.model == .rgb, let icc = cs.copyICCData() as Data? else { return false }
        return icc.prefix(512).range(of: Data("sRGB".utf8)) != nil
    }

    /// 系统自带的 sRGB 描述文件做成的色彩空间：带着 ICC 数据，写出去的文件里才真有一份 sRGB 描述文件
    /// （用命名的 sRGB 色彩空间，ImageIO 会省掉 ICC，只在 EXIF 里标一下）
    static let embeddedSRGB: CGColorSpace? = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")),
              let cs = CGColorSpace(iccData: data as CFData) else { return nil }
        return cs
    }()

    /// 像素换算到 sRGB 并标上 sRGB；已经是就不动（返回 nil）
    static func converted(_ image: CGImage) -> CGImage? {
        guard !isSRGB(image.colorSpace), let srgb = embeddedSRGB ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ci = CIImage(cgImage: image)
        return ciContext.createCGImage(ci, from: ci.extent, format: image.bitsPerComponent > 8 ? .RGBAh : .RGBA8, colorSpace: srgb)
    }

    /// 高质量缩小（Core Image 的 Lanczos），长边缩到 longEdge；只缩小不放大，色彩空间保持
    static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard longEdge > 0, longEdge < long else { return image }
        let s = Double(longEdge) / Double(long)
        let nw = image.width >= image.height ? longEdge : max(1, Int((Double(image.width) * s).rounded()))
        let nh = image.width >= image.height ? max(1, Int((Double(image.height) * s).rounded())) : longEdge
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(s, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let out = f.outputImage else { return nil }
        // 滤镜输出的边缘会有一圈半透明，先把边缘延伸出去再裁成目标尺寸
        let rect = CGRect(x: 0, y: 0, width: nw, height: nh)
        let cropped = out.clampedToExtent().cropped(to: rect)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.createCGImage(cropped, from: rect, format: image.bitsPerComponent > 8 ? .RGBAh : .RGBA8, colorSpace: space)
    }
}

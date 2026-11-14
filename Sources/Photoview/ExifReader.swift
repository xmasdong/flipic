import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExifEntry {
    let label: String
    let value: String
    /// 点击后打开的地址（拍摄地点用来在「地图」里打开）
    var link: URL? = nil
    /// 值最多排几行，超出的截断（鼠标停上去能看全）
    var lines: Int = 2
}

/// 「全部」里的一组
struct InfoSection {
    let title: String
    var rows: [ExifEntry]
    /// 拍摄参数那一组：面板把直方图排在它的各行上面
    var isShooting = false
}

/// 照片信息面板的内容。标题和说明在两级里都排在最上面；「常用」接 common，「全部」接 captionRows 和 sections
struct PhotoInfo {
    /// IPTC 标题（Headline，没有就用 ObjectName）
    var title: String?
    /// 图片说明：IPTC Caption，没有就用 XMP dc:description，再没有用 TIFF ImageDescription
    var caption: String?
    /// 说明只是相机自己写的占位文字（OLYMPUS DIGITAL CAMERA 这类）：「常用」里不显示，「全部」里照原样显示
    var captionIsBoilerplate = false
    var common: [ExifEntry] = []
    /// 「全部」里「说明」这一组除标题和正文以外的行
    var captionRows: [ExifEntry] = []
    var sections: [InfoSection] = []
    /// 视频：只有一列，不分级
    var isFlat = false
}

/// 信息条用的摘要
struct ExifSummary {
    var camera: String?
    var lens: String?
    var params: String?   // ƒ/1.8 · 1/250 s · ISO 64 · 24 mm
    var date: String?
}

enum ExifReader {
    /// 只读文件头，速度很快，适合每次翻图时调用
    static func summary(url: URL) -> ExifSummary {
        var s = ExifSummary(camera: nil, lens: nil, params: nil, date: nil)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return s
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        let model = tiff?["Model"] as? String
        let make = tiff?["Make"] as? String
        if let model, !model.isEmpty {
            s.camera = (make.map { model.hasPrefix($0) } ?? false) ? model : [make, model].compactMap { $0 }.joined(separator: " ")
        }
        if let lens = exif?["LensModel"] as? String, !lens.isEmpty { s.lens = lens }
        var shot = [String]()
        if let t = exif?["ExposureTime"] as? Double, t > 0 { shot.append(shutterText(t)) }
        if let f = exif?["FNumber"] as? Double, f > 0 { shot.append(String(format: "ƒ/%.1f", f)) }
        if let list = exif?["ISOSpeedRatings"] as? [Any], let iso = list.compactMap({ $0 as? Int }).first {
            shot.append("ISO \(iso)")
        }
        if let fl = exif?["FocalLength"] as? Double, fl > 0 { shot.append(String(format: "%.0f mm", fl)) }
        if !shot.isEmpty { s.params = shot.joined(separator: " · ") }
        if let date = captureDate(exif) { s.date = formatExifDate(date) }
        return s
    }

    /// 常用那一级的各行；视频走 VideoInfo
    static func read(url: URL) -> [ExifEntry] {
        info(url: url).common
    }

    /// 照片信息面板要的全部内容：顶部的说明块、「常用」的各行、「全部」的各组
    static func info(url: URL) -> PhotoInfo {
        var info = PhotoInfo()
        if Video.isVideo(url) {
            info.common = VideoInfo.read(url: url)
            info.isFlat = true
            return info
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return info
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        func xmpText(_ path: String) -> String? {
            guard let xmp else { return nil }
            return clean(CGImageMetadataCopyStringValueWithPath(xmp, nil, path as CFString) as String?)
        }
        func iptcText(_ key: CFString) -> String? { list(iptc?[key as String]).first }
        func iptcList(_ key: CFString) -> [String] { list(iptc?[key as String]) }
        func row(_ key: String, _ zh: String, _ value: String?, lines: Int = 2) -> ExifEntry? {
            guard let value, !value.isEmpty else { return nil }
            return ExifEntry(label: L10n.t(key, zh), value: value, lines: lines)
        }

        // MARK: 说明块

        // ObjectName 常常只是编号（P13074），有 Headline 就用 Headline 当标题，ObjectName 在「全部」里单独一行
        let headline = iptcText(kCGImagePropertyIPTCHeadline) ?? xmpText("photoshop:Headline")
        let objectName = iptcText(kCGImagePropertyIPTCObjectName) ?? xmpText("dc:title")
        info.title = headline ?? objectName
        // 相机自己写进去的占位说明（OLYMPUS DIGITAL CAMERA 这类）排到最后：有别的真说明就用真的
        var captions = [iptcText(kCGImagePropertyIPTCCaptionAbstract), xmpText("dc:description"),
                        clean(tiff?[kCGImagePropertyTIFFImageDescription as String])].compactMap { $0 }
        // IPTC 的说明最多 2000 字节，长说明（中文六百多字）在那里是截断的，全文在 XMP 里：后面有更完整的同一段就用完整的
        if let first = captions.first, let fuller = captions.dropFirst().first(where: { $0.count > first.count && $0.hasPrefix(first.prefix(200)) }) {
            captions[0] = fuller
        }
        if let real = captions.first(where: { !isCameraBoilerplate($0) }) {
            info.caption = real
        } else if let placeholder = captions.first {
            info.caption = placeholder
            info.captionIsBoilerplate = true
        }

        // MARK: 说明、署名

        let keywords = row("exif.keywords", "关键词", iptcList(kCGImagePropertyIPTCKeywords).joined(separator: ", "), lines: 6)
        let bylines = iptcList(kCGImagePropertyIPTCByline)
        let creator = row("exif.artist", "作者", bylines.isEmpty ? clean(tiff?["Artist"]) : bylines.joined(separator: ", "))
        let credit = iptcText(kCGImagePropertyIPTCCredit), source = iptcText(kCGImagePropertyIPTCSource)
        let copyright = row("exif.copyright", "版权", clean(tiff?["Copyright"]) ?? iptcText(kCGImagePropertyIPTCCopyrightNotice) ?? xmpText("dc:rights"), lines: 4)
        // 国家 / 省 / 市 / 具体地点，从大到小
        let placeParts = [iptcText(kCGImagePropertyIPTCCountryPrimaryLocationName), iptcText(kCGImagePropertyIPTCProvinceState),
                          iptcText(kCGImagePropertyIPTCCity), iptcText(kCGImagePropertyIPTCSubLocation)].compactMap { $0 }
        let place = row("exif.place", "地名", placeParts.joined(separator: " · "), lines: 3)

        // MARK: 拍摄

        let model = clean(tiff?["Model"]), make = clean(tiff?["Make"])
        let camera = row("exif.camera", "相机", model.map { m in (make.map { m.hasPrefix($0) } ?? false) ? m : [make, m].compactMap { $0 }.joined(separator: " ") })
        let lens = row("exif.lens", "镜头", clean(exif?["LensModel"]))
        let shutter = (exif?["ExposureTime"] as? Double).flatMap { $0 > 0 ? shutterText($0) : nil }
        let aperture = (exif?["FNumber"] as? Double).flatMap { $0 > 0 ? String(format: "ƒ/%.1f", $0) : nil }
        let iso = (exif?["ISOSpeedRatings"] as? [Any])?.compactMap { $0 as? Int }.first
        let focal = (exif?["FocalLength"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        let focal35 = (exif?["FocalLenIn35mmFilm"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        var shot = [String]()
        if let shutter { shot.append(shutter) }
        if let aperture { shot.append(aperture) }
        if let iso { shot.append("ISO \(iso)") }
        if let focal {
            var t = String(format: "%.0f mm", focal)
            // 等效焦距：手机和 APS-C 机身的实际焦距不好对照，括号里给 35mm 等效
            if let focal35, abs(Double(focal35) - focal) >= 1 {
                t += " " + L10n.f("exif.equiv", "（等效 %d mm）", focal35)
            }
            shot.append(t)
        }
        let params = row("exif.params", "拍摄参数", shot.joined(separator: " · "))
        let bias = row("exif.bias", "曝光补偿", (exif?["ExposureBiasValue"] as? Double).flatMap { $0 != 0 ? String(format: "%+.1f EV", $0) : nil })
        let program = row("exif.program", "曝光模式", programText(exif?["ExposureProgram"] as? Int))
        let metering = row("exif.metering", "测光", meteringText(exif?["MeteringMode"] as? Int))
        let flashBits = exif?["Flash"] as? Int
        let flash = row("exif.flash", "闪光灯", flashBits.map { $0 & 1 == 1 ? L10n.t("exif.flashOn", "闪光") : L10n.t("exif.flashOff", "未闪光") })
        let wb = row("exif.wb", "白平衡", (exif?["WhiteBalance"] as? Int).map { $0 == 1 ? L10n.t("exif.wbManual", "手动") : L10n.t("exif.wbAuto", "自动") })
        let taken = captureDate(exif)
        // 通讯社的图常常没有 EXIF，拍摄日期只写在 IPTC 里
        let iptcDate = iptcDateText(iptcText(kCGImagePropertyIPTCDateCreated), iptcText(kCGImagePropertyIPTCTimeCreated))
            ?? xmpDateText(xmpText("photoshop:DateCreated"))
        func dateRow(seconds: Bool) -> ExifEntry? {
            guard let taken else { return row("exif.date", "拍摄时间", iptcDate) }
            var t = formatExifDate(taken, seconds: seconds)
            if let tz = clean(exif?["OffsetTimeOriginal"]) { t += " (UTC" + tz + ")" }
            return row("exif.date", "拍摄时间", t)
        }

        // MARK: 图像

        var size: ExifEntry?
        if let w = props["PixelWidth"] as? Int, let h = props["PixelHeight"] as? Int {
            let mp = Double(w * h) / 1_000_000
            size = row("exif.size", "尺寸", "\(w) × \(h) · " + L10n.f("exif.megapixels", "%@ 百万像素", String(format: mp >= 10 ? "%.0f" : "%.1f", mp)))
        }
        let format = row("exif.format", "格式", (CGImageSourceGetType(src) as String?).flatMap { UTType($0)?.localizedDescription })
        let depth = row("exif.depth", "色深", depthText(src: src, props: props))
        let profile = row("exif.profile", "色彩描述", clean(props[kCGImagePropertyProfileName as String]))
        let software = row("exif.software", "软件", clean(tiff?["Software"]))

        // MARK: 文件

        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attr?[.size] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file) }
        let file = row("exif.file", "文件", bytes.map { url.lastPathComponent + " · " + $0 })

        // MARK: 常用：署名和地名在前，其余和以前一样

        var creditLine = [String]()
        for s in [credit, source].compactMap({ $0 }) where !creditLine.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { creditLine.append(s) }
        info.common = [creator, row("exif.credit", "署名", creditLine.joined(separator: " · ")), copyright, place, keywords,
                       camera, lens, params, bias, program, metering, flash, wb, dateRow(seconds: false),
                       size, format, depth, profile, location(props, altitude: true), software, file].compactMap { $0 }

        // MARK: 全部：分组

        // 标题和说明正文由面板顶部的说明块显示，这里是这一组剩下的行
        var categories = iptcList(kCGImagePropertyIPTCSupplementalCategory)
        if let c = iptcText(kCGImagePropertyIPTCCategory) { categories.insert(c, at: 0) }
        info.captionRows = [
            row("exif.objectName", "对象名称", headline != nil && objectName != headline ? objectName : nil),
            keywords,
            row("exif.category", "类别", categories.joined(separator: ", "), lines: 3),
            row("exif.urgency", "紧急程度", iptcText(kCGImagePropertyIPTCUrgency)),
            row("exif.instructions", "特别说明", iptcText(kCGImagePropertyIPTCSpecialInstructions), lines: 6),
            row("exif.writer", "说明撰写", iptcText(kCGImagePropertyIPTCWriterEditor)),
        ].compactMap { $0 }

        let contact = iptc?[kCGImagePropertyIPTCCreatorContactInfo as String] as? [String: Any]
        func contactText(_ key: CFString) -> String? { clean(contact?[key as String]) }
        let address = [contactText(kCGImagePropertyIPTCContactInfoAddress), contactText(kCGImagePropertyIPTCContactInfoCity),
                       contactText(kCGImagePropertyIPTCContactInfoStateProvince), contactText(kCGImagePropertyIPTCContactInfoPostalCode),
                       contactText(kCGImagePropertyIPTCContactInfoCountry)].compactMap { $0 }
            .map { $0.replacingOccurrences(of: "\n", with: ", ") }
        let rights = [
            creator,
            row("exif.jobTitle", "职务", iptcList(kCGImagePropertyIPTCBylineTitle).joined(separator: ", ")),
            row("exif.address", "地址", address.joined(separator: ", "), lines: 4),
            row("exif.email", "电子邮件", contactText(kCGImagePropertyIPTCContactInfoEmails), lines: 3),
            row("exif.phone", "电话", contactText(kCGImagePropertyIPTCContactInfoPhones), lines: 3),
            row("exif.website", "网站", contactText(kCGImagePropertyIPTCContactInfoWebURLs), lines: 3),
            row("exif.credit", "署名", credit),
            row("exif.source", "来源", source),
            row("exif.transmission", "传输编号", iptcText(kCGImagePropertyIPTCOriginalTransmissionReference)),
            copyright,
            row("exif.usage", "使用条款", iptcText(kCGImagePropertyIPTCRightsUsageTerms) ?? xmpText("xmpRights:UsageTerms"), lines: 8),
        ].compactMap { $0 }

        var digitized: ExifEntry?
        if let d = clean(exif?["DateTimeDigitized"]), d != taken {
            digitized = row("exif.digitized", "数字化时间", formatExifDate(d, seconds: true))
        } else if let d = iptcDateText(iptcText(kCGImagePropertyIPTCDigitalCreationDate), iptcText(kCGImagePropertyIPTCDigitalCreationTime)),
                  d != iptcDate, !(taken.map { formatExifDate($0).hasPrefix(d) } ?? false) {
            digitized = row("exif.digitized", "数字化时间", d)
        }
        // EXIF 和 IPTC 都写了日期、两边不是同一天（或同一分钟）时，IPTC 的另起一行
        var iptcDateRow: ExifEntry?
        if let taken, let iptcDate, !formatExifDate(taken).hasPrefix(iptcDate.components(separatedBy: " (").first ?? iptcDate) {
            iptcDateRow = row("exif.iptcDate", "IPTC 创建日期", iptcDate)
        }
        let shooting = [
            camera, lens,
            row("exif.focal", "焦距", focal.map { String(format: $0 < 10 ? "%.1f mm" : "%.0f mm", $0) }),
            row("exif.focal35", "35 mm 等效焦距", focal35.map { "\($0) mm" }),
            row("exif.aperture", "光圈", aperture),
            row("exif.shutter", "快门", shutter),
            row("exif.iso", "ISO", iso.map { "\($0)" }),
            bias, program, metering, flash, wb, dateRow(seconds: true), iptcDateRow, digitized,
        ].compactMap { $0 }

        var dpi: String?
        if let x = props[kCGImagePropertyDPIWidth as String] as? Double, x > 0 {
            let y = props[kCGImagePropertyDPIHeight as String] as? Double ?? x
            dpi = abs(x - y) < 0.5 ? String(format: "%.0f dpi", x) : String(format: "%.0f × %.0f dpi", x, y)
        }
        func yesNo(_ b: Bool) -> String { b ? L10n.t("exif.yes", "是") : L10n.t("exif.no", "否") }
        var colorModel = clean(props[kCGImagePropertyColorModel as String])
        if colorModel == (kCGImagePropertyColorModelGray as String) { colorModel = L10n.t("exif.gray", "灰度") }
        let image = [
            size, format, depth,
            row("exif.colorModel", "颜色模型", colorModel),
            profile,
            row("exif.alpha", "透明通道", (props[kCGImagePropertyHasAlpha as String] as? Bool).map(yesNo)),
            row("exif.orientation", "方向", orientationText(props[kCGImagePropertyOrientation as String] as? Int)),
            row("exif.dpi", "分辨率", dpi),
            // 闪光灯字段的第 6 位：拍的时候开没开防红眼
            row("exif.redEye", "防红眼", flashBits.map { yesNo($0 & 0x40 != 0) }),
        ].compactMap { $0 }

        let dates = DateFormatter()
        dates.dateFormat = "yyyy-MM-dd HH:mm"
        let fileRows = [
            row("exif.fileName", "名称", url.lastPathComponent, lines: 3),
            row("exif.fileSize", "大小", bytes),
            row("exif.created", "创建时间", (attr?[.creationDate] as? Date).map { dates.string(from: $0) }),
            row("exif.modified", "修改时间", (attr?[.modificationDate] as? Date).map { dates.string(from: $0) }),
            software,
        ].compactMap { $0 }

        info.sections = [
            InfoSection(title: L10n.t("exif.sec.rights", "署名与版权"), rows: rights),
            InfoSection(title: L10n.t("exif.sec.shooting", "拍摄"), rows: shooting, isShooting: true),
            InfoSection(title: L10n.t("exif.sec.image", "图像"), rows: image),
            InfoSection(title: L10n.t("exif.sec.place", "地点"), rows: [location(props, altitude: false), altitude(props), place].compactMap { $0 }),
            InfoSection(title: L10n.t("exif.sec.file", "文件"), rows: fileRows),
        ].filter { !$0.rows.isEmpty }
        return info
    }

    /// EXIF 的拍摄时间（yyyy:MM:dd HH:mm:ss）。面板和底部信息条都用这一个。
    /// 文件里同时有 IPTC 日期（只到天）时，系统会拿它盖掉 EXIF 的拍摄时间，变成 00:00:00；
    /// 数字化时间是同一天、带着真正的时分秒，就用它
    static func captureDate(_ exif: [String: Any]?) -> String? {
        let taken = clean(exif?["DateTimeOriginal"])
        if let t = taken, t.hasSuffix(" 00:00:00"), let d = clean(exif?["DateTimeDigitized"]), d.hasPrefix(t.prefix(10)), d != t { return d }
        return taken
    }

    /// XMP 里写得不标准、但认得出来的日期（美联社老文件的 28 Jan 2016）改成标准写法 2016-01-28；本来就标准或者认不出的返回 nil
    static func normalizedXMPDate(_ s: String) -> String? {
        guard s.range(of: "^\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) == nil,
              let fixed = xmpDateText(s), fixed.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
        return fixed
    }

    private static func clean(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return t.isEmpty ? nil : t
    }

    /// IPTC 的日期 20160128（或 2016:01:28）和时间 185327+0000 → 2016-01-28 18:53 (UTC+00:00)；只有日期就只出日期
    private static func iptcDateText(_ date: String?, _ time: String?) -> String? {
        guard let date else { return nil }
        let d = date.filter(\.isNumber)
        guard d.count == 8 else { return date }
        var out = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
        if let time {
            let digits = time.prefix { $0.isNumber || $0 == ":" }.filter(\.isNumber)
            if digits.count >= 4 {
                out += " \(digits.prefix(2)):\(digits.dropFirst(2).prefix(2))"
                let zone = time.drop { $0.isNumber || $0 == ":" }.filter { $0.isNumber || $0 == "+" || $0 == "-" }
                if zone.count == 5 { out += " (UTC\(zone.prefix(3)):\(zone.suffix(2)))" }
            }
        }
        return out
    }

    /// XMP 里的创建日期：标准写法是 2016-01-28T18:53:27+00:00，美联社的老文件写成 28 Jan 2016。认不出的照原样显示
    private static func xmpDateText(_ s: String?) -> String? {
        guard let s else { return nil }
        if s.range(of: "^\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) != nil {
            let t = s.replacingOccurrences(of: "T", with: " ")
            return t.count > 16 ? String(t.prefix(16)) : t
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["d MMM yyyy", "MMM d, yyyy", "yyyy:MM:dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) {
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: d)
            }
        }
        return s
    }

    /// IPTC 里可以重复的字段：ImageIO 有时给数组，有时只给一个字符串
    private static func list(_ v: Any?) -> [String] {
        if let a = v as? [Any] { return a.compactMap { clean($0) } }
        return clean(v).map { [$0] } ?? []
    }

    /// 相机固件自己填进「说明」的占位文字，不是拍摄者写的。只认整段完全相同的（不分大小写）
    private static let boilerplate: Set<String> = [
        "olympus digital camera", "sony dsc", "samsung camera pictures", "exif_jpeg_picture",
        "pentax image", "digital camera", "default",
        // 华为 / 荣耀手机按拍照模式写的缩写
        "cof", "sdr", "dav", "oznor", "oznorwo", "ozedf", "mde", "btf", "bsh", "rhdr", "edf", "nor", "ptr", "fbt", "qrf", "bdr",
    ]

    static func isCameraBoilerplate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if boilerplate.contains(t) { return true }
        // KONICA MINOLTA DIGITAL CAMERA、KODAK Digital Still Camera 这类「品牌 + DIGITAL CAMERA」
        if t.range(of: "^[a-z][a-z .-]{0,24} digital (still )?camera$", options: .regularExpression) != nil { return true }
        // 无人机、运动相机把存储卡路径写进来：DCIM\100MEDIA\DJI_0001.JPG
        if t.range(of: "^dcim[\\\\/][^\\s]*$", options: .regularExpression) != nil { return true }
        return false
    }

    /// 每个颜色通道的位数；带 HDR 增益图的照片标出 HDR
    private static func depthText(src: CGImageSource, props: [String: Any]) -> String? {
        guard let bits = props[kCGImagePropertyDepth as String] as? Int, bits > 0 else { return nil }
        var text = L10n.f("exif.bits", "%d 位", bits)
        var hdr = false
        if #available(macOS 15, *), CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil { hdr = true }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { hdr = true }
        if let cs = (props[kCGImagePropertyProfileName as String] as? String), cs.contains("PQ") || cs.contains("HLG") || cs.contains("2100") { hdr = true }
        if hdr { text += " · HDR" }
        return text
    }

    private static func coordinate(_ props: [String: Any]) -> (gps: [String: Any], lat: Double, lon: Double)? {
        guard let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
        if latRef == "S" { lat = -lat }
        if lonRef == "W" { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        return (gps, lat, lon)
    }

    private static func altitudeText(_ gps: [String: Any]) -> String? {
        guard var alt = gps[kCGImagePropertyGPSAltitude as String] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSAltitudeRef as String] as? Int) == 1 { alt = -alt }
        return String(format: "%.0f m", alt)
    }

    /// GPS 坐标：24.78° N, 118.60° E · 12 m，点击在「地图」里打开。「全部」里海拔单独一行
    private static func location(_ props: [String: Any], altitude: Bool) -> ExifEntry? {
        guard let (gps, lat, lon) = coordinate(props) else { return nil }
        var text = String(format: "%.5f° %@, %.5f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
        if altitude, let alt = altitudeText(gps) { text += " · " + alt }
        let link = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%.6f,%.6f", lat, lon, lat, lon))
        return ExifEntry(label: L10n.t("exif.location", "拍摄地点"), value: text, link: link)
    }

    private static func altitude(_ props: [String: Any]) -> ExifEntry? {
        guard let (gps, _, _) = coordinate(props), let alt = altitudeText(gps) else { return nil }
        return ExifEntry(label: L10n.t("exif.altitude", "海拔"), value: alt)
    }

    /// EXIF 方向 1–8：照片要怎么转才是正的
    private static func orientationText(_ v: Int?) -> String? {
        let flip = L10n.t("exif.oFlipH", "水平翻转")
        let cw = L10n.t("exif.oCW", "顺时针旋转 90°"), ccw = L10n.t("exif.oCCW", "逆时针旋转 90°")
        switch v {
        case 1: return L10n.t("exif.oNormal", "正常")
        case 2: return flip
        case 3: return L10n.t("exif.o180", "旋转 180°")
        case 4: return L10n.t("exif.oFlipV", "垂直翻转")
        case 5: return flip + " · " + ccw
        case 6: return cw
        case 7: return flip + " · " + cw
        case 8: return ccw
        default: return nil
        }
    }

    private static func programText(_ v: Int?) -> String? {
        switch v {
        case 1: return L10n.t("exif.pManual", "手动 (M)")
        case 2: return L10n.t("exif.pProgram", "程序自动 (P)")
        case 3: return L10n.t("exif.pAperture", "光圈优先 (A)")
        case 4: return L10n.t("exif.pShutter", "快门优先 (S)")
        case 5: return L10n.t("exif.pCreative", "创意（偏景深）")
        case 6: return L10n.t("exif.pAction", "运动（偏快门速度）")
        case 7: return L10n.t("exif.pPortrait", "人像")
        case 8: return L10n.t("exif.pLandscape", "风景")
        default: return nil
        }
    }

    private static func meteringText(_ v: Int?) -> String? {
        switch v {
        case 1: return L10n.t("exif.mAverage", "平均")
        case 2: return L10n.t("exif.mCenter", "中央重点")
        case 3: return L10n.t("exif.mSpot", "点测光")
        case 4: return L10n.t("exif.mMultiSpot", "多点")
        case 5: return L10n.t("exif.mPattern", "评价测光")
        case 6: return L10n.t("exif.mPartial", "局部")
        default: return nil
        }
    }

    private static func shutterText(_ t: Double) -> String {
        t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s"
    }

    private static func formatExifDate(_ s: String, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { return s }
        let out = DateFormatter()
        out.dateFormat = seconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return out.string(from: d)
    }
}

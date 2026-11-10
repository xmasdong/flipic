import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExifEntry {
    let label: String
    let value: String
    /// 点击后打开的地址（拍摄地点用来在「地图」里打开）
    var link: URL? = nil
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
        if let date = exif?["DateTimeOriginal"] as? String, !date.isEmpty { s.date = formatExifDate(date) }
        return s
    }

    static func read(url: URL) -> [ExifEntry] {
        if Video.isVideo(url) { return VideoInfo.read(url: url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return []
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]

        var entries: [ExifEntry] = []

        let model = tiff?["Model"] as? String
        let make = tiff?["Make"] as? String
        if let model, !model.isEmpty {
            let camera = (make.map { model.hasPrefix($0) } ?? false) ? model : [make, model].compactMap { $0 }.joined(separator: " ")
            entries.append(ExifEntry(label: L10n.t("exif.camera", "相机"), value: camera))
        }
        if let lens = exif?["LensModel"] as? String, !lens.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.lens", "镜头"), value: lens))
        }
        var shot = [String]()
        if let t = exif?["ExposureTime"] as? Double, t > 0 { shot.append(shutterText(t)) }
        if let f = exif?["FNumber"] as? Double, f > 0 { shot.append(String(format: "ƒ/%.1f", f)) }
        if let list = exif?["ISOSpeedRatings"] as? [Any], let iso = list.compactMap({ $0 as? Int }).first {
            shot.append("ISO \(iso)")
        }
        if let fl = exif?["FocalLength"] as? Double, fl > 0 {
            var t = String(format: "%.0f mm", fl)
            // 等效焦距：手机和 APS-C 机身的实际焦距不好对照，括号里给 35mm 等效
            if let eq = exif?["FocalLenIn35mmFilm"] as? Int, eq > 0, abs(Double(eq) - fl) >= 1 {
                t += " " + L10n.f("exif.equiv", "（等效 %d mm）", eq)
            }
            shot.append(t)
        }
        if !shot.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.params", "拍摄参数"), value: shot.joined(separator: " · ")))
        }
        if let bias = exif?["ExposureBiasValue"] as? Double, bias != 0 {
            entries.append(ExifEntry(label: L10n.t("exif.bias", "曝光补偿"), value: String(format: "%+.1f EV", bias)))
        }
        if let mode = programText(exif?["ExposureProgram"] as? Int) {
            entries.append(ExifEntry(label: L10n.t("exif.program", "曝光模式"), value: mode))
        }
        if let m = meteringText(exif?["MeteringMode"] as? Int) {
            entries.append(ExifEntry(label: L10n.t("exif.metering", "测光"), value: m))
        }
        if let flash = exif?["Flash"] as? Int {
            entries.append(ExifEntry(label: L10n.t("exif.flash", "闪光灯"),
                                     value: flash & 1 == 1 ? L10n.t("exif.flashOn", "闪光") : L10n.t("exif.flashOff", "未闪光")))
        }
        if let wb = exif?["WhiteBalance"] as? Int {
            entries.append(ExifEntry(label: L10n.t("exif.wb", "白平衡"),
                                     value: wb == 1 ? L10n.t("exif.wbManual", "手动") : L10n.t("exif.wbAuto", "自动")))
        }
        if let date = exif?["DateTimeOriginal"] as? String, !date.isEmpty {
            var t = formatExifDate(date)
            if let tz = exif?["OffsetTimeOriginal"] as? String, !tz.isEmpty { t += " (UTC" + tz + ")" }
            entries.append(ExifEntry(label: L10n.t("exif.date", "拍摄时间"), value: t))
        }
        if let w = props["PixelWidth"] as? Int, let h = props["PixelHeight"] as? Int {
            let mp = Double(w * h) / 1_000_000
            entries.append(ExifEntry(label: L10n.t("exif.size", "尺寸"),
                                     value: "\(w) × \(h) · " + L10n.f("exif.megapixels", "%@ 百万像素", String(format: mp >= 10 ? "%.0f" : "%.1f", mp))))
        }
        if let type = CGImageSourceGetType(src) as String?, let desc = UTType(type)?.localizedDescription {
            entries.append(ExifEntry(label: L10n.t("exif.format", "格式"), value: desc))
        }
        if let depth = depthText(src: src, props: props) {
            entries.append(ExifEntry(label: L10n.t("exif.depth", "色深"), value: depth))
        }
        if let profile = props[kCGImagePropertyProfileName as String] as? String, !profile.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.profile", "色彩描述"), value: profile))
        }
        if let place = location(props) {
            entries.append(place)
        }
        if let sw = tiff?["Software"] as? String, !sw.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.software", "软件"), value: sw))
        }
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        if let artist = (tiff?["Artist"] as? String) ?? (iptc?["Byline"] as? [String])?.first, !artist.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.artist", "作者"), value: artist))
        }
        if let c = (tiff?["Copyright"] as? String) ?? (iptc?["CopyrightNotice"] as? String), !c.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.copyright", "版权"), value: c))
        }
        if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attr[.size] as? Int {
            entries.append(ExifEntry(label: L10n.t("exif.file", "文件"),
                                     value: url.lastPathComponent + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        return entries
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

    /// GPS 坐标：24.78° N, 118.60° E · 12 m，点击在「地图」里打开
    private static func location(_ props: [String: Any]) -> ExifEntry? {
        guard let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
        if latRef == "S" { lat = -lat }
        if lonRef == "W" { lon = -lon }
        guard abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        var text = String(format: "%.5f° %@, %.5f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
        if var alt = gps[kCGImagePropertyGPSAltitude as String] as? Double {
            if (gps[kCGImagePropertyGPSAltitudeRef as String] as? Int) == 1 { alt = -alt }
            text += String(format: " · %.0f m", alt)
        }
        let link = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%.6f,%.6f", lat, lon, lat, lon))
        return ExifEntry(label: L10n.t("exif.location", "拍摄地点"), value: text, link: link)
    }

    private static func programText(_ v: Int?) -> String? {
        switch v {
        case 1: return L10n.t("exif.pManual", "手动 (M)")
        case 2: return L10n.t("exif.pProgram", "程序自动 (P)")
        case 3: return L10n.t("exif.pAperture", "光圈优先 (A)")
        case 4: return L10n.t("exif.pShutter", "快门优先 (S)")
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

    private static func formatExifDate(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { return s }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd HH:mm"
        return out.string(from: d)
    }
}

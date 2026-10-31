import Foundation
import ImageIO

struct ExifEntry {
    let label: String
    let value: String
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
        if let fl = exif?["FocalLength"] as? Double, fl > 0 { shot.append(String(format: "%.0f mm", fl)) }
        if !shot.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.params", "拍摄参数"), value: shot.joined(separator: " · ")))
        }
        if let bias = exif?["ExposureBiasValue"] as? Double, bias != 0 {
            entries.append(ExifEntry(label: L10n.t("exif.bias", "曝光补偿"), value: String(format: "%+.1f EV", bias)))
        }
        if let date = exif?["DateTimeOriginal"] as? String, !date.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.date", "拍摄时间"), value: formatExifDate(date)))
        }
        if let w = props["PixelWidth"] as? Int, let h = props["PixelHeight"] as? Int {
            entries.append(ExifEntry(label: L10n.t("exif.size", "尺寸"), value: "\(w) × \(h)"))
        }
        if let profile = props[kCGImagePropertyProfileName as String] as? String, !profile.isEmpty {
            entries.append(ExifEntry(label: L10n.t("exif.profile", "色彩描述"), value: profile))
        }
        if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attr[.size] as? Int {
            entries.append(ExifEntry(label: L10n.t("exif.file", "文件"),
                                     value: url.lastPathComponent + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        return entries
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

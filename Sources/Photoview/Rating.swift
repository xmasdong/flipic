import Foundation
import ImageIO

/// 星级评分（0 = 未评分，1–5 星），按 XMP 标准写 xmp:Rating，Lightroom、Bridge、Capture One 都认。
/// JPEG / HEIC / PNG / TIFF / DNG 写进文件本身，只改元数据不重新编码；
/// 索尼、佳能、尼康这些专有 RAW 写在同名 .xmp 旁车文件里（Adobe 的惯例），不碰原始文件
enum Rating {
    private static let embeddable: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng"]

    static func read(_ url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        if !embeddable.contains(ext) || CleanupUnit.isRaw(url) && ext != "dng" {
            if let r = readSidecar(sidecarURL(for: url)) { return r }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(meta, nil, "xmp:Rating" as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else {
            return sidecarFallback(url)
        }
        return clamp(Int("\(value)") ?? 0)
    }

    /// 嵌入写不进去的格式，之前可能落到了旁车文件
    private static func sidecarFallback(_ url: URL) -> Int {
        readSidecar(sidecarURL(for: url)) ?? 0
    }

    /// 写入评分；成功返回 true。同名 RAW + JPG 由调用方各写一次
    @discardableResult
    static func write(_ rating: Int, to url: URL) -> Bool {
        let r = clamp(rating)
        let ext = url.pathExtension.lowercased()
        if embeddable.contains(ext), writeEmbedded(r, to: url) {
            FolderWatcher.noteOwnWrite(url)
            // 之前写过旁车文件的，清掉免得两处不一致
            let side = sidecarURL(for: url)
            if FileManager.default.fileExists(atPath: side.path), readSidecar(side) != nil, !hasOtherSidecarOwner(side, except: url) {
                _ = writeSidecar(r, to: side)
            }
            return true
        }
        return writeSidecar(r, to: sidecarURL(for: url))
    }

    /// 一次读出星级和 XMP 颜色标签（同一次打开文件/旁车，不额外多读盘）
    static func readBoth(_ url: URL) -> (rating: Int, label: TagColor?) {
        let ext = url.pathExtension.lowercased()
        let preferSidecar = !embeddable.contains(ext) || (CleanupUnit.isRaw(url) && ext != "dng")
        let side = sidecarURL(for: url)
        var r: Int?
        var lbl: TagColor?
        var sideRead = false
        func loadSidecar() {
            guard !sideRead else { return }
            sideRead = true
            if let text = try? String(contentsOf: side, encoding: .utf8) {
                if r == nil { r = parseSidecarRating(text) }
                if lbl == nil { lbl = parseSidecarLabel(text) }
            }
        }
        if preferSidecar { loadSidecar() }
        if r == nil || lbl == nil,
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            if r == nil, let tag = CGImageMetadataCopyTagWithPath(meta, nil, "xmp:Rating" as CFString),
               let value = CGImageMetadataTagCopyValue(tag) {
                r = clamp(Int("\(value)") ?? 0)
            }
            if lbl == nil, let tag = CGImageMetadataCopyTagWithPath(meta, nil, "xmp:Label" as CFString),
               let value = CGImageMetadataTagCopyValue(tag) {
                lbl = TagColor.fromXMP("\(value)")
            }
        }
        if !preferSidecar && (r == nil || lbl == nil) { loadSidecar() }
        return (r ?? 0, lbl)
    }

    static func readLabel(_ url: URL) -> TagColor? { readBoth(url).label }

    /// 写入 XMP 颜色标签（xmp:Label）；nil = 清除。
    /// 与星级共用无损写入和 .xmp 旁车逻辑，不重压像素，不破坏已有 xmp:Rating 和访达扩展属性
    @discardableResult
    static func writeLabel(_ color: TagColor?, to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if embeddable.contains(ext), writeEmbeddedLabel(color, to: url) {
            FolderWatcher.noteOwnWrite(url)
            let side = sidecarURL(for: url)
            if FileManager.default.fileExists(atPath: side.path), !hasOtherSidecarOwner(side, except: url) {
                _ = writeSidecarLabel(color, to: side)
            }
            return true
        }
        let ok = writeSidecarLabel(color, to: sidecarURL(for: url))
        return ok
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, 0), 5) }

    /// ★★★☆☆ 这样的显示文字
    static func stars(_ n: Int) -> String {
        String(repeating: "★", count: clamp(n)) + String(repeating: "☆", count: 5 - clamp(n))
    }

    // MARK: - 写进文件

    private static func writeEmbedded(_ rating: Int, to url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return false }
        let meta = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(meta, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil),
              CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "\(rating)" as CFString) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".flipic-rating-\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, CGImageSourceGetCount(src), nil) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        // CopyImageSource 只换元数据，像素数据原样拷贝，不会重新压缩
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        // 写完读回来确认，再替换原文件（保留原文件的创建时间等属性）
        guard let check = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let m = CGImageSourceCopyMetadataAtIndex(check, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(m, nil, "xmp:Rating" as CFString),
              let v = CGImageMetadataTagCopyValue(tag), Int("\(v)") == rating else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// 无损把 xmp:Label 写进支持内嵌 XMP 的文件；nil = 去掉 xmp:Label（文件本来就没有就不碰盘）
    private static func writeEmbeddedLabel(_ color: TagColor?, to url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) else { return false }
        let existing = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        if color == nil {
            guard let existing, CGImageMetadataCopyTagWithPath(existing, nil, "xmp:Label" as CFString) != nil else { return true }
        }
        let meta: CGMutableImageMetadata
        let merge: Bool
        if let color {
            meta = CGImageMetadataCreateMutable()
            guard CGImageMetadataRegisterNamespaceForPrefix(meta, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil),
                  CGImageMetadataSetValueWithPath(meta, nil, "xmp:Label" as CFString, color.xmpLabel as CFString) else { return false }
            merge = true
        } else {
            guard let existing, let copy = CGImageMetadataCreateMutableCopy(existing) else { return false }
            CGImageMetadataRemoveTagWithPath(copy, nil, "xmp:Label" as CFString)
            meta = copy
            merge = false
        }
        let savedTags = Marks.readTags(url)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".flipic-label-\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, CGImageSourceGetCount(src), nil) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: merge]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        guard let check = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let m = CGImageSourceCopyMetadataAtIndex(check, 0, nil) else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        let tag = CGImageMetadataCopyTagWithPath(m, nil, "xmp:Label" as CFString)
        let readBack = tag.flatMap { CGImageMetadataTagCopyValue($0) }.flatMap { TagColor.fromXMP("\($0)") }
        guard readBack == color else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            if !savedTags.isEmpty, Marks.readTags(url) != savedTags { _ = Marks.writeTags(savedTags, to: url) }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: - 旁车 .xmp

    static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 同名 JPG 写进了文件本身时，旁车文件可能是 RAW 的，不能动
    private static func hasOtherSidecarOwner(_ side: URL, except url: URL) -> Bool {
        let base = side.deletingPathExtension()
        return CleanupUnit.rawExtensions.contains { ext in
            [ext, ext.uppercased()].contains { e in
                let candidate = base.appendingPathExtension(e)
                return candidate != url && FileManager.default.fileExists(atPath: candidate.path)
            }
        }
    }

    private static func readSidecar(_ side: URL) -> Int? {
        guard let text = try? String(contentsOf: side, encoding: .utf8) else { return nil }
        return parseSidecarRating(text)
    }

    private static func parseSidecarRating(_ text: String) -> Int? {
        for pattern in [#"xmp:Rating\s*=\s*"(-?\d)""#, #"<xmp:Rating>\s*(-?\d)\s*</xmp:Rating>"#] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                return clamp(Int(text[r]) ?? 0)
            }
        }
        return nil
    }

    private static func parseSidecarLabel(_ text: String) -> TagColor? {
        for pattern in [#"xmp:Label\s*=\s*"([^"]*)""#, #"<xmp:Label>\s*([^<]*)\s*</xmp:Label>"#] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                return TagColor.fromXMP(String(text[r]))
            }
        }
        return nil
    }

    /// 已有旁车文件（Lightroom 等写的）只改评分这一项，其余内容原样保留
    private static func writeSidecar(_ rating: Int, to side: URL) -> Bool {
        var text: String
        if let existing = try? String(contentsOf: side, encoding: .utf8) {
            text = existing
            let replaced = replace(in: text, #"xmp:Rating\s*=\s*"-?\d""#, "xmp:Rating=\"\(rating)\"")
                ?? replace(in: text, #"<xmp:Rating>\s*-?\d\s*</xmp:Rating>"#, "<xmp:Rating>\(rating)</xmp:Rating>")
            if let replaced {
                text = replaced
            } else if let r = text.range(of: "<rdf:Description") {
                // 没有评分字段：加到第一个 rdf:Description 上，并补上 xmp 命名空间
                var attrs = " xmp:Rating=\"\(rating)\""
                if !text.contains("xmlns:xmp=") { attrs = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + attrs }
                text.insert(contentsOf: attrs, at: r.upperBound)
            } else {
                text = minimalXMP("xmp:Rating=\"\(rating)\"")
            }
        } else {
            if rating == 0 { return true }   // 没评过分也不用新建文件
            text = minimalXMP("xmp:Rating=\"\(rating)\"")
        }
        do {
            try text.write(to: side, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 已有旁车文件只改 xmp:Label 这一项，xmp:Rating 和 Lightroom 的其他字段原样保留
    private static func writeSidecarLabel(_ color: TagColor?, to side: URL) -> Bool {
        var text: String
        if let existing = try? String(contentsOf: side, encoding: .utf8) {
            text = existing
            if let color {
                let val = color.xmpLabel
                let replaced = replace(in: text, #"xmp:Label\s*=\s*"[^"]*""#, "xmp:Label=\"\(val)\"")
                    ?? replace(in: text, #"<xmp:Label>[^<]*</xmp:Label>"#, "<xmp:Label>\(val)</xmp:Label>")
                if let replaced {
                    text = replaced
                } else if let r = text.range(of: "<rdf:Description") {
                    var attrs = " xmp:Label=\"\(val)\""
                    if !text.contains("xmlns:xmp=") { attrs = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + attrs }
                    text.insert(contentsOf: attrs, at: r.upperBound)
                } else {
                    text = minimalXMP("xmp:Label=\"\(val)\"")
                }
            } else {
                var cleaned = replace(in: text, #"\s*xmp:Label\s*=\s*"[^"]*""#, "") ?? text
                cleaned = replace(in: cleaned, #"\s*<xmp:Label>[^<]*</xmp:Label>"#, "") ?? cleaned
                if cleaned == text { return true }
                text = cleaned
            }
        } else {
            guard let color else { return true }
            text = minimalXMP("xmp:Label=\"\(color.xmpLabel)\"")
        }
        do {
            try text.write(to: side, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func replace(in text: String, _ pattern: String, _ with: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }

    private static func minimalXMP(_ attr: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Flipic">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \(attr)/>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }
}

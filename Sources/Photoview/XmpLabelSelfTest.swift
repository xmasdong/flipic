import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --xmplabeltest <工作文件夹>`：验证 XMP 颜色标签（xmp:Label）嵌入/旁车读写、与 xmp:Rating 和访达标签共存、
/// 导出序列号隐私脱敏、RAW 导出带 xmp:Label、水印 {index} 批量序号，以及看图器端到端同步。最后一行 XMPLABEL summary
extension ViewerViewController {
    func runXmpLabelTest(outDir: String) {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: outDir).appendingPathComponent("xmplabel-\(lang)")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("XMPLABEL \(ok ? "ok  " : "FAIL") [\(lang)] \(what)")
            fflush(stdout)
        }

        // 1. TagColor.fromXMP 映射
        check(TagColor.fromXMP("Red") == .red && TagColor.fromXMP("yellow") == .yellow && TagColor.fromXMP("GREY") == .gray,
              "fromXMP: standard English")
        check(TagColor.fromXMP("Select") == .red && TagColor.fromXMP("Second") == .yellow
              && TagColor.fromXMP("Approved") == .green && TagColor.fromXMP("Review") == .blue && TagColor.fromXMP("To Do") == .purple,
              "fromXMP: Lightroom default label set")
        check(TagColor.fromXMP("红色") == .red && TagColor.fromXMP("蓝色") == .blue && TagColor.fromXMP("unknown_xyz") == nil,
              "fromXMP: localized & unknown")

        // 造合成图（带 EXIF、GPS、机身/镜头序列号）
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeImage(_ name: String, uti: String = UTType.jpeg.identifier, serials: Bool = false) -> URL {
            let u = dir.appendingPathComponent(name)
            let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.45, blue: 0.70, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            var exif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: "2026:11:22 10:11:12"]
            if serials {
                exif[kCGImagePropertyExifBodySerialNumber as String] = "BODY-998877"
                exif[kCGImagePropertyExifLensSerialNumber as String] = "LENS-112233"
                exif[kCGImagePropertyExifCameraOwnerName as String] = "Photographer Zhang"
            }
            let props: [String: Any] = [
                kCGImagePropertyExifDictionary as String: exif,
                kCGImagePropertyGPSDictionary as String: [
                    kCGImagePropertyGPSLatitude as String: 31.23, kCGImagePropertyGPSLatitudeRef as String: "N",
                    kCGImagePropertyGPSLongitude as String: 121.47, kCGImagePropertyGPSLongitudeRef as String: "E",
                ],
                kCGImageDestinationLossyCompressionQuality as String: 0.9,
            ]
            let d = CGImageDestinationCreateWithURL(u as CFURL, uti as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, props as CFDictionary)
            CGImageDestinationFinalize(d)
            return u
        }

        // 2. 嵌入格式（JPEG / PNG / TIFF）：xmp:Label 与 xmp:Rating、EXIF、访达标签共存
        for (name, uti) in [("embed.jpg", UTType.jpeg.identifier), ("embed.png", UTType.png.identifier), ("embed.tif", UTType.tiff.identifier)] {
            let u = makeImage(name, uti: uti)
            _ = Marks.writeTags(["CustomNote\n0", "\(Marks.tagName)\n2"], to: u)
            check(Rating.write(4, to: u), "\(name): write rating 4")
            check(Rating.writeLabel(.green, to: u), "\(name): write label Green")
            let both1 = Rating.readBoth(u)
            check(both1.rating == 4 && both1.label == .green, "\(name): readBoth rating=\(both1.rating) label=\(String(describing: both1.label))")
            check(Marks.readTags(u).contains("CustomNote\n0") && Marks.isMarked(u), "\(name): Finder tags survive XMP write")
            // 改星级不影响颜色标签
            check(Rating.write(5, to: u), "\(name): update rating to 5")
            let both2 = Rating.readBoth(u)
            check(both2.rating == 5 && both2.label == .green, "\(name): rating update keeps label")
            // 清除颜色标签：星级和 EXIF 仍在
            check(Rating.writeLabel(nil, to: u), "\(name): clear label")
            let both3 = Rating.readBoth(u)
            check(both3.rating == 5 && both3.label == nil, "\(name): cleared label, rating=\(both3.rating)")
            let props = CGImageSourceCreateWithURL(u as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            let exif = props?[kCGImagePropertyExifDictionary as String] as? [String: Any]
            check(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:11:22 10:11:12",
                  "\(name): EXIF DateTimeOriginal survives clear")
        }

        // 3. 专有 RAW 旁车 .xmp（保留 Lightroom 自定义字段与 xmp:Rating）
        let raw = dir.appendingPathComponent("shot.arw")
        try? Data("RAWPLACEHOLDER".utf8).write(to: raw)
        let side = Rating.sidecarURL(for: raw)
        let lrcXMP = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmp:Rating="3" xmp:Label="Approved" crs:Exposure2012="+0.50"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try? lrcXMP.write(to: side, atomically: true, encoding: .utf8)
        let rb = Rating.readBoth(raw)
        check(rb.rating == 3 && rb.label == .green, "RAW sidecar read Lightroom Approved -> green, rating=\(rb.rating)")
        check(Rating.writeLabel(.blue, to: raw), "RAW sidecar update label -> Blue")
        let s1 = (try? String(contentsOf: side, encoding: .utf8)) ?? ""
        check(Rating.readBoth(raw) == (3, .blue) && s1.contains("crs:Exposure2012=\"+0.50\""),
              "RAW sidecar updated to Blue while preserving Rating & crs:Exposure2012")
        check(Rating.writeLabel(nil, to: raw), "RAW sidecar clear label")
        let s2 = (try? String(contentsOf: side, encoding: .utf8)) ?? ""
        check(Rating.readBoth(raw) == (3, nil) && s2.contains("crs:Exposure2012=\"+0.50\"") && !s2.contains("xmp:Label"),
              "RAW sidecar cleared label while keeping Rating & crs")

        // 4. 导出隐私脱敏：stripSerial 去掉机身/镜头序列号和机主名，保留拍摄时间和（未勾 stripGPS 时的）GPS
        let privSrc = makeImage("priv.jpg", serials: true)
        func hasSerial(_ data: Data) -> Bool {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
               let ex = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                if ex[kCGImagePropertyExifBodySerialNumber as String] != nil
                    || ex[kCGImagePropertyExifLensSerialNumber as String] != nil
                    || ex[kCGImagePropertyExifCameraOwnerName as String] != nil { return true }
            }
            if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
                var found = false
                CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { _, tag in
                    if let n = CGImageMetadataTagCopyName(tag) as String?,
                       ["BodySerialNumber", "LensSerialNumber", "CameraOwnerName", "SerialNumber"].contains(n) { found = true }
                    return true
                }
                if found { return true }
            }
            return false
        }
        func hasGPS(_ data: Data) -> Bool {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return false }
            return props[kCGImagePropertyGPSDictionary as String] != nil
        }
        func hasDate(_ data: Data) -> Bool {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
                  let ex = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return false }
            return ex[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:11:22 10:11:12"
        }
        if let full = ImageLoader.decodedFull(url: privSrc) {
            var oKeep = ExportOptions(); oKeep.keepMetadata = true; oKeep.stripSerial = false
            let outKeep = ImageExporter.encode(full, source: privSrc, uti: UTType.jpeg.identifier, quality: 90, options: oKeep)
            check(outKeep.map { hasSerial($0.data) && hasGPS($0.data) && hasDate($0.data) } == true, "export keep all: serial + GPS + date kept")

            var oStrip = ExportOptions(); oStrip.keepMetadata = true; oStrip.stripGPS = false; oStrip.stripSerial = true
            let outStrip = ImageExporter.encode(full, source: privSrc, uti: UTType.jpeg.identifier, quality: 90, options: oStrip)
            check(outStrip.map { !hasSerial($0.data) && hasGPS($0.data) && hasDate($0.data) } == true, "export stripSerial only: serial gone, GPS + date kept")

            var oBoth = ExportOptions(); oBoth.keepMetadata = true; oBoth.stripGPS = true; oBoth.stripSerial = true
            let outBoth = ImageExporter.encode(full, source: privSrc, uti: UTType.jpeg.identifier, quality: 90, options: oBoth)
            check(outBoth.map { !hasSerial($0.data) && !hasGPS($0.data) && hasDate($0.data) } == true, "export stripSerial+stripGPS: both gone, date kept")
        } else {
            check(false, "decode privSrc")
        }

        // 5. 水印 {index} 占位符
        let d0 = Date(timeIntervalSince1970: 1_763_769_600)
        check(WatermarkTokens.expand("#{index} {name}", fileName: "DSC0123", date: d0, index: 7) == "#007 DSC0123",
              "WatermarkTokens {index} pads 7 -> 007")
        check(WatermarkTokens.expand("{INDEX}", fileName: "A", date: d0, index: 1234) == "1234",
              "WatermarkTokens {INDEX} case-insensitive & 4-digit")

        // 6. 看图器端到端：从 Lightroom 嵌入的 xmp:Label 读入界面，按 6 同步写 Finder + XMP，清除两边同步清空
        let vdir = dir.appendingPathComponent("viewer")
        try? fm.createDirectory(at: vdir, withIntermediateDirectories: true)
        let lrPic = vdir.appendingPathComponent("a_from_lrc.jpg")
        let cleanPic = vdir.appendingPathComponent("b_clean.jpg")
        try? fm.copyItem(at: privSrc, to: lrPic)
        try? fm.copyItem(at: privSrc, to: cleanPic)
        _ = Rating.writeLabel(.purple, to: lrPic)
        // 确保 lrPic 没有任何访达标签，全靠 xmp:Label 识别
        _ = FinderTags.clearColors(for: lrPic)

        folder.sortKey = .name
        folder.sortReversed = false
        open(url: vdir)
        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }
        }
        at(1.2) {
            self.ratingQueue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(self.folder.current?.url.lastPathComponent == "a_from_lrc.jpg" && self.folder.current?.tagColors.contains(.purple) == true,
                  "viewer loads embedded xmp:Label Purple without Finder tag")
            self.navigateForward(nil)
        }
        at(0.6) {
            check(self.folder.current?.url.lastPathComponent == "b_clean.jpg", "navigated to b_clean.jpg")
            self.toggleTagColor(.red)
            self.ratingQueue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(FinderTags.colors(of: cleanPic).contains(.red) && Rating.readLabel(cleanPic) == .red,
                  "viewer toggleTagColor(.red) writes BOTH Finder tag and xmp:Label=Red")
            self.clearTagColors(nil)
            self.ratingQueue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(FinderTags.colors(of: cleanPic).isEmpty && Rating.readLabel(cleanPic) == nil,
                  "viewer clearTagColors clears BOTH Finder tag and xmp:Label")
        }
        at(0.3) {
            print("XMPLABEL summary [\(lang)] checks=\(checks) failures=\(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        runNext()
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --bordertest <工作文件夹>`：加边框。生成 9600×5400（带拍摄日期和 GPS）和 3000×4000 两张 JPEG，
/// 按各种比例、颜色、尺寸另存，用 ImageIO 查尺寸、取像素、查元数据，原图不动；导出 / 批量转换带边框；
/// 看图里开条、截预览（4:5 白、模糊背景），回车另存、Esc 收起。最后一行 BORDER summary
extension ViewerViewController {
    func runBorderTest(outDir: String) {
        // BORDER_REAL=<照片>：用真照片按 4:5 模糊背景、长边 1440 渲一张 real-blur.jpg 给人看，然后退出
        if let real = ProcessInfo.processInfo.environment["BORDER_REAL"],
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: real) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            var spec = BorderSpec(); spec.w = 4; spec.h = 5; spec.fill = .blur
            let out = spec.render(img, choice: .preset(1440))
            if let out, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outDir + "/real-blur.jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, out, nil); CGImageDestinationFinalize(dest)
            }
            print("BORDER real \(out.map { "\($0.width)x\($0.height)" } ?? "fail")")
            exit(0)
        }
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: outDir).appendingPathComponent("photos-\(lang)")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("BORDER \(ok ? "ok  " : "FAIL") [\(lang)] \(what)")
            fflush(stdout)
        }
        let date = "2024:05:06 07:08:09"
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // 照片是一块蓝色 (51,128,204)，带上完整相机 EXIF 给参数相框测试用
        func make(_ name: String, _ w: Int, _ h: Int, withCamera: Bool = true) -> URL {
            let u = dir.appendingPathComponent(name)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var exifDict: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: date]
            var props: [String: Any] = [
                kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 31.23, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                          kCGImagePropertyGPSLongitude as String: 121.47, kCGImagePropertyGPSLongitudeRef as String: "E"],
                kCGImageDestinationLossyCompressionQuality as String: 0.9,
            ]
            if withCamera {
                exifDict[kCGImagePropertyExifLensModel as String] = "FE 35mm F1.4 GM"
                exifDict[kCGImagePropertyExifFocalLength as String] = 35.0
                exifDict[kCGImagePropertyExifFNumber as String] = 1.4
                exifDict[kCGImagePropertyExifExposureTime as String] = 0.004
                exifDict[kCGImagePropertyExifISOSpeedRatings as String] = [100]
                props[kCGImagePropertyTIFFDictionary as String] = [
                    kCGImagePropertyTIFFMake as String: "SONY",
                    kCGImagePropertyTIFFModel as String: "ILCE-7M4",
                ]
            }
            props[kCGImagePropertyExifDictionary as String] = exifDict
            let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, props as CFDictionary)
            CGImageDestinationFinalize(d)
            return u
        }
        let src = make("big.jpg", 9600, 5400)
        let tall = make("tall.jpg", 3000, 4000)
        let noExif = dir.appendingPathComponent("noexif.png")
        do {
            let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            let d = CGImageDestinationCreateWithURL(noExif as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }
        let original = try? Data(contentsOf: src)

        func image(_ u: URL) -> CGImage? { CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
        func props(_ u: URL) -> [String: Any] { CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:] }
        func px(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
            var d = [UInt8](repeating: 0, count: 4)
            d.withUnsafeMutableBytes { b in
                let ctx = CGContext(data: b.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
            }
            return d.prefix(3).map(Int.init)
        }
        func isPhoto(_ p: [Int]) -> Bool { abs(p[0] - 51) < 14 && abs(p[1] - 128) < 14 && abs(p[2] - 204) < 14 }
        func isWhite(_ p: [Int]) -> Bool { p.allSatisfy { $0 > 245 } }
        func isBlack(_ p: [Int]) -> Bool { p.allSatisfy { $0 < 10 } }
        func spec(_ w: Int, _ h: Int, _ fill: BorderSpec.Fill = .white, pct: Double = 0, size: SaveSize.Choice = .original, pixels: Bool = false) -> BorderSpec {
            var s = BorderSpec(w: w, h: h, pixels: pixels, fill: fill)
            s.percent = pct
            s.size = size
            return s
        }
        var made: [URL] = []
        func save(_ u: URL, _ s: BorderSpec, _ tag: String) -> CGImage? {
            let out = Straighten.save(url: u, quarterTurns: 0, degrees: 0, crop: nil, overwrite: false, border: s)
            guard let f = out.url, let img = image(f) else { check(false, "\(tag): 没存出来"); return nil }
            made.append(f)
            let expectExt = CleanupUnit.isRaw(u) ? "jpg" : u.pathExtension
            check(f.lastPathComponent.hasPrefix(u.deletingPathExtension().lastPathComponent + L10n.t("border.suffix", "-边框")) && f.pathExtension == expectExt,
                  "\(tag): 文件名 \(f.lastPathComponent)")
            return img
        }

        // ---- 纯计算
        check(BorderSpec.parseCustom("4", "5")! == (4, 5) && BorderSpec.parseCustom("1920", "1080")! == (1920, 1080)
              && BorderSpec.parseCustom("1920", "10") == nil && BorderSpec.parseCustom("0", "5") == nil, "自定义：比例 / 像素 / 不合法")
        let l45 = spec(4, 5).layout(CGSize(width: 9600, height: 5400))
        check(l45.canvas == CGSize(width: 9600, height: 12000) && l45.photo == CGRect(x: 0, y: 3300, width: 9600, height: 5400), "4:5 原尺寸：画布 \(l45.canvas) 照片 \(l45.photo)")
        check(BorderSpec().percent == 5 && spec(4, 5).percent == 0 && BorderSpec().summary.hasSuffix("5%"), "默认：原比例 5%、固定比例 0%（\(BorderSpec().summary)）")

        // ---- 1. 4:5 白，长边 1440 → 1152×1440，照片 1152×648 居中
        if let img = save(src, spec(4, 5, size: .preset(1440)), "4:5") {
            check(img.width == 1152 && img.height == 1440, "4:5 长边 1440：\(img.width)×\(img.height)")
            check(isWhite(px(img, 576, 100)) && isWhite(px(img, 576, 388)) && isPhoto(px(img, 576, 404)) && isPhoto(px(img, 576, 720))
                  && isPhoto(px(img, 576, 1036)) && isWhite(px(img, 576, 1052)) && isWhite(px(img, 576, 1340)) && isPhoto(px(img, 2, 720)),
                  "4:5：上下白、照片 1152×648 在 y 396–1044（\(px(img, 576, 100)) \(px(img, 576, 720))）")
            let p = props(made.last!)
            let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let gps = p[kCGImagePropertyGPSDictionary as String] as? [String: Any]
            check(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == date, "保留拍摄日期 \(exif?[kCGImagePropertyExifDateTimeOriginal as String] ?? "nil")")
            check(abs((gps?[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - 31.23) < 0.01 && gps?[kCGImagePropertyGPSLongitudeRef as String] as? String == "E",
                  "保留 GPS \(gps ?? [:])")
        }
        // ---- 2. 原比例 5%，长边 2040：画布 2040×1200，四边都是 60
        if let img = save(src, spec(0, 0, pct: 5, size: .preset(2040)), "equal") {
            check(img.width == 2040 && img.height == 1200, "原比例 5%：\(img.width)×\(img.height)")
            let edges = [px(img, 50, 600), px(img, 1990, 600), px(img, 1020, 50), px(img, 1020, 1150)]
            let inside = [px(img, 70, 600), px(img, 1970, 600), px(img, 1020, 70), px(img, 1020, 1130)]
            check(edges.allSatisfy(isWhite) && inside.allSatisfy(isPhoto), "原比例：四边等宽 60（\(edges) | \(inside)）")
        }
        // ---- 3. 1:1 黑，长边 1080
        if let img = save(src, spec(1, 1, .black, size: .preset(1080)), "1:1") {
            check(img.width == 1080 && img.height == 1080 && isBlack(px(img, 540, 100)) && isBlack(px(img, 540, 1000)) && isPhoto(px(img, 540, 540)),
                  "1:1 黑：\(img.width)×\(img.height) 上 \(px(img, 540, 100)) 中 \(px(img, 540, 540))")
        }
        // ---- 4. 模糊背景：角上不是纯白、纯黑
        if let img = save(src, spec(4, 5, .blur, pct: 4, size: .preset(1440)), "blur") {
            let corners = [px(img, 5, 5), px(img, 1146, 1434)]
            check(corners.allSatisfy { !isWhite($0) && !isBlack($0) } && isPhoto(px(img, 576, 720)), "模糊背景：角上 \(corners)")
        }
        // ---- 5. 像素画布 1920×1080，5%：正好 1920×1080，两边留白
        if let img = save(src, spec(1920, 1080, pct: 5, size: .preset(1440), pixels: true), "pixels") {
            check(img.width == 1920 && img.height == 1080, "像素画布：\(img.width)×\(img.height)")
            check(isWhite(px(img, 40, 540)) && isWhite(px(img, 960, 20)) && isPhoto(px(img, 960, 540)) && isPhoto(px(img, 110, 540)), "像素画布：四周留白、照片在中间")
        }
        // ---- 6. 竖图放进 16:9：左右留白，上下贴边
        if let img = save(tall, spec(16, 9), "tall") {
            check(img.width == 7111 && img.height == 4000, "竖图 16:9：\(img.width)×\(img.height)")
            check(isWhite(px(img, 100, 2000)) && isWhite(px(img, 7000, 2000)) && isPhoto(px(img, 3555, 2)) && isPhoto(px(img, 3555, 3997)),
                  "竖图 16:9：左右白、上下没有边")
        }
        check((try? Data(contentsOf: src)) == original && original != nil, "原图一个字节都没变")

        // ---- 7. 导出 / 批量转换带边框（长边限制管整张画布）
        var o = ExportOptions()
        o.maxLongEdge = 1440
        o.border = spec(4, 5)
        if let full = ImageLoader.decodedFull(url: src), let out = ImageExporter.encode(full, source: src, uti: UTType.jpeg.identifier, quality: 90, options: o) {
            check(out.width == 1152 && out.height == 1440, "导出带边框：\(out.width)×\(out.height)")
        } else { check(false, "导出带边框失败") }
        let bdir = dir.appendingPathComponent("batch")
        let sum = BatchConvert.run([src], settings: .init(uti: UTType.jpeg.identifier, ext: "jpg", quality: 90, options: o, outDir: bdir))
        let bimg = sum.outputs.first.flatMap(image)
        check(sum.converted == 1 && bimg?.width == 1152 && bimg?.height == 1440, "批量转换带边框：\(bimg?.width ?? 0)×\(bimg?.height ?? 0)")
        // ---- 7b. EXIF 摄影参数相框：解析、旧版 JSON 兼容、白底深字、黑底浅字、无 EXIF 容错
        let parsedExif = BorderExif.read(url: src)
        check(parsedExif.camera == "SONY ILCE-7M4" && parsedExif.lens == "FE 35mm F1.4 GM"
              && parsedExif.shot == "35mm · ƒ/1.4 · 1/250s · ISO 100" && parsedExif.date == "2024-05-06",
              "EXIF 相框解析：\(parsedExif)")
        let legacyJSON = Data(#"{"w":4,"h":5,"pixels":false,"fill":0,"rgb":16777215,"equalPercent":5,"fitPercent":0,"edge":0,"customEdge":false}"#.utf8)
        let decodedLegacy = try? JSONDecoder().decode(BorderSpec.self, from: legacyJSON)
        check(decodedLegacy?.showExif == false && decodedLegacy?.w == 4 && decodedLegacy?.h == 5, "旧版 BorderSpec JSON 向后兼容")

        func countInk(_ img: CGImage, yRange: Range<Int>, expectDark: Bool) -> Int {
            var hits = 0
            for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: 2) {
                for x in stride(from: 20, to: img.width - 20, by: 4) {
                    let p = px(img, x, y)
                    if expectDark { if p[0] < 180 && p[1] < 180 && p[2] < 180 { hits += 1 } }
                    else { if p[0] > 80 && p[1] > 80 && p[2] > 80 { hits += 1 } }
                }
            }
            return hits
        }
        var exifWhite = BorderSpec(w: 0, h: 0, fill: .white, showExif: true); exifWhite.percent = 5; exifWhite.size = .preset(1600)
        if let img = save(src, exifWhite, "exif-white") {
            let g = exifWhite.geometry(CGSize(width: 9600, height: 5400))
            check(g.footer.height > g.photo.minY, "EXIF 白框底栏高于顶边")
            let ink = countInk(img, yRange: Int(Double(img.height) * 0.87)..<img.height, expectDark: true)
            check(ink > 30, "EXIF 白框底部有深色文字像素（hits=\(ink)）")
            if let f = made.last { try? fm.copyItem(at: f, to: URL(fileURLWithPath: "\(outDir)/exif-frame-white-\(lang).jpg")) }
        }
        var exifBlack = BorderSpec(w: 4, h: 5, fill: .black, showExif: true); exifBlack.percent = 3; exifBlack.size = .preset(1440)
        if let img = save(src, exifBlack, "exif-black") {
            let ink = countInk(img, yRange: Int(Double(img.height) * 0.89)..<img.height, expectDark: false)
            check(ink > 20, "EXIF 黑框底部有浅色反色文字像素（hits=\(ink)）")
            if let f = made.last { try? fm.copyItem(at: f, to: URL(fileURLWithPath: "\(outDir)/exif-frame-black-\(lang).jpg")) }
        }
        // 无 EXIF 图片：不崩溃且底栏纯净无杂字
        if let img = save(noExif, exifWhite, "exif-none") {
            let ink = countInk(img, yRange: Int(Double(img.height) * 0.88)..<img.height, expectDark: true)
            check(ink == 0, "无 EXIF 图片底栏无杂像素（hits=\(ink)）")
        }
        // 导出带 EXIF 相框
        var oExif = ExportOptions(); oExif.maxLongEdge = 1440; oExif.border = exifWhite
        if let full = ImageLoader.decodedFull(url: src),
           let out = ImageExporter.encode(full, source: src, uti: UTType.jpeg.identifier, quality: 90, options: oExif),
           let outImg = CGImageSourceCreateWithData(out.data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
            let ink = countInk(outImg, yRange: Int(Double(outImg.height) * 0.87)..<outImg.height, expectDark: true)
            check(ink > 20, "导出带 EXIF 相框文字正常渲染（hits=\(ink)）")
        } else { check(false, "导出带 EXIF 相框失败") }

        try? fm.removeItem(at: bdir)
        for f in made { try? fm.removeItem(at: f) }

        // ---- 8. 看图：开条、预览、截图、回车另存、Esc 收起
        let suiteName = "com.xmasdong.bordertest.\(ProcessInfo.processInfo.processIdentifier)"
        let suite = UserDefaults(suiteName: suiteName)!
        let savedDefaults = BorderSpec.defaults
        BorderSpec.defaults = suite
        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 820, width: 1180, height: 800), display: true)
        }
        open(url: src)
        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }
        }
        func key(_ code: UInt16, _ chars: String) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            imageView.keyDown(with: e)
        }
        func listing() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") } }
        var before = Set<String>()
        at(2.5) {
            self.addBorder(nil)
            check(self.border != nil && !self.rotationBar.isHidden, "开加边框：条出来了")
            self.border?.debugSet(spec(4, 5, size: .preset(1440)))
        }
        at(1.0) {
            guard let b = self.border else { return }
            let f = b.preview.debugFrames
            check(abs(f.canvas.width / f.canvas.height - 0.8) < 0.01 && abs(f.photo.width / f.photo.height - 16.0 / 9) < 0.02 && abs(f.photo.width - f.canvas.width) < 1,
                  "预览 4:5：画布 \(f.canvas.size) 照片 \(f.photo)")
            check(b.size.result.stringValue.contains("1152 × 1440"), "条上的尺寸：\(b.size.result.stringValue)")
            self.captureWindow(to: "\(outDir)/\(lang)-border-45-white.png", raw: true)
            b.debugSet(spec(4, 5, .blur, pct: 4, size: .preset(1440)))
        }
        at(1.0) {
            self.captureWindow(to: "\(outDir)/\(lang)-border-45-blur.png", raw: true)
            var ew = BorderSpec(w: 0, h: 0, fill: .white, showExif: true); ew.percent = 5; ew.size = .preset(1600)
            self.border?.debugSet(ew)
        }
        at(0.6) {
            check(self.border?.preview.debugCaptionVisible == true, "预览 EXIF 参数底栏可见")
            self.captureWindow(to: "\(outDir)/\(lang)-border-exif-white.png", raw: true)
            self.border?.debugSet(spec(4, 5, .blur, pct: 4, size: .preset(1440)))
        }
        at(0.6) {
            before = listing()
            key(36, "\r")
        }
        at(4.0) {
            let n = listing().subtracting(before)
            let img = n.first.flatMap { image(dir.appendingPathComponent($0)) }
            check(self.border == nil && n.count == 1 && img?.width == 1152 && img?.height == 1440, "回车另存：\(n) \(img?.width ?? 0)×\(img?.height ?? 0)")
            check(BorderSpec.saved.fill == .blur && BorderSpec.saved.size == .preset(1440), "记住了上次的设置 \(BorderSpec.saved.summary)")
            self.addBorder(nil)
            check(self.border?.spec.fill == .blur, "再开：沿用上次的设置")
            key(53, "\u{1b}")
            check(self.border == nil && self.rotationBar.isHidden, "Esc 收起")
        }
        at(0.5) {
            BorderSpec.defaults = savedDefaults
            suite.removePersistentDomain(forName: suiteName)
            print("BORDER summary [\(lang)] checks=\(checks) failures=\(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        runNext()
    }
}

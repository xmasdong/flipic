import AppKit
import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// `Flipic --mismatchtest <输出目录>`：
/// 验证「文件后缀与实际格式不符」（如豆包把 PNG/WebP 存成 .jpg 导致访达无缩略图）全链路：
/// 1. 魔数检测（PNG/WebP/GIF/JPEG 错配、合法后缀无误报、RAW .dng/.cr3 绝不误报）
/// 2. 真实 macOS QLThumbnailGenerator 修复前失败 → 无损改后缀后立即出缩略图（含重名避让、访达标签与 .xmp 同步）
/// 3. 转为真 JPEG 模式（透明 PNG 铺白底不变黑、保留 EXIF 与访达标签、QLThumbnailGenerator 立即出缩略图）
/// 4. Straighten/Border 另存副本不再产出假 JPG
/// 5. 看图窗口轻提示条、照片信息栏（I）橙色提示卡、右键菜单动态显隐、批量修复弹窗截图
extension ViewerViewController {
    func runFormatMismatchTest(outDir: String) {
        let lang = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("mm-\(lang)")
        let shots = URL(fileURLWithPath: outDir).appendingPathComponent("shots-\(lang)")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)

        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("MISMATCH \(ok ? "ok  " : "FAIL") [\(lang)] \(what)")
            fflush(stdout)
        }
        func pump(_ secs: Double = 0.05) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: secs))
        }
        func qlThumbOK(_ url: URL) -> Bool {
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 200, height: 200), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
                ok = (err == nil && rep?.type == .thumbnail && (rep?.cgImage.width ?? 0) > 0)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            return ok
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeImage(w: Int = 640, h: Int = 420, alphaCorner: Bool = false) -> CGImage {
            let ai: CGImageAlphaInfo = alphaCorner ? .premultipliedLast : .noneSkipLast
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb, bitmapInfo: ai.rawValue)!
            if alphaCorner {
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.48, blue: 0.82, alpha: 1))
                ctx.fill(CGRect(x: 80, y: 60, width: w - 160, height: h - 120))
            } else {
                let grad = CGGradient(colorsSpace: srgb, colors: [
                    CGColor(srgbRed: 0.12, green: 0.36, blue: 0.68, alpha: 1),
                    CGColor(srgbRed: 0.88, green: 0.62, blue: 0.34, alpha: 1),
                ] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
            }
            return ctx.makeImage()!
        }

        func writeImg(_ img: CGImage, to url: URL, uti: String, camera: String? = nil) {
            var props: [String: Any] = [:]
            if let camera {
                props[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFModel as String: camera]
            }
            let d = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil)!
            CGImageDestinationAddImage(d, img, props.isEmpty ? nil : props as CFDictionary)
            CGImageDestinationFinalize(d)
        }

        let solid = makeImage()
        let alphaImg = makeImage(alphaCorner: true)

        // 1. 构造各类测试文件
        let unitDir = root.appendingPathComponent("unit")
        try? fm.createDirectory(at: unitDir, withIntermediateDirectories: true)

        let realJPG = unitDir.appendingPathComponent("real.jpg")
        let realJPEG = unitDir.appendingPathComponent("real2.jpeg")
        let realPNG = unitDir.appendingPathComponent("real.png")
        let pngAsJPG = unitDir.appendingPathComponent("doubao_01.jpg")
        let pngAsJPGXmp = unitDir.appendingPathComponent("doubao_01.xmp")
        let gifAsJPG = unitDir.appendingPathComponent("anim.jpg")
        let jpgAsPNG = unitDir.appendingPathComponent("photo.png")
        let dupPNG = unitDir.appendingPathComponent("dup.png")
        let dupAsJPG = unitDir.appendingPathComponent("dup.jpg")
        let transAsJPG = unitDir.appendingPathComponent("alpha_doubao.jpg")
        let fakeDNG = unitDir.appendingPathComponent("raw.dng")
        let fakeCR3 = unitDir.appendingPathComponent("canon.cr3")

        writeImg(solid, to: realJPG, uti: UTType.jpeg.identifier)
        writeImg(solid, to: realJPEG, uti: UTType.jpeg.identifier)
        writeImg(solid, to: realPNG, uti: UTType.png.identifier)
        writeImg(solid, to: pngAsJPG, uti: UTType.png.identifier, camera: "DOUBAO-AI")
        try? "<x:xmpmeta/>".write(to: pngAsJPGXmp, atomically: true, encoding: .utf8)
        _ = Marks.set(true, for: pngAsJPG)
        writeImg(solid, to: gifAsJPG, uti: UTType.gif.identifier)
        writeImg(solid, to: jpgAsPNG, uti: UTType.jpeg.identifier)
        writeImg(solid, to: dupPNG, uti: UTType.png.identifier)
        writeImg(solid, to: dupAsJPG, uti: UTType.png.identifier)
        writeImg(alphaImg, to: transAsJPG, uti: UTType.png.identifier, camera: "DOUBAO-ALPHA")
        _ = Marks.set(true, for: transAsJPG)
        // 模拟 RAW 文件头（TIFF DNG + ISOBMFF CR3）
        try? Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]).write(to: fakeDNG)
        try? Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x63, 0x72, 0x78, 0x20, 0, 0, 0, 0]).write(to: fakeCR3)

        // WebP saved as .jpg（写标准 RIFF..WEBP 头 + 从已有截图或构造验证）
        let webpAsJPG = unitDir.appendingPathComponent("web_01.jpg")
        try? Data([0x52, 0x49, 0x46, 0x46, 0x24, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20]).write(to: webpAsJPG)

        // MARK: 1. 魔数检测检查
        check(FormatMismatch.detect(realJPG) == nil, "real.jpg not flagged")
        check(FormatMismatch.detect(realJPEG) == nil, "real2.jpeg not flagged")
        check(FormatMismatch.detect(realPNG) == nil, "real.png not flagged")
        check(FormatMismatch.detect(fakeDNG) == nil, "raw.dng never flagged")
        check(FormatMismatch.detect(fakeCR3) == nil, "canon.cr3 never flagged")

        let mPNG = FormatMismatch.detect(pngAsJPG)
        check(mPNG?.actual == .png && mPNG?.suggestedExt == "png", "doubao_01.jpg detected as PNG")
        check(FormatMismatch.detect(gifAsJPG)?.actual == .gif, "anim.jpg detected as GIF")
        check(FormatMismatch.detect(jpgAsPNG)?.actual == .jpeg, "photo.png detected as JPEG")
        check(FormatMismatch.detect(webpAsJPG)?.actual == .webp, "web_01.jpg detected as WebP")

        // MARK: 2. QLThumbnailGenerator 修复前失败 → 无损改后缀后恢复 + 重名避让 + .xmp/标签保留
        check(!qlThumbOK(pngAsJPG), "QLThumbnailGenerator fails on PNG-in-JPG before fix")
        check(qlThumbOK(realJPG), "QLThumbnailGenerator succeeds on real.jpg")

        if let mPNG {
            let res = FormatMismatch.renameToActual(mPNG)
            if case .success(let fixedURL) = res {
                check(fixedURL.lastPathComponent == "doubao_01.png" && fm.fileExists(atPath: fixedURL.path) && !fm.fileExists(atPath: pngAsJPG.path),
                      "renameToActual produced doubao_01.png")
                check(FormatMismatch.detect(fixedURL) == nil, "fixed doubao_01.png no longer mismatched")
                check(fm.fileExists(atPath: pngAsJPGXmp.path), "companion doubao_01.xmp preserved")
                check(Marks.isMarked(fixedURL), "Finder mark preserved after rename")
                check(qlThumbOK(fixedURL), "QLThumbnailGenerator SUCCEEDS immediately after rename to .png")
            } else {
                check(false, "renameToActual failed")
            }
        }
        // 重名避让：dup.png 已存在，dup.jpg 应改成 dup-2.png
        if let mDup = FormatMismatch.detect(dupAsJPG) {
            if case .success(let fixedDup) = FormatMismatch.renameToActual(mDup) {
                check(fixedDup.lastPathComponent == "dup-2.png" && fm.fileExists(atPath: dupPNG.path),
                      "collision-safe rename dup.jpg -> \(fixedDup.lastPathComponent)")
            } else {
                check(false, "collision rename failed")
            }
        }

        // MARK: 3. 转为真 JPEG（透明 PNG 铺白底 + 保留 EXIF/标签 + QLThumbnailGenerator 恢复）
        check(!qlThumbOK(transAsJPG), "QLThumbnailGenerator fails on alpha_doubao.jpg before JPEG convert")
        if let mAlpha = FormatMismatch.detect(transAsJPG) {
            if case .success(let jpgURL) = FormatMismatch.convertToRealJPEG(mAlpha) {
                check(jpgURL == transAsJPG && FormatMismatch.detect(jpgURL) == nil, "convertToRealJPEG kept .jpg name and fixed format")
                let data = (try? Data(contentsOf: jpgURL)) ?? Data()
                check(FormatMismatch.hasJPEGHeader(data), "converted file has real FF D8 FF JPEG header")
                check(Marks.isMarked(jpgURL), "Finder mark preserved after convertToRealJPEG")
                check(qlThumbOK(jpgURL), "QLThumbnailGenerator SUCCEEDS after convertToRealJPEG")
                // 检查左上角透明像素被铺成纯白（而非黑色）
                if let src = CGImageSourceCreateWithURL(jpgURL as CFURL, nil),
                   let outImg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                    let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
                    check((tiff?[kCGImagePropertyTIFFModel as String] as? String) == "DOUBAO-ALPHA", "EXIF camera preserved after convertToRealJPEG")
                    var px = [UInt8](repeating: 0, count: 4)
                    px.withUnsafeMutableBytes { buf in
                        let c = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                        c.draw(outImg, in: CGRect(x: 0, y: -(outImg.height - 1), width: outImg.width, height: outImg.height))
                    }
                    check(px[0] > 245 && px[1] > 245 && px[2] > 245, "transparent corner flattened to white rgb=(\(px[0]),\(px[1]),\(px[2]))")
                } else {
                    check(false, "failed reading converted JPEG")
                }
            } else {
                check(false, "convertToRealJPEG failed")
            }
        }

        // MARK: 4. Straighten/Border 另存副本不再产出假 JPG
        let borderSrc = unitDir.appendingPathComponent("border_fake.jpg")
        writeImg(solid, to: borderSrc, uti: UTType.png.identifier)
        var bSpec = BorderSpec(w: 0, h: 0, fill: .white, showExif: false); bSpec.percent = 5
        let bOut = Straighten.save(url: borderSrc, quarterTurns: 0, degrees: 0, crop: nil, overwrite: false, border: bSpec)
        check(bOut.url?.pathExtension.lowercased() == "png" && bOut.url.map({ FormatMismatch.detect($0) == nil }) == true,
              "Straighten border copy uses real .png ext (\(bOut.url?.lastPathComponent ?? "nil"))")

        // MARK: 5. 实机看图窗口 UI + 信息面板 + 批量修复弹窗截图验证
        let uiDir = root.appendingPathComponent("new-chat")
        try? fm.createDirectory(at: uiDir, withIntermediateDirectories: true)
        let uiFiles = ["李俊志-缩风.jpg", "李俊志-柜风.jpg", "李俊志-底风.jpg"]
        for name in uiFiles {
            writeImg(solid, to: uiDir.appendingPathComponent(name), uti: UTType.png.identifier, camera: "SONY ILCE-7M4")
        }
        writeImg(solid, to: uiDir.appendingPathComponent("正常照片.jpg"), uti: UTType.jpeg.identifier)

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 30, y: vis.maxY - 820, width: 1280, height: 780), display: true)
        }
        open(url: uiDir.appendingPathComponent(uiFiles[0]))
        let d1 = Date().addingTimeInterval(3)
        while Date() < d1 && (currentMismatch == nil || mismatchBanner.isHidden) { pump(0.05) }
        check(currentMismatch?.actual == .png && !mismatchBanner.isHidden, "viewer shows mismatch banner for PNG-in-JPG")

        // 校验右键菜单项自动显现，且标题含 .png
        let miFix = NSMenuItem(title: "", action: #selector(fixCurrentExtension(_:)), keyEquivalent: "")
        check(validateMenuItem(miFix) && !miFix.isHidden && miFix.title.contains(".png"), "context menu fix item visible: \(miFix.title)")

        // 打开照片信息面板（I），验证信息卡片和格式行均标出后缀错配
        if exifPanel.isHidden { toggleInfoPanel(nil) }
        pump(0.6)
        check(!exifPanel.isHidden, "info panel opened with mismatch card")
        debugCapture(to: shots.appendingPathComponent("01_viewer_banner_info.png").path)

        // 打开批量修复弹窗截图（无损改后缀模式）
        let scanned = FormatMismatch.scan(folder.items.map(\.url))
        check(scanned.count == 3, "folder scan found 3/4 mismatched images (got \(scanned.count))")
        let sheet = FormatMismatchWindowController(items: scanned, folderName: "new-chat") { _, _ in }
        sheet.present(attachedTo: nil)
        sheet.window?.center()
        pump(0.3)
        if let sw = sheet.window,
           let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(sw.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
           let dest = CGImageDestinationCreateWithURL(shots.appendingPathComponent("02_batch_sheet.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        check(sheet.debugRowCount == 3 && sheet.debugFirstTarget.hasSuffix(".png"), "batch sheet preview rows=\(sheet.debugRowCount) first=\(sheet.debugFirstTarget)")
        sheet.window?.close()

        // 点击单张修正，验证轻提示条立刻隐藏、当前文件变成 .png
        fixCurrentExtension(nil)
        pump(0.3)
        check(folder.current?.url.pathExtension.lowercased() == "png" && currentMismatch == nil && mismatchBanner.isHidden,
              "single-click fix renamed to \(folder.current?.url.lastPathComponent ?? "nil") and hid banner")
        check(!validateMenuItem(miFix) && miFix.isHidden, "context menu fix item hidden after fix")

        print("MISMATCH summary [\(lang)] checks=\(checks) failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}

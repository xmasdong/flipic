import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --inspecttest <工作文件夹>`：
/// 验证 Phase 2 免费摄影质检与效率功能：
/// 1. PhotoHistogram（纯白/纯黑/中灰/复杂画面 S/H 占比）
/// 2. InspectMask（过曝红斑马、死黑蓝斑马、焦点峰值青绿锐度遮罩、无误触发）
/// 3. AFPointReader（EXIF SubjectArea 2/3/4 参、EXIF Orientation=6、XMP mwg-rs:Regions、Sony 0x2027、Fujifilm 0x1023、90° 旋转四次归位）
/// 4. BatchRenameEngine & BatchRenameAccessory（纯前缀兼容、EXIF 变量模板、缺 EXIF 兜底、关联 .xmp 同步重命名、重名避让、预设预览）
/// 5. 外接硬盘极速打开（FolderModel prefetched stat 不丢大小/时间、跳过 ._*、EmbeddedPreview 4MB 前缀快扫 & >4MB 回退扫描）
/// 6. 实机看图窗口 UI（H/J/K/A 开关、旋转对齐、菜单勾选态、截图输出）。最后一行 INSPECT summary
extension ViewerViewController {
    func runInspectTest(outDir: String) {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("inspect-\(lang)")
        let shots = URL(fileURLWithPath: outDir).appendingPathComponent("shots-\(lang)")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)

        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("INSPECT \(ok ? "ok  " : "FAIL") [\(lang)] \(what)")
            fflush(stdout)
        }
        func pump(_ secs: Double = 0.05) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: secs))
        }
        func waitInspect() {
            inspect.queue.sync {}
            pump(0.12)
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeSolid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, w: Int = 200, h: Int = 200) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()!
        }

        func pixelRGBA(_ img: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let w = img.width, h = img.height
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
            let p = (min(max(0, y), h - 1) * w + min(max(0, x), w - 1)) * 4
            return (ptr[p], ptr[p + 1], ptr[p + 2], ptr[p + 3])
        }

        /// 生成一张视觉丰富的摄影测试场景：左上天空过曝高光、左下深暗影、右上锐利人像/建筑标靶（对焦区）、右下柔焦平滑散景
        func makeRichScene(w: Int = 1200, h: Int = 800) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            // 蓝紫渐层底（散景背景）
            let grad = CGGradient(colorsSpace: srgb, colors: [
                CGColor(srgbRed: 0.14, green: 0.22, blue: 0.34, alpha: 1),
                CGColor(srgbRed: 0.38, green: 0.44, blue: 0.52, alpha: 1),
                CGColor(srgbRed: 0.72, green: 0.62, blue: 0.50, alpha: 1),
            ] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat(w), y: CGFloat(h)), options: [])

            // 顶部左侧过曝云/太阳区（CGContext y=0 在底部，所以顶部是 y = h * 0.72...）
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 40, y: CGFloat(h) - 180, width: 300, height: 140))

            // 底部左侧死黑暗部区（y = 40...180）
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 40, y: 40, width: 260, height: 140))

            // 右上锐利细节目标区（画面坐标 y ≈ 0.30 从上往下，即 CGContext y ≈ h * 0.70）
            let sx = 680, sy = 440, sw = 320, sh = 240
            ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.88, blue: 0.82, alpha: 1))
            ctx.fill(CGRect(x: sx, y: sy, width: sw, height: sh))
            ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.15, blue: 0.20, alpha: 1))
            let step = 16
            for row in 0..<(sh / step) {
                for col in 0..<(sw / step) where (row + col) % 2 == 0 {
                    ctx.fill(CGRect(x: sx + col * step, y: sy + row * step, width: step, height: step))
                }
            }
            // 同心圆锐利标靶（对焦主体中心）
            ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.22, blue: 0.18, alpha: 1))
            ctx.setLineWidth(4)
            for rad in stride(from: 20, through: 90, by: 20) {
                ctx.strokeEllipse(in: CGRect(x: sx + sw / 2 - rad, y: sy + sh / 2 - rad, width: rad * 2, height: rad * 2))
            }
            return ctx.makeImage()!
        }

        // MARK: 1. PhotoHistogram
        let hWhite = PhotoHistogram.compute(makeSolid(1, 1, 1))
        check(hWhite != nil && hWhite!.highlightPercent > 99 && hWhite!.shadowPercent < 0.1,
              "histogram white H=\(hWhite?.highlightPercent ?? -1) S=\(hWhite?.shadowPercent ?? -1)")
        let hBlack = PhotoHistogram.compute(makeSolid(0, 0, 0))
        check(hBlack != nil && hBlack!.shadowPercent > 99 && hBlack!.highlightPercent < 0.1,
              "histogram black S=\(hBlack?.shadowPercent ?? -1) H=\(hBlack?.highlightPercent ?? -1)")
        let hMid = PhotoHistogram.compute(makeSolid(0.5, 0.5, 0.5))
        check(hMid != nil && hMid!.shadowPercent < 0.1 && hMid!.highlightPercent < 0.1,
              "histogram mid-gray no clipping")

        // MARK: 2. InspectMask (Clipping & Focus Peaking)
        let scene = makeRichScene()
        let hScene = PhotoHistogram.compute(scene)
        check(hScene != nil && hScene!.highlightPercent > 2 && hScene!.shadowPercent > 2,
              "histogram scene has highlights(\(String(format: "%.1f", hScene?.highlightPercent ?? 0))%) & shadows(\(String(format: "%.1f", hScene?.shadowPercent ?? 0))%)")

        let clipMask = InspectMask.render(scene, clipping: true, peaking: false)
        check(clipMask != nil, "clipping mask rendered")
        if let m = clipMask {
            // 左上过曝区 -> 红色不透明
            let hiPx = pixelRGBA(m, x: m.width / 8, y: m.height / 10)
            check(hiPx.3 >= 100 && hiPx.0 > hiPx.2, "clipping highlight pixel is red rgba=\(hiPx)")
            // 左下死黑区 -> 蓝色不透明
            let shPx = pixelRGBA(m, x: m.width / 8, y: m.height - m.height / 10)
            check(shPx.3 >= 100 && shPx.2 > hiPx.2 && shPx.2 > shPx.0, "clipping shadow pixel is blue rgba=\(shPx)")
            // 右下平滑散景 -> 完全透明
            let okPx = pixelRGBA(m, x: m.width * 3 / 4, y: m.height - m.height / 8)
            check(okPx.3 == 0, "clipping normal area transparent rgba=\(okPx)")
        }

        let peakMask = InspectMask.render(scene, clipping: false, peaking: true)
        check(peakMask != nil, "focus peaking mask rendered")
        if let m = peakMask {
            // 右上锐利棋盘区统计亮起的青绿像素，右下平滑渐变区应为 0
            let w = m.width, h = m.height
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(m, in: CGRect(x: 0, y: 0, width: w, height: h))
            let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
            var sharpLit = 0, smoothLit = 0
            for y in (h / 10)..<(h * 45 / 100) {
                for x in (w * 58 / 100)..<(w * 82 / 100) {
                    let p = (y * w + x) * 4
                    if ptr[p + 3] > 100 && ptr[p + 1] > ptr[p] { sharpLit += 1 }
                }
            }
            for y in (h * 72 / 100)..<(h * 92 / 100) {
                for x in (w * 58 / 100)..<(w * 88 / 100) {
                    let p = (y * w + x) * 4
                    if ptr[p + 3] > 0 { smoothLit += 1 }
                }
            }
            check(sharpLit > 400 && smoothLit == 0, "peaking lights sharp target (\(sharpLit) px) and ignores smooth bokeh (\(smoothLit) px)")
        }

        // MARK: 3. AFPointReader (EXIF SubjectArea, Orientation=6, XMP MWG-RS, Sony 0x2027, Fujifilm 0x1023)
        let photosDir = root.appendingPathComponent("viewer")
        try? fm.createDirectory(at: photosDir, withIntermediateDirectories: true)

        func writeJPEG(_ url: URL, img: CGImage, props: [String: Any], xmp: String? = nil) {
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            if let xmp, let data = xmp.data(using: .utf8),
               let meta = CGImageMetadataCreateFromXMPData(data as CFData) {
                CGImageDestinationAddImageAndMetadata(dest, img, meta, props as CFDictionary)
            } else {
                CGImageDestinationAddImage(dest, img, props as CFDictionary)
            }
            CGImageDestinationFinalize(dest)
        }

        // 3a. EXIF SubjectArea (4-element rect centered on sharp target: x=840, y=240 in top-left 1200x800)
        let sceneURL = photosDir.appendingPathComponent("01_scene_af.jpg")
        writeJPEG(sceneURL, img: scene, props: [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "SONY",
                kCGImagePropertyTIFFModel as String: "ILCE-7M4",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:22 14:35:08",
                kCGImagePropertyExifFocalLength as String: 35.0,
                kCGImagePropertyExifSubjectArea as String: [840, 240, 220, 180],
            ],
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
        ])
        let afExif = AFPointReader.read(url: sceneURL)
        check(afExif.count == 1 && abs(afExif[0].midX - 0.70) < 0.01 && abs(afExif[0].midY - 0.30) < 0.01,
              "AF EXIF SubjectArea parsed \(afExif)")

        // 3b. EXIF Orientation = 6 (90° CW): raw (cx=0.3, cy=0.2) -> rotated CW -> (cx=0.8, cy=0.3)
        let orientURL = root.appendingPathComponent("af_orient6.jpg")
        writeJPEG(orientURL, img: makeSolid(0.4, 0.5, 0.6, w: 1000, h: 1000), props: [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifSubjectArea as String: [300, 200, 100, 100],
            ],
        ])
        let afOri = AFPointReader.read(url: orientURL)
        check(afOri.count == 1 && abs(afOri[0].midX - 0.80) < 0.01 && abs(afOri[0].midY - 0.30) < 0.01,
              "AF EXIF orientation=6 rotated \(afOri)")

        // 3c. XMP MWG-RS Region (Focus)
        let xmpAFURL = root.appendingPathComponent("af_xmp.jpg")
        let xmpFocus = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
            xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#">
           <mwg-rs:Regions rdf:parseType="Resource">
            <mwg-rs:RegionList>
             <rdf:Bag>
              <rdf:li rdf:parseType="Resource">
               <mwg-rs:Type>Focus</mwg-rs:Type>
               <mwg-rs:Area stArea:x="0.25" stArea:y="0.65" stArea:w="0.08" stArea:h="0.08" stArea:unit="normalized"/>
              </rdf:li>
             </rdf:Bag>
            </mwg-rs:RegionList>
           </mwg-rs:Regions>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        writeJPEG(xmpAFURL, img: makeSolid(0.3, 0.3, 0.3, w: 400, h: 300), props: [:], xmp: xmpFocus)
        let afXmp = AFPointReader.read(url: xmpAFURL)
        check(afXmp.count == 1 && abs(afXmp[0].midX - 0.25) < 0.01 && abs(afXmp[0].midY - 0.65) < 0.01,
              "AF XMP mwg-rs:Regions parsed \(afXmp)")

        // 3d. Synthetic TIFF with Sony MakerNote 0x2027 (FocusLocation) & Fujifilm MakerNote 0x1023 (FocusPixel)
        func writeLE16(_ buf: inout [UInt8], _ v: Int) { buf.append(UInt8(v & 0xFF)); buf.append(UInt8((v >> 8) & 0xFF)) }
        func writeLE32(_ buf: inout [UInt8], _ v: Int) {
            buf.append(UInt8(v & 0xFF)); buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8((v >> 16) & 0xFF)); buf.append(UInt8((v >> 24) & 0xFF))
        }
        func makeSyntheticMakerNoteTIFF(isFuji: Bool) -> Data {
            // Minimal valid 1x1 RGB TIFF with IFD0 -> ExifIFD (0x8769) -> MakerNote (0x927C)
            var b: [UInt8] = [0x49, 0x49, 0x2A, 0x00]   // II 42
            writeLE32(&b, 8)   // IFD0 at 8
            // IFD0: 7 entries (Width=1000, Height=800, BPS, Compression, Photometric, StripOffsets, ExifIFD)
            // Keep pixel data valid 2x2 RGB = 12 bytes at offset 400 so ImageIO parses pixelWidth/Height cleanly
            let ifd0Count = 8
            let exifIFDOff = 8 + 2 + ifd0Count * 12 + 4   // 110
            let mnOff = 160
            let stripOff = 360
            writeLE16(&b, ifd0Count)
            func entry(_ tag: Int, _ type: Int, _ count: Int, _ val: Int) {
                writeLE16(&b, tag); writeLE16(&b, type); writeLE32(&b, count); writeLE32(&b, val)
            }
            entry(0x0100, 4, 1, 1000)      // ImageWidth
            entry(0x0101, 4, 1, 800)       // ImageLength
            entry(0x0102, 3, 1, 8)         // BitsPerSample
            entry(0x0103, 3, 1, 1)         // Compression = none
            entry(0x0106, 3, 1, 1)         // Photometric = BlackIsZero
            entry(0x0111, 4, 1, stripOff)  // StripOffsets
            entry(0x0117, 4, 1, 16)        // StripByteCounts
            entry(0x8769, 4, 1, exifIFDOff) // ExifIFD
            writeLE32(&b, 0)
            while b.count < exifIFDOff { b.append(0) }
            // ExifIFD: 1 entry -> MakerNote 0x927C at mnOff
            writeLE16(&b, 1)
            entry(0x927C, 7, 128, mnOff)
            writeLE32(&b, 0)
            while b.count < mnOff { b.append(0) }
            if isFuji {
                // "FUJIFILM" + offset 12 (relative to mnOff) -> IFD with 0x1023 (fx=400, fy=600)
                b += Array("FUJIFILM".utf8)
                writeLE32(&b, 12)
                writeLE16(&b, 1)
                writeLE16(&b, 0x1023); writeLE16(&b, 3); writeLE32(&b, 2)
                writeLE16(&b, 400); writeLE16(&b, 600)
                writeLE32(&b, 0)
            } else {
                // "SONY DSC \0\0\0" + IFD with 0x2027 pointing to [6000, 4000, 2100, 1600] (0.35, 0.40)
                b += Array("SONY DSC \0\0\0".utf8)
                let valOff = mnOff + 12 + 2 + 12 + 4
                writeLE16(&b, 1)
                entry(0x2027, 3, 4, valOff)
                writeLE32(&b, 0)
                writeLE16(&b, 6000); writeLE16(&b, 4000); writeLE16(&b, 2100); writeLE16(&b, 1600)
            }
            while b.count < stripOff + 16 { b.append(0x80) }
            return Data(b)
        }

        let sonyURL = root.appendingPathComponent("af_sony.tif")
        try? makeSyntheticMakerNoteTIFF(isFuji: false).write(to: sonyURL)
        let afSony = AFPointReader.read(url: sonyURL)
        check(afSony.count == 1 && abs(afSony[0].midX - 0.35) < 0.01 && abs(afSony[0].midY - 0.40) < 0.01,
              "AF Sony MakerNote 0x2027 parsed \(afSony)")

        let fujiURL = root.appendingPathComponent("af_fuji.tif")
        try? makeSyntheticMakerNoteTIFF(isFuji: true).write(to: fujiURL)
        let afFuji = AFPointReader.read(url: fujiURL)
        check(afFuji.count == 1 && abs(afFuji[0].midX - 0.40) < 0.01 && abs(afFuji[0].midY - 0.75) < 0.01,
              "AF Fujifilm MakerNote 0x1023 parsed \(afFuji)")

        // 3e. Plain photo with no AF -> empty
        let plainURL = photosDir.appendingPathComponent("02_no_af.png")
        let pDest = CGImageDestinationCreateWithURL(plainURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(pDest, makeSolid(0.25, 0.45, 0.65, w: 600, h: 400), nil)
        CGImageDestinationFinalize(pDest)
        check(AFPointReader.read(url: plainURL).isEmpty, "AF empty for plain PNG")

        // 3f. AFPointReader.rotated 4×90° round-trip
        let origBox = CGRect(x: 0.15, y: 0.25, width: 0.12, height: 0.08)
        var rotBox = origBox
        for _ in 0..<4 { rotBox = AFPointReader.rotated(rotBox, quarterTurns: 1) }
        check(abs(rotBox.minX - origBox.minX) < 1e-6 && abs(rotBox.minY - origBox.minY) < 1e-6
              && abs(rotBox.width - origBox.width) < 1e-6 && abs(rotBox.height - origBox.height) < 1e-6,
              "AF rotated 4x90° round-trip exact")

        // MARK: 4. BatchRenameEngine & BatchRenameAccessory
        let brDir = root.appendingPathComponent("batchrename")
        try? fm.createDirectory(at: brDir, withIntermediateDirectories: true)
        let br1 = brDir.appendingPathComponent("DSC001.jpg")
        let br2 = brDir.appendingPathComponent("Screenshot.png")
        try? fm.copyItem(at: sceneURL, to: br1)
        try? fm.copyItem(at: plainURL, to: br2)
        // 给 br1 配一个 .xmp 附属文件，验证重命名同步跟走
        let br1Xmp = brDir.appendingPathComponent("DSC001.xmp")
        try? "<x:xmpmeta/>".write(to: br1Xmp, atomically: true, encoding: .utf8)

        let plainCompat = BatchRenameEngine.expand(template: "Tokyo", url: br1, seq: 1)
        check(plainCompat == "Tokyo-001", "batchRename plain prefix compat -> '\(plainCompat)'")

        let exifExpand = BatchRenameEngine.expand(template: "{date}_{time}_{camera}_{focal}_{seq}", url: br1, seq: 7)
        check(exifExpand == "20261122_143508_ILCE-7M4_35mm_007", "batchRename EXIF template -> '\(exifExpand)'")

        let missingExifExpand = BatchRenameEngine.expand(template: "{camera}_{focal}_{name}_{seq4}", url: br2, seq: 12)
        check(missingExifExpand == "Screenshot_0012", "batchRename missing EXIF collapses cleanly -> '\(missingExifExpand)'")

        // BatchRenameAccessory UI & preset switching + screenshot
        let sampleItems = [
            ImageItem(url: br1, modified: Date(), fileSize: 100),
            ImageItem(url: br2, modified: Date(), fileSize: 100),
        ]
        let acc = BatchRenameAccessory(items: sampleItems, folderName: "Trip")
        acc.presetPopup.selectItem(at: 2)   // {date}_{time}_{camera}_{seq}
        acc.presetPopup.sendAction(acc.presetPopup.action, to: acc.presetPopup.target)
        check(acc.templateText == "{date}_{time}_{camera}_{seq}", "BatchRenameAccessory preset switch -> '\(acc.templateText)'")
        let hostWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 442, height: 196),
                               styleMask: [.titled], backing: .buffered, defer: false)
        hostWin.title = L10n.t("br.title", "批量重命名")
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 442, height: 196))
        wrap.wantsLayer = true
        wrap.appearance = NSAppearance(named: .darkAqua)
        wrap.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        acc.frame = NSRect(x: 16, y: 16, width: 410, height: 164)
        wrap.addSubview(acc)
        hostWin.appearance = NSAppearance(named: .darkAqua)
        hostWin.contentView = wrap
        wrap.layoutSubtreeIfNeeded()
        if let rep = wrap.bitmapImageRepForCachingDisplay(in: wrap.bounds) {
            wrap.cacheDisplay(in: wrap.bounds, to: rep)
            if let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
                try? png.write(to: shots.appendingPathComponent("batch_rename_ui.png"))
            }
        }

        // Execute rename with EXIF template and verify .xmp sidecar moved too
        let brRes = BatchRenameEngine.execute(items: sampleItems, template: "{date}_{camera}_{seq}", startSeq: 5)
        let br1Expected = brDir.appendingPathComponent("20261122_ILCE-7M4_005.jpg")
        let br1XmpExpected = brDir.appendingPathComponent("20261122_ILCE-7M4_005.xmp")
        check(brRes.renamed == 2 && fm.fileExists(atPath: br1Expected.path) && fm.fileExists(atPath: br1XmpExpected.path),
              "BatchRenameEngine.execute renamed 2 files + companion .xmp (renamed=\(brRes.renamed))")

        // MARK: 5. External Drive Fast-Open (Prefetched FolderModel + EmbeddedPreview 4MB fast scan & fallback)
        let extDir = root.appendingPathComponent("extdrive")
        try? fm.createDirectory(at: extDir, withIntermediateDirectories: true)
        for i in 1...12 {
            let u = extDir.appendingPathComponent(String(format: "IMG_%03d.jpg", i))
            try? fm.copyItem(at: sceneURL, to: u)
        }
        // AppleDouble ._ 隐藏文件与 .xmp 不应进入图片列表
        try? Data([0, 5, 22, 7]).write(to: extDir.appendingPathComponent("._IMG_001.jpg"))
        try? "<x:xmpmeta/>".write(to: extDir.appendingPathComponent("IMG_001.xmp"), atomically: true, encoding: .utf8)
        let fmModel = FolderModel()
        let opened = fmModel.open(url: extDir)
        check(opened && fmModel.count == 12 && fmModel.items.allSatisfy { $0.fileSize > 0 },
              "FolderModel prefetched stat count=\(fmModel.count) allSize>0=\(fmModel.items.allSatisfy { $0.fileSize > 0 })")

        // 5b. EmbeddedPreview 4MB fast prefix path (synthetic 6 MB RAW: TIFF header + embedded JPEG at 64KB + 6MB zeros)
        let jpegBytes = (try? Data(contentsOf: sceneURL)) ?? Data()
        let rawFast = root.appendingPathComponent("fast_preview.dng")
        var fastBuf = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        fastBuf.append(Data(count: 64 * 1024))
        fastBuf.append(jpegBytes)
        fastBuf.append(Data(count: 6 * 1024 * 1024))
        try? fastBuf.write(to: rawFast)
        let fastImg = EmbeddedPreview.image(rawFast, maxPixel: 600)
        check(fastImg != nil && max(fastImg!.width, fastImg!.height) <= 600,
              "EmbeddedPreview 4MB prefix fast-path found & decoded \(fastImg.map { "\($0.width)x\($0.height)" } ?? "nil")")

        // 5c. EmbeddedPreview fallback (>4MB offset)
        let rawLate = root.appendingPathComponent("late_preview.dng")
        var lateBuf = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        lateBuf.append(Data(count: 4_500_000))
        lateBuf.append(jpegBytes)
        try? lateBuf.write(to: rawLate)
        let lateImg = EmbeddedPreview.image(rawLate, maxPixel: 600)
        check(lateImg != nil,
              "EmbeddedPreview >4MB fallback scan & decode ok \(lateImg.map { "\($0.width)x\($0.height)" } ?? "nil")")

        // MARK: 6. Live Viewer UI + Screenshots (H, J, K, A + rotation + menu validation)
        open(url: sceneURL)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !debugShownSharp { pump(0.05) }
        check(debugShownSharp, "viewer loaded scene sharp")

        // 6a. Histogram (H) + Clipping (J)
        perform(.histogram)
        perform(.clipping)
        waitInspect()
        check(inspect.showHistogram && !inspect.histogramView.isHidden && inspect.histogramView.histogram != nil,
              "viewer histogram shown stats=\(inspect.histogramView.debugStats)")
        check(inspect.showClipping && imageView.debugInspectHasMask, "viewer clipping mask active")
        debugCapture(to: shots.appendingPathComponent("inspect_hist_clip.png").path)

        // 6b. Switch to Focus Peaking (K) + AF Point (A)
        perform(.clipping)
        perform(.focusPeaking)
        perform(.afPoint)
        waitInspect()
        check(!inspect.showClipping && inspect.showPeaking && imageView.debugInspectHasMask, "viewer focus peaking active")
        check(inspect.showAF && imageView.debugAFVisible, "viewer AF reticle visible")
        let afRect = imageView.debugAFBounds
        let imgF = imageView.debugImageFrame
        check(afRect.midX > imgF.width * 0.55 && afRect.midY < imgF.height * 0.45,
              "viewer AF reticle centered on top-right target (mid=\(Int(afRect.midX)),\(Int(afRect.midY)) in \(Int(imgF.width))x\(Int(imgF.height)))")
        debugCapture(to: shots.appendingPathComponent("inspect_peak_af.png").path)

        // 6c. All 4 active + 90° rotation keeps inspect layers synced
        perform(.clipping)
        waitInspect()
        debugCapture(to: shots.appendingPathComponent("inspect_all.png").path)
        imageView.rotate(clockwise: 1)
        waitInspect()
        check(imageView.debugInspectHasMask && imageView.debugAFVisible, "overlays stay synced after 90° rotate")
        imageView.rotate(clockwise: -1)
        waitInspect()

        // 6d. Menu validation reflects .on states
        let miHist = NSMenuItem(title: "", action: #selector(toggleHistogram(_:)), keyEquivalent: "")
        let miClip = NSMenuItem(title: "", action: #selector(toggleClipping(_:)), keyEquivalent: "")
        let miPeak = NSMenuItem(title: "", action: #selector(toggleFocusPeaking(_:)), keyEquivalent: "")
        let miAF = NSMenuItem(title: "", action: #selector(toggleAFPoint(_:)), keyEquivalent: "")
        check(validateMenuItem(miHist) && miHist.state == .on
              && validateMenuItem(miClip) && miClip.state == .on
              && validateMenuItem(miPeak) && miPeak.state == .on
              && validateMenuItem(miAF) && miAF.state == .on,
              "menu validation reports .on for all 4 inspect toggles")

        // 6e. Navigate to plain PNG without AF -> AF box clears cleanly
        navigate(1)
        let d2 = Date().addingTimeInterval(2)
        while Date() < d2 && folder.current?.url.lastPathComponent != "02_no_af.png" { pump(0.05) }
        waitInspect()
        check(!imageView.debugAFVisible, "plain PNG clears AF reticle")

        // Clean turn-off
        perform(.histogram); perform(.clipping); perform(.focusPeaking); perform(.afPoint)
        waitInspect()
        check(inspect.histogramView.isHidden && !imageView.debugInspectHasMask && !imageView.debugAFVisible,
              "all 4 inspect overlays cleanly turned off")

        print("INSPECT summary [\(lang)] checks=\(checks) failures=\(failures)")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}

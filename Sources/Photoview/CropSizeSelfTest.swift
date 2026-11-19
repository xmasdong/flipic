import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --cropsizetest <工作文件夹>`：保存修改时选尺寸。生成一张 6000×4000、带拍摄日期的 JPEG，裁成 3:4，
/// 在保存对话框里选长边 1440 / 自定义 2000 / 原尺寸 / 比裁出来大的尺寸，另存后用 ImageIO 查像素尺寸和拍摄日期，原图不动；
/// 选了缩小的尺寸时「覆盖原图」点不了；记住了「另存一份」不弹框时按原尺寸；最后覆盖原图仍是全分辨率。
/// 尺寸、记住的比例放临时偏好设置。截图：保存对话框（带界面语言）。最后一行 CROPSIZE summary
extension ViewerViewController {
    func runCropSizeTest(outDir: String) {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: outDir).appendingPathComponent("photos-\(lang)")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("big.jpg")
        let date = "2024:05:06 07:08:09"

        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("CROPSIZE \(ok ? "ok  " : "FAIL") [\(lang)] \(what)")
            fflush(stdout)
        }

        // 6000×4000，几块颜色，EXIF 拍摄日期
        do {
            let w = 6000, h = 4000
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            for i in 0..<6 {
                ctx.setFillColor(CGColor(srgbRed: CGFloat(i) / 6, green: 0.4, blue: 1 - CGFloat(i) / 6, alpha: 1))
                ctx.fill(CGRect(x: i * 1000, y: 0, width: 1000, height: h))
            }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 2900, y: 1900, width: 200, height: 200))
            let props: [String: Any] = [
                kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: date],
                kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFDateTime as String: date],
                kCGImageDestinationLossyCompressionQuality as String: 0.9,
            ]
            let d = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, props as CFDictionary)
            CGImageDestinationFinalize(d)
        }

        func fileSize(_ url: URL) -> CGSize {
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] else { return .zero }
            return CGSize(width: p[kCGImagePropertyPixelWidth as String] as? Int ?? 0, height: p[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        }
        func exifDate(_ url: URL) -> String? {
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] else { return nil }
            return (p[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifDateTimeOriginal as String] as? String
        }
        func listing() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") } }
        let originalData = try? Data(contentsOf: src)
        func untouched() -> Bool { (try? Data(contentsOf: src)) == originalData && originalData != nil }

        // ---- 0. 纯计算
        let native = CGSize(width: 3000, height: 4000)
        check(SaveSize.output(native: native, choice: .preset(1440)) == CGSize(width: 1080, height: 1440), "3000×4000 长边 1440 → 1080×1440")
        check(SaveSize.output(native: native, choice: .custom(2000)) == CGSize(width: 1500, height: 2000), "自定义 2000 → 1500×2000")
        check(SaveSize.output(native: native, choice: .original) == native && SaveSize.shrinkEdge(native: native, choice: .original) == nil, "原尺寸不变")
        check(SaveSize.output(native: native, choice: .preset(4096)) == native && SaveSize.shrinkEdge(native: native, choice: .preset(4096)) == nil, "长边 4096 比 4000 大：不放大")
        check(SaveSize.shrinkEdge(native: native, choice: .preset(4000)) == nil, "长边正好等于：不算缩小")
        check(SaveSize.output(native: CGSize(width: 6000, height: 4000), choice: .preset(1080)) == CGSize(width: 1080, height: 720), "横图 6000×4000 长边 1080 → 1080×720")

        let suiteName = "com.xmasdong.cropsizetest.\(ProcessInfo.processInfo.processIdentifier)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let savedSizeDefaults = SaveSize.defaults, savedMemory = CropMemory.defaults
        SaveSize.defaults = suite
        CropMemory.defaults = suite
        let savedTarget = Straighten.saveTarget, savedRemind = Straighten.remindUnsaved
        Straighten.saveTarget = .ask
        Straighten.remindUnsaved = false
        check(SaveSize.last == .original, "没选过时默认原尺寸")
        do {
            let row = SaveSizeRow(native: native, initial: .custom(2000))
            row.debugType("10")
            check(row.customValue == 64 && row.outputSize == CGSize(width: 48, height: 64), "自定义小于 64 按 64（\(SaveSize.text(row.outputSize))）")
            row.debugType("abc")
            check(row.customValue == SaveSize.customEdge, "自定义不是数字：用上次的 \(row.customValue)")
        }

        // ---- 步骤
        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        func idle(_ f: @escaping () -> Void) { steps.append((-1, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            if dt >= 0 { DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }; return }
            var waited = 0.0
            func poll() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    waited += 0.25
                    if (self.isProcessing || waited < 0.5), waited < 60 { poll(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { f(); runNext() }
                }
            }
            poll()
        }
        func key(_ code: UInt16, _ chars: String) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            imageView.keyDown(with: e)
        }
        func shotSheet(_ name: String) {
            guard let sheet = view.window?.attachedSheet else { check(false, "\(name): no sheet to capture"); return }
            // 刚改过的选项先画出来再抓，不然抓到的是上一帧
            sheet.contentView?.layoutSubtreeIfNeeded()
            sheet.display()
            CATransaction.flush()
            if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(lang)-\(name)-sheet.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
            captureWindow(to: "\(outDir)/\(lang)-\(name)-window.png", includePanel: sheet)
        }
        func goBig() {
            if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == "big.jpg" }) { goTo(i) } else { check(false, "big.jpg not in folder") }
        }
        /// 裁成 3:4、完成
        func crop34() {
            at(0.8) { goBig() }
            at(0.8) {
                CropMemory.forget()
                self.straighten(nil)
                self.rotationBar.debugSelectAspect(.r3x4)
            }
            at(0.4) { key(36, "\r") }
            at(0.6) {
                check(!self.isStraightening && self.imageView.pixelSize == native, "裁成 3:4：\(SaveSize.text(self.imageView.pixelSize))")
            }
        }
        var before = Set<String>()
        /// 弹出保存对话框，pick 里选尺寸、检查，然后按 button（1 = 覆盖原图，2 = 另存一份）
        func saveWith(_ tag: String, button: Int, _ pick: @escaping (SaveSizeRow) -> Void) {
            at(0.2) {
                before = listing()
                SaveSizeRow.current = nil
                self.rotationBar.onSave?()
            }
            at(0.8) {
                guard let row = SaveSizeRow.current, let sheet = self.view.window?.attachedSheet else { check(false, "\(tag): 保存对话框没出来"); return }
                pick(row)
                self.view.window?.endSheet(sheet, returnCode: button == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            }
        }
        func newFile() -> URL? {
            let n = listing().subtracting(before)
            return n.count == 1 ? dir.appendingPathComponent(n.first!) : nil
        }

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 820, width: 1180, height: 800), display: true)
        }
        open(url: src)

        // ---- 1. 长边 1440 另存：1080×1440，拍摄日期在，原图不动；选了之后覆盖原图点不了
        at(1.5) {}
        crop34()
        saveWith("1440", button: 2) { row in
            check(row.choice == .original && row.overwriteButton?.isEnabled == true && row.note.stringValue.isEmpty
                  && row.result.stringValue.contains("3000 × 4000"), "打开时是原尺寸，覆盖原图可点，显示 \(row.result.stringValue)")
            check(row.rememberButton?.isEnabled == true, "原尺寸时「以后都这样」可勾")
            shotSheet("original")
            row.select(.preset(1440))
            check(row.overwriteButton?.isEnabled == false && row.overwriteButton?.keyEquivalent == "" && row.copyButton?.keyEquivalent == "\r",
                  "长边 1440：覆盖原图点不了，回车是另存一份")
            check(!row.note.stringValue.isEmpty && row.rememberButton?.isEnabled == false && row.rememberButton?.state == .off,
                  "长边 1440：说明「\(row.note.stringValue)」，「以后都这样」勾不了")
            check(row.result.stringValue.contains("1080 × 1440"), "长边 1440：显示 \(row.result.stringValue)")
            shotSheet("1440")
            row.select(.original)
            check(row.overwriteButton?.isEnabled == true && row.overwriteButton?.keyEquivalent == "\r" && row.note.stringValue.isEmpty && row.rememberButton?.isEnabled == true,
                  "改回原尺寸：覆盖原图又能点")
            row.select(.preset(1440))
        }
        idle {
            let f = newFile()
            let s = f.map(fileSize) ?? .zero
            check(s == CGSize(width: 1080, height: 1440), "另存 \(f?.lastPathComponent ?? "-")：\(SaveSize.text(s))")
            check(f.flatMap(exifDate) == date, "另存保留拍摄日期 \(f.flatMap(exifDate) ?? "nil")")
            check(f?.lastPathComponent.hasPrefix("big" + L10n.t("rot.cropSuffix", "-裁剪")) == true, "另存的文件名照旧 \(f?.lastPathComponent ?? "-")")
            check(untouched() && fileSize(src) == CGSize(width: 6000, height: 4000), "原图没动（内容一致）")
            check(SaveSize.last == .preset(1440), "记住了长边 1440")
            check(!self.imageView.hasPendingRotation, "另存后视图回到原样")
        }

        // ---- 2. 再存：打开就是上次的 1440；改自定义 2000
        crop34()
        saveWith("custom", button: 2) { row in
            check(row.choice == .preset(1440) && row.overwriteButton?.isEnabled == false, "再打开时是上次的长边 1440")
            row.select(.custom(SaveSize.customEdge))
            row.debugType("2000")
            check(!row.field.isHidden && row.choice == .custom(2000) && row.result.stringValue.contains("1500 × 2000"), "自定义 2000：\(row.result.stringValue)")
            shotSheet("custom")
        }
        idle {
            let s = newFile().map(fileSize) ?? .zero
            check(max(s.width, s.height) == 2000 && s == CGSize(width: 1500, height: 2000), "自定义 2000 另存：\(SaveSize.text(s))")
            check(untouched(), "原图没动")
            check(SaveSize.last == .custom(2000) && SaveSize.customEdge == 2000, "记住了自定义 2000")
        }

        // ---- 3. 原尺寸另存：裁出来的原尺寸
        crop34()
        saveWith("orig", button: 2) { row in row.select(.original) }
        idle {
            let f = newFile()
            let s = f.map(fileSize) ?? .zero
            check(s == native, "原尺寸另存：\(SaveSize.text(s))")
            check(f.flatMap(exifDate) == date && untouched(), "原尺寸另存：拍摄日期在，原图没动")
        }

        // ---- 4. 比裁出来大的尺寸：不放大，覆盖原图仍可点
        crop34()
        saveWith("4096", button: 2) { row in
            row.select(.preset(4096))
            check(row.overwriteButton?.isEnabled == true && row.shrinkEdge == nil && row.result.stringValue.contains("3000 × 4000")
                  && row.result.stringValue.contains(L10n.t("rot.size.noUpscale", "，不放大")), "长边 4096 > 4000：不放大，\(row.result.stringValue)")
            shotSheet("noupscale")
        }
        idle {
            let s = newFile().map(fileSize) ?? .zero
            check(s == native, "长边 4096 另存没放大：\(SaveSize.text(s))")
        }

        // ---- 5. 缩小时硬按「覆盖原图」（测试绕过按钮）：什么都不写
        crop34()
        saveWith("blocked", button: 1) { row in row.select(.preset(1080)) }
        at(1.2) {
            check(listing() == before && untouched() && self.imageView.hasPendingRotation, "缩小时覆盖原图不生效：没新文件、原图没动、修改还在")
        }

        // ---- 6. 记住了「另存一份」：不弹框，按原尺寸（记住的尺寸是 1080 也不用）
        at(0.2) {
            check(SaveSize.last == .preset(4096), "缩小时没保存成，不记住那次选的：仍是 \(SaveSize.last)")
            SaveSize.last = .preset(1080)
            Straighten.saveTarget = .copy
            before = listing()
            SaveSizeRow.current = nil
            self.rotationBar.onSave?()
        }
        idle {
            check(SaveSizeRow.current == nil, "记住另存一份：不弹框")
            let s = newFile().map(fileSize) ?? .zero
            check(s == native, "记住另存一份：原尺寸 \(SaveSize.text(s))")
            Straighten.saveTarget = .ask
        }

        // ---- 7. 覆盖原图：全分辨率，拍摄日期在
        crop34()
        saveWith("overwrite", button: 1) { row in
            check(row.choice == .preset(1080) && row.overwriteButton?.isEnabled == false, "打开时是记住的长边 1080，覆盖点不了")
            row.select(.original)
            check(row.overwriteButton?.isEnabled == true, "改回原尺寸后覆盖可点")
        }
        idle {
            check(listing() == before, "覆盖原图：没有新文件")
            check(fileSize(src) == native && !untouched(), "覆盖原图：\(SaveSize.text(fileSize(src)))，全分辨率")
            check(exifDate(src) == date, "覆盖原图保留拍摄日期 \(exifDate(src) ?? "nil")")
        }

        at(0.5) {
            Straighten.saveTarget = savedTarget
            Straighten.remindUnsaved = savedRemind
            suite.removePersistentDomain(forName: suiteName)
            SaveSize.defaults = savedSizeDefaults
            CropMemory.defaults = savedMemory
            print("CROPSIZE summary [\(lang)] checks=\(checks) failures=\(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        runNext()
    }
}

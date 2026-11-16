import AppKit
import ImageIO

/// --watermarktest 里关于导出窗口预览和多行「本次文字」的部分：
/// 预览有图、随样式 / 文字 / 胶片 / 长边变化、和真正导出的缩小图一致、过期的渲染被丢掉、24 MP 的耗时；
/// 回车是换行不触发默认按钮、Tab 跳走；多行文字从任务到渲染到预设 JSON 都保留；两列排版不重叠、各语言不截断
private final class ClickCounter: NSObject {
    var count = 0
    @objc func fire() { count += 1 }
}

extension ViewerViewController {
    func runExportPreviewChecks(work: URL, idcard: URL, portrait: URL, landscape: URL, store: WatermarkStore, shots: URL, lang: String) {
        typealias T = WatermarkSelfTest
        typealias X = ExportSelfTest
        let fm = FileManager.default
        let id = store.styles.first { $0.builtIn == "id" }!, proof = store.styles.first { $0.builtIn == "proof" }!, sign = store.styles.first { $0.builtIn == "sign" }!
        func accessory(_ url: URL) -> ExportAccessory {
            let a = ExportAccessory(formats: ["JPEG", "PNG", "HEIC"], formatIndex: 0, quality: 85) {}
            a.preview.delay = 0.02
            a.setPhoto(url: url, turns: 0, degrees: 0, crop: nil)
            a.preview.debugFlush()
            return a
        }

        // ---- 预览有图，随各项变化
        let a = accessory(idcard)
        let pv = a.preview
        T.check(pv.lastImage != nil && pv.debugBaseReady, "preview: an image exists once the photo is read (\(pv.lastImage?.width ?? 0)x\(pv.lastImage?.height ?? 0))")
        T.check(max(pv.lastImage?.width ?? 0, pv.lastImage?.height ?? 0) <= ExportPreviewRender.maxBase, "preview: rendered from a downscaled source (long edge ≤ \(ExportPreviewRender.maxBase))")
        let none = pv.lastImage
        let row = a.options.watermarkRow
        row.debugSelect(1)
        pv.debugFlush()
        let withID = pv.lastImage
        if let n = none, let w = withID { T.check(T.changes(n, w, threshold: 4).fraction > 0.02, "preview: choosing a watermark style changes the preview") } else { T.check(false, "preview: missing images") }
        row.field.debugType("仅供办理租房使用")
        pv.debugFlush()
        let typed = pv.lastImage
        if let w = withID, let t = typed { T.check(T.changes(w, t, threshold: 4).count > 800, "preview: typing in the text field updates the preview") } else { T.check(false, "preview: typed image missing") }
        row.debugSelect(2)
        pv.debugFlush()
        if let t = typed, let p = pv.lastImage { T.check(T.changes(t, p, threshold: 4).count > 800, "preview: switching to another style updates the preview") } else { T.check(false, "preview: style image missing") }
        row.debugSelect(0)
        pv.debugFlush()
        if let n = none, let p = pv.lastImage { T.check(T.changes(n, p, threshold: 1).count == 0, "preview: with 无 it is just the photo, same as before any watermark") } else { T.check(false, "preview: 无 image missing") }
        T.check(pv.debugCaption == L10n.t("wm.preview", "预览"), "preview: caption without a long-edge limit is just the title (\(pv.debugCaption))")
        // 长边限制
        row.debugSelect(1)
        a.options.debugSet(long: 600, megabytes: 1, srgb: false, strip: false)
        a.options.onChange?()
        pv.debugFlush()
        let limited = pv.lastImage
        T.check(limited.map { max($0.width, $0.height) == 600 } == true, "preview: a long-edge limit of 600 gives a 600 px preview (\(limited?.width ?? 0)x\(limited?.height ?? 0))")
        let capSize = pv.debugOutputSize
        T.check(capSize.map { max($0.w, $0.h) == 600 } == true && pv.debugCaption.contains("600"), "preview: caption shows the output pixel size (\(pv.debugCaption))")
        // 不相干的选项（元数据、大小）不重画
        let delivered = pv.deliveredCount
        a.options.onChange?()
        pv.debugFlush()
        T.check(pv.deliveredCount == delivered, "preview: an unchanged picture is not re-rendered")

        // ---- 胶片（Pro）
        #if FLIPIC_PRO
        FilmEffect.install()
        License.debugSetTrialStart(daysAgo: 0)
        let b = accessory(landscape)
        b.options.watermarkRow.debugSelect(0)
        b.preview.debugFlush()
        let beforeFilm = b.preview.lastImage
        b.options.debugSelectFilm(1)
        b.preview.debugFlush()
        if let x = beforeFilm, let y = b.preview.lastImage, b.options.options.effect != nil {
            T.check(T.changes(x, y, threshold: 3).fraction > 0.2, "preview: choosing a film look changes the preview (\(String(format: "%.0f", T.changes(x, y, threshold: 3).fraction * 100))% of pixels)")
        } else { T.check(false, "preview: film look did not apply") }
        b.options.debugSelectFilm(0)
        #endif

        // ---- 预览和真正的导出一致（同样的选项，真导出缩到预览的大小）
        var o = ExportOptions()
        o.watermark = WatermarkJob(style: id, text: "仅供办理租房使用")
        o.maxLongEdge = 700
        let realURL = work.appendingPathComponent("preview-vs-real.jpg")
        _ = X.uiExport(idcard, realURL, o, quality: 95)
        let c = accessory(idcard)
        c.options.watermarkRow.debugSelect(1)
        c.options.watermarkRow.field.debugType("仅供办理租房使用")
        c.options.debugSet(long: 700, megabytes: 1, srgb: false, strip: false)
        c.options.onChange?()
        c.preview.debugFlush()
        if let real = T.decode(realURL), let prev = c.preview.lastImage {
            let d = T.thumbDiff(real, prev)
            T.check(abs(real.width - prev.width) <= 1 && abs(real.height - prev.height) <= 1, "preview vs export: same pixel size (\(prev.width)x\(prev.height) vs \(real.width)x\(real.height))")
            T.check(d < 3.0, "preview vs export: pictures match within tolerance (mean channel difference \(String(format: "%.2f", d)))")
            let ch = T.changes(real, prev, threshold: 40)
            T.check(ch.fraction < 0.01, "preview vs export: almost no pixel differs strongly (\(String(format: "%.3f", ch.fraction * 100))%)")
        } else { T.check(false, "preview vs export: images missing") }
        let outSize = c.preview.debugOutputSize
        T.check(outSize.map { X.size(realURL).0 == $0.w && X.size(realURL).1 == $0.h } == true, "preview: caption pixel size equals the real export size (\(outSize.map { "\($0.w)x\($0.h)" } ?? "-") vs \(X.size(realURL)))")

        // ---- 过期的渲染被丢掉
        let d = accessory(landscape)
        d.options.watermarkRow.debugSelect(1)
        d.preview.debugFlush()
        d.preview.renderHook = { Thread.sleep(forTimeInterval: 0.25) }
        let dropsBefore = d.preview.droppedCount
        let deliveredBefore = d.preview.deliveredCount
        d.options.watermarkRow.field.debugType("FIRST")
        d.preview.render(force: true)
        d.options.watermarkRow.field.debugType("SECOND")
        d.preview.render(force: true)
        d.options.watermarkRow.field.debugType("THIRD LINE\nSECOND LINE")
        d.preview.render(force: true)
        d.preview.debugFlush()
        d.preview.renderHook = nil
        T.check(d.preview.droppedCount - dropsBefore >= 2 && d.preview.deliveredCount - deliveredBefore == 1, "stale: 3 quick renders → 1 delivered, \(d.preview.droppedCount - dropsBefore) dropped")
        let expected = ExportPreviewRender.image(base: ImageLoader.decodedFull(url: landscape, maxPixel: 1400)!, options: d.options.options, fileName: "landscape", source: landscape)
        if let got = d.preview.lastImage { T.check(T.changes(expected, got, threshold: 1).count == 0, "stale: what stays on screen is the newest text, not an older render") } else { T.check(false, "stale: no image") }

        // ---- 24 MP 的耗时
        let big = work.appendingPathComponent("big24mp.jpg")
        T.makeScene(big, width: 6000, height: 4000, seed: 3)
        let t0 = CFAbsoluteTimeGetCurrent()
        let decoded = ImageLoader.decodedFull(url: big, maxPixel: 1400)
        let tDecode = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        var bo = ExportOptions(); bo.watermark = WatermarkJob(style: id, text: "仅供办理租房使用\n2026-11-16")
        var times: [Double] = []
        for _ in 0..<5 {
            let t1 = CFAbsoluteTimeGetCurrent()
            _ = ExportPreviewRender.image(base: decoded!, options: bo, fileName: "big24mp", source: big)
            times.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }
        let e = accessory(big)
        e.options.watermarkRow.debugSelect(1)
        e.preview.debugFlush()
        T.info("preview timing 24 MP (6000x4000): decode to ≤1400 = \(String(format: "%.0f", tDecode)) ms, render median = \(String(format: "%.0f", T.median(times))) ms (runs \(times.map { String(format: "%.0f", $0) }.joined(separator: "/"))), pane render = \(String(format: "%.0f", e.preview.lastMillis)) ms")
        T.check(decoded.map { max($0.width, $0.height) == 1400 } == true && T.median(times) < 400, "timing: 24 MP preview renders in \(String(format: "%.0f", T.median(times))) ms from a 1400 px source")
        try? fm.removeItem(at: big)

        // ---- 多行文字
        let lines = "Line A\nLine B\nLine C"
        var sg = sign.frozen(); sg.opacity = 1; sg.edge = .none; sg.size = 0.05
        let flat = T.solid(1200, 800)
        func inkRows(_ img: CGImage?) -> Int {
            guard let img else { return 0 }
            let pa = T.rgba(flat), pb = T.rgba(img)
            var rows = 0
            for y in 0..<800 {
                var hit = false
                for x in 0..<1200 { let o = (y * 1200 + x) * 4; if abs(Int(pa[o]) - Int(pb[o])) > 2 { hit = true; break } }
                if hit { rows += 1 }
            }
            return rows
        }
        let oneRows = inkRows(WatermarkRenderer.render(flat, style: sg, text: "Line A", fileName: nil))
        let threeRows = inkRows(WatermarkRenderer.render(flat, style: sg, text: lines, fileName: nil))
        T.check(oneRows > 0 && threeRows > oneRows * 2, "multi-line: three lines cover more ink rows than one (\(threeRows) vs \(oneRows))")
        let job = WatermarkJob(style: id, text: lines)
        T.check(job.text == lines && job.effectiveText == lines, "multi-line: the job keeps the newlines")
        if let data = try? JSONEncoder().encode(job), let back = try? JSONDecoder().decode(WatermarkJob.self, from: data) {
            T.check(back.text == lines && String(data: data, encoding: .utf8)?.contains("\\n") == true, "multi-line: survives a JSON round trip (\(data.count) bytes)")
        } else { T.check(false, "multi-line: JSON round trip failed") }
        let acc2 = accessory(landscape)
        let row2 = acc2.options.watermarkRow
        row2.debugSelect(1)
        row2.field.debugType(lines)
        T.check(row2.job?.text == lines && row2.field.stringValue == lines, "multi-line: the text field hands the job the full text")
        // 导出文件里是多行
        var o1 = ExportOptions(); o1.watermark = WatermarkJob(style: sg, text: "Line A")
        var o3 = ExportOptions(); o3.watermark = WatermarkJob(style: sg, text: lines)
        let u1 = work.appendingPathComponent("ml-1.jpg"), u3 = work.appendingPathComponent("ml-3.jpg"), u0 = work.appendingPathComponent("ml-0.jpg")
        _ = X.uiExport(landscape, u0, ExportOptions()); _ = X.uiExport(landscape, u1, o1); _ = X.uiExport(landscape, u3, o3)
        if let p0 = T.decode(u0), let p1 = T.decode(u1), let p3 = T.decode(u3) {
            let r1 = T.changes(p0, p1, threshold: 6).box.height, r3 = T.changes(p0, p3, threshold: 6).box.height
            T.check(r3 > r1 * 2, "multi-line: the exported file shows three lines (mark height \(Int(r3)) px vs \(Int(r1)) px)")
        } else { T.check(false, "multi-line: exports missing") }
        #if FLIPIC_PRO
        let suite = UserDefaults(suiteName: "\(Bundle.main.bundleIdentifier ?? "x").mlpreset.\(UUID().uuidString)")!
        let ps = ExportPresetStore(defaults: suite)
        var po = ExportOptions(); po.watermark = job
        _ = ps.add(ExportPreset(name: "ML", format: "JPEG", quality: 85, options: po))
        let reread = ExportPresetStore(defaults: suite).presets.first?.options.exportOptions.watermark
        T.check(reread?.text == lines && reread?.effectiveText == lines, "multi-line: stored in a preset's JSON and read back with the newlines")
        #endif

        // ---- 回车是换行，不触发默认按钮；Tab 跳走
        let counter = ClickCounter()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        let ok = NSButton(title: "OK", target: counter, action: #selector(ClickCounter.fire))
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: 320, y: 10, width: 80, height: 28)
        let field = MultilineTextField(width: 232)
        field.frame = NSRect(x: 20, y: 120, width: 232, height: 60)
        let next = NSTextField(string: "")
        next.frame = NSRect(x: 20, y: 80, width: 232, height: 22)
        for v in [ok, field, next] as [NSView] { host.addSubview(v) }
        win.contentView = host
        win.defaultButtonCell = ok.cell as? NSButtonCell
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(field.textView)
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            // 和系统一样：先问窗口有没有人要这个组合键（默认按钮），没有再当作按键交给焦点控件
            if !win.performKeyEquivalent(with: e) { NSApp.sendEvent(e) }
            T.spin(0.05)
        }
        field.stringValue = ""
        var changed = 0
        field.onTextChange = { changed += 1 }
        key(0, "a"); key(36, "\r"); key(0, "b"); key(76, "\u{3}"); key(0, "c")
        T.check(field.stringValue == "a\nb\nc", "return key: inserts a newline in the text field (\(field.stringValue.debugDescription))")
        T.check(counter.count == 0, "return key: the window's default button did not fire (\(counter.count) times)")
        T.check(changed >= 5, "return key: every key press reports a text change (\(changed))")
        key(48, "\t")
        T.check(win.firstResponder === next.currentEditor() || win.firstResponder === next, "tab key: moves focus to the next control")
        T.check(!field.stringValue.contains("\t"), "tab key: no tab character was typed into the text")
        win.makeFirstResponder(field.textView)
        let defaultBefore = win.defaultButtonCell
        T.check(defaultBefore == nil, "return key: while typing, the window has no default button (so Return can never fire it)")
        win.makeFirstResponder(next)
        T.check(win.defaultButtonCell === ok.cell, "return key: the default button comes back when focus leaves the text field")
        key(36, "\r")
        T.check(counter.count == 1, "return key: outside the text field Return still triggers the default button")
        win.orderOut(nil)

        // ---- 两列排版：不重叠、都在附件里、尺寸合理
        let acc = accessory(idcard)
        acc.options.watermarkRow.debugSelect(1)
        acc.options.watermarkRow.field.debugType("仅供办理租房使用\n2026-11-16")
        acc.view.layoutSubtreeIfNeeded()
        if let outer = acc.view as? NSStackView {
            let left = outer.arrangedSubviews[0].frame, right = acc.preview.frame
            T.check(!left.intersects(right) && left.maxX <= outer.bounds.maxX && right.maxX <= outer.bounds.maxX && right.minX >= 0 && left.minX >= 0, "layout: controls and preview side by side, no overlap (controls \(left.integral), preview \(right.integral) in \(outer.bounds.size))")
            T.check(abs(left.height - right.height) < 1.5, "layout: the preview is as tall as the controls column (\(Int(left.height)) vs \(Int(right.height)))")
            T.check(right.width >= 340 && right.height >= 200, "layout: the preview is big enough to read (\(Int(right.width))x\(Int(right.height)))")
            T.check(outer.frame.width <= 900 && outer.frame.height <= 560, "layout: accessory fits typical save panel sizes (≤ 900 x 560)")
            T.info("accessory size (\(lang)) with text field: \(Int(outer.frame.width)) x \(Int(outer.frame.height)); preview \(Int(right.width)) x \(Int(right.height)); rtl=\(NSApp.userInterfaceLayoutDirection == .rightToLeft)")
        }
        acc.options.watermarkRow.debugSelect(0)
        acc.view.layoutSubtreeIfNeeded()
        T.info("accessory size (\(lang)) with 无: \(Int(acc.view.frame.width)) x \(Int(acc.view.frame.height))")
    }
}

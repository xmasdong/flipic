import AppKit
import ImageIO

/// --watermarktest 的后半：真的走一遍 ⌘S 面板；各窗口截图；编辑窗口；三张完整导出样张；各语言的排版检查
extension ViewerViewController {
    /// 看图窗口里打开照片，真的点 ⌘S（保存面板是 sheet），选水印、改本次文字、点「导出」
    func runWatermarkPanelFlow(work: URL, outs: URL, src: URL, idcard: URL, shotsDir: URL) {
        typealias T = WatermarkSelfTest
        typealias X = ExportSelfTest
        let fm = FileManager.default
        let ui = work.appendingPathComponent("uiphotos")
        try? fm.createDirectory(at: ui, withIntermediateDirectories: true)
        let shown = ui.appendingPathComponent("p3.jpg")
        try? fm.copyItem(at: src, to: shown)
        try? fm.copyItem(at: idcard, to: ui.appendingPathComponent("idcard-sample.jpg"))
        let shaShown = T.sha(shown)
        open(url: shown)
        T.spin(3) { self.folder.current != nil }
        T.check(folder.current != nil, "panel: photo opened in the viewer")
        let store = WatermarkStore.shared
        let idStyle = store.styles.first { $0.builtIn == "id" }!
        WatermarkMemory.defaults.removeObject(forKey: WatermarkMemory.exportKey)

        // 文件 › 加水印导出…
        exportWithWatermark(nil)
        T.spin(3) { self.exportAccessory != nil }
        guard let acc = exportAccessory, let panel = exportSavePanel else { T.check(false, "panel: ⌘S export panel did not appear"); return }
        let row = acc.options.watermarkRow
        T.check(row.active?.id == idStyle.id && !row.field.isHidden && row.field.stringValue == idStyle.resolvedText, "panel: 加水印导出… opens ⌘S with 证件用途 selected and its text in the field")
        // 选「无」再选回来：面板的大小跟着变
        row.debugSelect(0)
        T.spin(0.6)
        let hNone = panel.frame.height
        row.debugSelect(1)
        T.spin(0.8)
        let hStyle = panel.frame.height
        T.info("panel height none=\(hNone) style=\(hStyle) accessory=\(acc.view.frame.height)")
        T.check(hStyle > hNone, "panel: the save panel itself grows when the text field appears (\(hNone) → \(hStyle))")
        // 真正的保存面板：附件在哪个窗口里、预览画出来没有、回车和 Tab 在面板里是什么表现，再按窗口号抓图
        acc.preview.delay = 0.02
        let lang0 = Bundle.main.preferredLocalizations.first ?? "?"
        row.field.debugType(lang0.hasPrefix("zh") ? "仅供办理租房使用\n2026-11-16" : "For rental application only\n2026-11-16")
        acc.preview.debugFlush()
        T.check(acc.preview.lastImage != nil && acc.preview.debugBaseReady, "real panel: the preview in the ⌘S accessory rendered the opened photo")
        let tv = row.field.textView
        _ = tv.window?.makeFirstResponder(tv)
        let host = tv.window
        T.info("real panel: accessory window title=「\(host?.title ?? "-")」 class=\(host.map { String(describing: type(of: $0)) } ?? "-") isPanel=\(host === panel) sheet=\(panel.sheetParent != nil) accessory frame=\(acc.view.frame.size) windowFrame=\(host?.frame.size ?? .zero)")
        T.check(host?.firstResponder === tv, "real panel: the multi-line field can take focus inside the save panel")
        if let host {
            let before = tv.string
            for (code, chars) in [(UInt16(36), "\r"), (UInt16(0), "x")] {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                if !host.performKeyEquivalent(with: e) { NSApp.sendEvent(e) }
                T.spin(0.15)
            }
            T.check(tv.string == before + "\nx" && panel.sheetParent != nil && self.exportAccessory != nil, "real panel: Return in the field typed a newline and the Save panel stayed open (\(tv.string.suffix(4).debugDescription))")
        }
        row.field.debugType(lang0.hasPrefix("zh") ? "仅供办理租房使用\n2026-11-16" : "For rental application only\n2026-11-16")
        acc.preview.debugFlush()
        T.spin(0.8)
        T.shootOurWindows(prefix: "real-panel", dir: shotsDir)
        // 保存面板的内容是系统另一个进程画的，按窗口号抓只有空壳，附件窗口也不在屏幕上：附件窗口自己的内容在本进程里画一遍
        T.check(T.shootView(host?.contentView, shotsDir.appendingPathComponent("real-panel-accessory-window-\(lang0).png")), "shot: the real save panel's accessory window (\(host?.title ?? "-")), drawn in-process")

        row.field.debugType("仅供办理租房使用")
        T.spin(8) { self.exportEstimateLabel?.stringValue.contains("…") == false && self.exportEstimateLabel?.stringValue.isEmpty == false }
        T.check(self.exportEstimateLabel?.stringValue.contains("…") == false, "panel: estimate follows the watermarked image: \(self.exportEstimateLabel?.stringValue ?? "-")")
        let dest = ui.appendingPathComponent("p3-compressed.jpg")
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
        T.spin(8) { fm.fileExists(atPath: dest.path) && !self.isProcessing }
        T.check(fm.fileExists(atPath: dest.path), "panel: exported through the real ⌘S panel → \(dest.lastPathComponent)")
        T.check(WatermarkMemory.last(WatermarkMemory.exportKey) == idStyle.id, "panel: the choice was remembered for next time")
        T.check(store.style(id: idStyle.id)?.text == "", "panel: the saved style's text was not touched by the typed text")
        T.check(T.sha(shown) == shaShown, "panel: the original photo is byte-identical after the export")
        let plainRef = work.appendingPathComponent("panel-plain.jpg")
        _ = X.uiExport(shown, plainRef, ExportOptions())
        let markedDefault = work.appendingPathComponent("panel-default-text.jpg")
        var o = ExportOptions(); o.watermark = WatermarkJob(style: idStyle)
        _ = X.uiExport(shown, markedDefault, o)
        var o2 = ExportOptions(); o2.watermark = WatermarkJob(style: idStyle, text: "仅供办理租房使用")
        let markedTyped = work.appendingPathComponent("panel-typed-text.jpg")
        _ = X.uiExport(shown, markedTyped, o2)
        if let a = T.decode(plainRef), let b = T.decode(dest), let c = T.decode(markedDefault), let d = T.decode(markedTyped) {
            T.check(T.changes(a, b, threshold: 6).fraction > 0.03, "panel: the exported file carries the watermark")
            T.check(T.changes(c, b, threshold: 6).count > 1000, "panel: the typed text (not the style's default text) was rendered")
            T.check(T.changes(d, b, threshold: 2).fraction < 0.001, "panel: the file matches an export built with the same typed text")
        } else { T.check(false, "panel: could not decode the outputs") }
        let em = X.exif(dest)
        // 证件用途会自动勾上「去掉位置信息」：拍摄信息留着，位置去掉
        T.check(X.val(em, "Make") == "TESTCAM" && !X.has(em, "GPSLatitude"), "panel: ID style keeps camera info and drops the location in the ⌘S export")
        T.check(ExportOptions.saved.stripGPS == false, "panel: the automatic strip-location tick is not remembered for later exports")

        // 选「无」导出：没有水印
        exportAs(nil)
        T.spin(3) { self.exportAccessory != nil }
        guard let acc2 = exportAccessory, let panel2 = exportSavePanel else { T.check(false, "panel: second ⌘S panel did not appear"); return }
        T.check(acc2.options.watermarkRow.active?.id == idStyle.id, "panel: plain ⌘S opens with the last used style (remembered)")
        acc2.options.watermarkRow.debugSelect(0)
        let dest2 = dest
        try? fm.removeItem(at: dest2)
        panel2.sheetParent?.endSheet(panel2, returnCode: .OK)
        T.spin(8) { fm.fileExists(atPath: dest2.path) && !self.isProcessing }
        if let a = T.decode(plainRef), let b = T.decode(dest2) { T.check(T.changes(a, b, threshold: 1).count == 0, "panel: choosing 无 exports with no watermark") } else { T.check(false, "panel: no-watermark export missing") }
        T.check(WatermarkMemory.defaults.string(forKey: WatermarkMemory.exportKey) == "none", "panel: 无 is remembered as the choice")
        WatermarkMemory.defaults.removeObject(forKey: WatermarkMemory.exportKey)
    }

    /// 截图、编辑窗口、样张、排版检查，最后打印汇总并退出
    func wmFinishStage1(work: URL, outs: URL, shots: URL, idcard: URL, portrait: URL, landscape: URL, store: WatermarkStore, uiOnly: Bool) {
        typealias T = WatermarkSelfTest
        typealias X = ExportSelfTest
        let fm = FileManager.default
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let id = store.styles.first { $0.builtIn == "id" }!, proof = store.styles.first { $0.builtIn == "proof" }!, sign = store.styles.first { $0.builtIn == "sign" }!

        runExportPreviewChecks(work: work, idcard: idcard, portrait: portrait, landscape: landscape, store: store, shots: shots, lang: lang)

        // ---- 三张完整导出的样张
        func sample(_ url: URL, _ style: WatermarkStyle, _ name: String) {
            var o = ExportOptions(); o.watermark = WatermarkJob(style: style)
            let dest = outs.appendingPathComponent("\(name)-\(lang).jpg")
            T.check(X.uiExport(url, dest, o) != nil && fm.fileExists(atPath: dest.path), "sample: \(dest.lastPathComponent) written (\(X.size(dest)))")
        }
        sample(idcard, id, "idcard-id")
        sample(portrait, proof, "portrait-proof")
        sample(landscape, sign, "landscape-sign")
        sample(portrait, id, "portrait-id")
        sample(idcard, proof, "idcard-proof")

        // ---- 导出窗口各处的截图（普通窗口里放附件；保存面板本身是 sheet，抓不到）
        func shootAccessory(_ a: ExportAccessory, _ name: String) {
            a.preview.debugFlush()
            let pad: CGFloat = 20
            let box = NSView(frame: NSRect(x: 0, y: 0, width: a.view.frame.width + 2 * pad, height: a.view.frame.height + 2 * pad))
            a.view.frame.origin = NSPoint(x: pad, y: pad)
            box.addSubview(a.view)
            let win = NSWindow(contentRect: box.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = box
            win.center()
            win.makeKeyAndOrderFront(nil)
            T.spin(0.8)
            T.check(T.shootWindow(win, shots.appendingPathComponent("\(name)-\(lang).png")), "shot: \(name)")
            T.layoutCheck(box, name)
            win.orderOut(nil)
        }
        let two = lang.hasPrefix("zh") ? "仅供办理租房使用\n2026-11-16" : "For rental application only\n2026-11-16"
        WatermarkMemory.defaults.removeObject(forKey: WatermarkMemory.exportKey)
        let a1 = ExportAccessory(formats: ["JPEG", "PNG", "HEIC"], formatIndex: 0, quality: 85) {}
        a1.preview.delay = 0.02
        a1.setPhoto(url: idcard, turns: 0, degrees: 0, crop: nil)
        a1.estimateLabel.stringValue = L10n.f("exp.estimate", "预计大小： %@", "1.2 MB")
        shootAccessory(a1, "export-panel-none")
        a1.options.watermarkRow.debugSelect(1)
        a1.options.watermarkRow.field.debugType(two)
        shootAccessory(a1, "export-panel-watermark")
        // 样片（竖的照片）
        a1.setPhoto(url: portrait, turns: 0, degrees: 0, crop: nil)
        a1.options.watermarkRow.debugSelect(2)
        a1.options.watermarkRow.field.debugType(lang.hasPrefix("zh") ? "样片 请勿外传" : "Sample - do not share")
        shootAccessory(a1, "export-panel-proof")

        let (alert, bacc) = debugBatchAlert()
        bacc.options.watermarkRow.debugSelect(2)
        bacc.options.watermarkRow.field.debugType(two)
        bacc.preview.debugFlush()
        alert.layout()
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        T.spin(1.0)
        T.check(T.shootWindow(alert.window, shots.appendingPathComponent("batch-dialog-\(lang).png")), "shot: batch dialog with the watermark row")
        T.layoutCheck(alert.window.contentView!, "batch dialog")
        let heightWith = alert.window.frame.height
        bacc.options.watermarkRow.debugSelect(0)
        T.spin(0.4)
        T.check(alert.window.frame.height < heightWith, "batch: the dialog itself shrinks when the text field disappears (\(heightWith) → \(alert.window.frame.height))")
        bacc.options.watermarkRow.debugSelect(2)
        T.spin(0.4)
        alert.window.orderOut(nil)

        #if FLIPIC_PRO
        // 预设编辑窗口
        var po = ExportOptions(); po.watermark = WatermarkJob(style: id, text: "仅供办理租房使用"); po.maxLongEdge = 2048
        let preset = ExportPreset(name: (lang.hasPrefix("zh") ? "租房材料" : "Rental documents"), format: "JPEG", quality: 85, options: po,
                                  destination: PresetDestination(kind: .subfolder, subfolder: "导出"))
        ExportPresetStore.shared.add(preset)
        let pm = PresetManagerController.shared
        pm.show()
        T.spin(1.0)
        pm.debugSelect(0)
        T.spin(0.8)
        T.check(pm.debugOptionsView?.watermarkRow.active?.id == id.id && pm.debugOptionsView?.watermarkRow.field.stringValue == "仅供办理租房使用", "preset editor: shows the preset's watermark and its text")
        T.check(T.shootWindow(pm.window, shots.appendingPathComponent("preset-editor-\(lang).png")), "shot: preset editor")
        T.layoutCheck(pm.window!.contentView!, "preset editor")
        // 在预设编辑里换成另一个样式、改文字 → 存进预设
        pm.debugOptionsView?.watermarkRow.debugSelect(2)
        T.spin(0.2)
        T.check(ExportPresetStore.shared.presets.first?.options.watermark?.style.id == proof.id, "preset editor: choosing a style stores the full style in the preset")
        pm.debugOptionsView?.watermarkRow.field.debugType("预设文字")
        T.check(ExportPresetStore.shared.presets.first?.options.watermark?.text == "预设文字", "preset editor: the text is stored in the preset, not in the style (style text '\(store.style(id: proof.id)?.text ?? "-")')")
        pm.debugOptionsView?.watermarkRow.debugSelect(0)
        T.check(ExportPresetStore.shared.presets.first?.options.watermark == nil, "preset editor: choosing 无 clears the watermark")
        pm.debugOptionsView?.watermarkRow.debugSelect(1)
        pm.window?.orderOut(nil)
        #endif

        // ---- 编辑窗口
        WatermarkEditor.photoProvider = { idcard }
        let ed = WatermarkEditor.shared
        ed.skipDeleteConfirm = true
        ed.show(selecting: id.id)
        ed.debugFlushPreview()
        T.spin(8) { ed.debugPreviewDecoded }
        ed.debugFlushPreview()
        T.check(ed.lastPreview != nil && !ed.debugPreviewIsPlaceholder, "editor: live preview rendered on the current photo (\(ed.lastPreview?.width ?? 0) px wide, \(String(format: "%.0f", ed.lastPreviewMillis)) ms)")
        T.check(ed.debugCount.contains("3"), "editor: lists the three built-in styles (\(ed.debugCount))")
        for (i, st) in [id, proof, sign].enumerated() {
            ed.debugSelect(i)
            T.spin(0.5)
            ed.debugFlushPreview()
            T.spin(0.4)
            let n = ["id", "proof", "sign"][i]
            T.check(ed.nameField.stringValue == st.displayName && ed.textView.string == st.resolvedText, "editor: \(n) loads its name and text")
            T.check(T.shootWindow(ed.window, shots.appendingPathComponent("editor-\(n)-\(lang).png")), "shot: editor with \(n)")
            if i == 0 { T.layoutCheck(ed.window!.contentView!, "editor"); T.layoutCheck(ed.debugForm, "editor form") }
        }
        // 改控件 → 存进样式 → 预览跟着变
        ed.debugSelect(0)
        T.spin(0.3)
        ed.debugFlushPreview()
        let beforePrev = ed.lastPreview
        ed.opacitySlider.doubleValue = 0.9
        ed.debugCommit()
        ed.debugFlushPreview()
        T.check(store.style(id: id.id)?.opacity == 0.9, "editor: moving the opacity slider updates the saved style")
        if let a = beforePrev, let b = ed.lastPreview { T.check(T.changes(a, b, threshold: 3).count > 500, "editor: the preview re-renders when a control changes") } else { T.check(false, "editor: preview missing") }
        ed.debugType("Line A\nLine B")
        T.check(store.style(id: id.id)?.text == "Line A\nLine B", "editor: multi-line text is saved")
        ed.debugTypeName("自定义名")
        T.check(store.style(id: id.id)?.name == "自定义名", "editor: renaming is saved")
        ed.layoutSeg.selectedSegment = 1
        ed.debugCommit()
        T.check(store.style(id: id.id)?.layout == .single, "editor: switching to a single mark is saved")
        if let b = ed.debugAnchorButtons.first(where: { $0.tag == 0 }) { b.performClick(nil) }
        T.check(store.style(id: id.id)?.anchor == .topLeft, "editor: nine-position picker sets the anchor")
        ed.tintSeg.selectedSegment = 2
        ed.colorWell.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        ed.debugCommit()
        T.check(store.style(id: id.id)?.tint == .custom && store.style(id: id.id)?.customColor == [1, 0, 0], "editor: custom colour is saved")
        // 添加、复制、删除、恢复
        let nBefore = store.styles.count
        ed.addStyle()
        T.check(store.styles.count == nBefore + 1, "editor: Add creates a style")
        ed.duplicateStyle()
        T.check(store.styles.count == nBefore + 2, "editor: Duplicate adds another")
        ed.deleteStyle(); ed.deleteStyle()
        T.check(store.styles.count == nBefore, "editor: Delete removes the selected style")
        ed.resetBuiltIns()
        T.check(store.style(id: id.id)?.layout == .tiled && store.style(id: id.id)?.name == "" && store.style(id: id.id)?.opacity == id.opacity, "editor: Reset built-ins puts 证件用途 back as shipped")
        // 图片水印
        let logo = work.appendingPathComponent("editor-logo.png")
        T.makeLogoPNG(logo)
        ed.addStyle()
        ed.kindSeg.selectedSegment = 1
        ed.debugCommit()
        ed.debugSetImage(logo)
        ed.debugFlushPreview()
        let sid = ed.selectedID
        T.check(sid.flatMap { store.style(id: $0) }?.imageFile != nil && sid.flatMap({ store.style(id: $0) })?.kind == .image, "editor: choosing a picture copies it into the store and switches the style to a picture")
        T.check(T.shootWindow(ed.window, shots.appendingPathComponent("editor-image-\(lang).png")), "shot: editor with a picture watermark")
        if let sid { store.remove(id: sid) }
        // 没有打开照片：中性占位图
        WatermarkEditor.photoProvider = { nil }
        ed.prepare(selecting: id.id)
        T.spin(0.5)
        ed.debugFlushPreview()
        T.check(ed.debugPreviewIsPlaceholder && ed.lastPreview != nil, "editor: falls back to the placeholder picture when no photo is open (\(ed.debugPreviewCaption))")
        T.check(T.shootWindow(ed.window, shots.appendingPathComponent("editor-placeholder-\(lang).png")), "shot: editor on the placeholder")
        ed.window?.orderOut(nil)

        // ---- 隔离：没写进真的 Application Support
        let real = WatermarkStore.defaultDirectory
        T.check(real.path.contains(Bundle.main.bundleIdentifier ?? "?") && !real.path.contains("com.xmasdong.photoview/Watermarks") , "isolated: the default store folder belongs to the test bundle id (\(real.lastPathComponent))")
        let output = ["WATERMARKTEST"]
        _ = output
        T.finish()
    }
}

extension WatermarkSelfTest {
    /// 排版检查：一行文字被截断，或者控件超出它所在的容器，都算问题
    static func layoutCheck(_ root: NSView, _ name: String) {
        root.layoutSubtreeIfNeeded()
        var clipped: [String] = []
        var outside: [String] = []
        func walk(_ v: NSView, depth: Int) {
            if v.isHidden || NSStringFromClass(type(of: v)).hasPrefix("_NS") { return }
            if let t = v as? NSTextField, !t.isEditable, !t.stringValue.isEmpty, t.bounds.width > 0 {
                let single = t.maximumNumberOfLines == 1 || t.cell?.wraps == false
                if single {
                    let need = ceil(t.attributedStringValue.size().width)
                    if need > t.bounds.width + 1.5 && t.lineBreakMode != .byTruncatingMiddle && t.lineBreakMode != .byTruncatingTail { clipped.append("\(t.stringValue.prefix(24)) need \(Int(need)) have \(Int(t.bounds.width))") }
                } else {
                    // 换行的文字：算高度够不够
                    let w = t.bounds.width
                    let h = t.attributedStringValue.boundingRect(with: NSSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin]).height
                    if h > t.bounds.height + 2 { clipped.append("\(t.stringValue.prefix(24)) wrapped needs h \(Int(h)) have \(Int(t.bounds.height))") }
                }
            }
            if let b = v as? NSButton, b.bezelStyle != .regularSquare, !(b is NSPopUpButton), !b.title.isEmpty, b.bounds.width > 0 {
                let need = ceil(b.attributedTitle.size().width)
                if need > b.bounds.width + 1.5 { clipped.append("button \(b.title.prefix(20)) need \(Int(need)) have \(Int(b.bounds.width))") }
            }
            if let sup = v.superview, !(sup is NSClipView), !(sup is NSScrollView), depth > 0 {
                let f = v.frame, sb = sup.bounds
                if f.maxX > sb.maxX + 4.5 || f.minX < sb.minX - 4.5 { outside.append("\(type(of: v)) x \(Int(f.minX))..\(Int(f.maxX)) in \(Int(sb.width))") }
            }
            for s in v.subviews { walk(s, depth: depth + 1) }
        }
        walk(root, depth: 0)
        check(clipped.isEmpty, "layout \(name): no clipped labels or buttons \(clipped.prefix(4))")
        check(outside.isEmpty, "layout \(name): nothing sticks out sideways \(outside.prefix(4))")
    }
}

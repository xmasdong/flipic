import AppKit
import ImageIO

extension ViewerViewController {
    /// --cropratiotest <输出文件夹> <照片文件夹>：新增比例（3:4、2:3、9:16）和自定义比例走一遍。
    /// 照片文件夹里放 land.jpg（横）和 port.jpg（竖），保存只另存副本，原图不动；记住的比例放临时偏好设置。
    /// 截图（带界面语言）：比例菜单展开、自定义对话框
    func runCropRatioTest(outDir: String, folder path: String) {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path)
        func fail(_ s: String) { NSLog("CROPRATIO FAIL [%@] %@", lang, s); NSLog("CROPRATIO end [%@] failures=1", lang); NSApp.terminate(nil) }
        guard fm.fileExists(atPath: dir.appendingPathComponent("land.jpg").path), fm.fileExists(atPath: dir.appendingPathComponent("port.jpg").path) else {
            fail("need land.jpg and port.jpg in \(path)"); return
        }
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let suiteName = "com.xmasdong.cropratiotest.\(ProcessInfo.processInfo.processIdentifier)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let savedMemory = CropMemory.defaults
        CropMemory.defaults = suite
        let savedTarget = Straighten.saveTarget, savedRemind = Straighten.remindUnsaved

        var failures = 0, checks = 0
        func expect(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            NSLog("CROPRATIO %@ [%@] %@", ok ? "ok" : "FAIL", lang, what)
        }
        func shot(_ name: String) { captureWindow(to: "\(outDir)/\(lang)-\(name).png", raw: true) }
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
        func go(_ name: String) {
            if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == name }) { goTo(i) } else { expect(false, "no \(name) in folder") }
        }
        func key(_ code: UInt16, _ chars: String) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            imageView.keyDown(with: e)
        }
        func px() -> CGSize { imageView.pixelSize }
        func sizeText(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }
        func fileSize(_ url: URL) -> CGSize {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return .zero }
            return CGSize(width: p["PixelWidth"] as? Int ?? 0, height: p["PixelHeight"] as? Int ?? 0)
        }
        func listing() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") } }
        func save(copy: Bool) {
            Straighten.saveTarget = .ask
            rotationBar.onSave?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let sheet = self.view.window?.attachedSheet {
                    self.view.window?.endSheet(sheet, returnCode: copy ? .alertSecondButtonReturn : .alertFirstButtonReturn)
                }
            }
        }
        func enter() { CropMemory.forget(); self.straighten(nil) }
        /// 框在照片里、比例对（宽高各 ±1 像素）
        func ratioOK(_ size: CGSize, _ w: CGFloat, _ h: CGFloat) -> Bool {
            abs(size.width - size.height * w / h) <= 1 || abs(size.height - size.width * h / w) <= 1
        }
        let inside = { CropSelfTest.cornersInside(self.imageView.debugCropNow, image: self.imageView.debugTurnedSize, degrees: self.imageView.fineDegrees) }
        let photos: [(String, CGSize)] = [("land.jpg", CGSize(width: 1200, height: 800)), ("port.jpg", CGSize(width: 800, height: 1200))]

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 820, width: 1180, height: 800), display: true)
        }
        Straighten.saveTarget = .ask
        Straighten.remindUnsaved = true
        open(url: dir)

        // ---- 1. 菜单：顺序、写法、说明、当前项打勾
        at(1.5) {
            go("land.jpg")
        }
        at(1.0) {
            enter()
            let items = self.rotationBar.debugMenuItems
            let want = RotationBar.aspectOrder.map { $0 == .custom ? L10n.t("crop.custom", "自定义…") : RotationBar.title($0, swapped: false) }
            expect(items.count == want.count && zip(items, want).allSatisfy { $0.title.hasPrefix($1) }, "menu order \(items.map { $0.title })")
            let fixed: [CropGeometry.Aspect] = [.square, .r4x5, .r3x4, .r2x3, .r3x2, .r16x9, .r9x16]
            let hints = fixed.compactMap { RotationBar.hint($0) }
            expect(hints.count == fixed.count && Set(hints).count == fixed.count && fixed.allSatisfy { a in
                items.first { $0.title.hasPrefix(RotationBar.title(a, swapped: false)) }?.title.contains(RotationBar.hint(a) ?? "\u{0}") == true
            }, "every fixed ratio carries its own hint: \(hints)")
            expect(items.first?.checked == true && items.filter { $0.checked }.count == 1, "original ticked on entry")
        }

        // ---- 2. 新比例 × 横竖照片：框的比例、在照片里、互换、另存副本的像素尺寸
        struct Case { let aspect: CropGeometry.Aspect; let name: String; let w: CGFloat; let h: CGFloat }
        let newRatios = [Case(aspect: .r3x4, name: "3x4", w: 3, h: 4), Case(aspect: .r2x3, name: "2x3", w: 2, h: 3), Case(aspect: .r9x16, name: "9x16", w: 9, h: 16)]
        // 期望的尺寸（框是以照片里放得下的最大框）
        let expected: [String: CGSize] = [
            "land.jpg 3x4": CGSize(width: 600, height: 800), "land.jpg 2x3": CGSize(width: 533, height: 800), "land.jpg 9x16": CGSize(width: 450, height: 800),
            "port.jpg 3x4": CGSize(width: 800, height: 1067), "port.jpg 2x3": CGSize(width: 800, height: 1200), "port.jpg 9x16": CGSize(width: 675, height: 1200),
        ]
        var before = Set<String>()
        var want = CGSize.zero
        for (file, photo) in photos {
            for c in newRatios {
                at(0.8) { go(file) }
                at(0.8) {
                    enter()
                    self.rotationBar.debugSelectAspect(c.aspect)
                }
                at(0.4) {
                    let s = px()
                    let tag = "\(file) \(c.name)"
                    expect(ratioOK(s, c.w, c.h) && inside() && s.width <= photo.width && s.height <= photo.height, "\(tag): \(sizeText(s)) exact ratio, inside | \(self.rotationBar.debugCrop)")
                    if let e = expected[tag] { expect(abs(s.width - e.width) <= 1 && abs(s.height - e.height) <= 1, "\(tag): size \(sizeText(s)) want ~\(sizeText(e))") }
                    expect(self.rotationBar.debugCrop.contains("swap=1") && self.rotationBar.debugCrop.contains("aspect=\(Int(c.w)):\(Int(c.h))"), "\(tag): swap enabled, label \(self.rotationBar.debugCrop)")
                    self.rotationBar.onSwap?()
                    let t = px()
                    expect(ratioOK(t, c.h, c.w) && inside() && self.rotationBar.debugCrop.contains("aspect=\(Int(c.h)):\(Int(c.w))"), "\(tag): swapped \(sizeText(t)) is \(Int(c.h)):\(Int(c.w)) | \(self.rotationBar.debugCrop)")
                    self.rotationBar.onSwap?()
                    expect(px() == s, "\(tag): swap twice is back to \(sizeText(px()))")
                    want = px()
                    key(36, "\r")
                }
                at(0.6) {
                    // 竖照片上的 2:3 就是整张图，什么都没改：不会有「还没保存」，也没有可存的
                    let whole = want == photo
                    expect(!self.isStraightening && self.imageView.hasPendingRotation == !whole, "\(file) \(c.name): applied, pending=\(self.imageView.hasPendingRotation) whole=\(whole)")
                    before = listing()
                    if !whole { save(copy: true) }
                }
                idle {
                    let new = listing().subtracting(before)
                    let s = new.first.map { fileSize(dir.appendingPathComponent($0)) } ?? .zero
                    if want == photo { expect(new.isEmpty, "\(file) \(c.name): whole photo, nothing to save"); return }
                    expect(new.count == 1 && s == want && ratioOK(s, c.w, c.h), "\(file) \(c.name): saved copy \(new.first ?? "-") \(sizeText(s)) want \(sizeText(want))")
                    expect(fileSize(dir.appendingPathComponent(file)) == photo, "\(file) \(c.name): original untouched \(sizeText(fileSize(dir.appendingPathComponent(file))))")
                }
            }
        }
        // 已有的固定比例换个写法后还对：1:1、4:5、3:2、16:9 在两张照片上
        for (file, _) in photos {
            at(0.8) { go(file) }
            at(0.8) {
                for (a, w, h) in [(CropGeometry.Aspect.square, 1.0, 1.0), (.r4x5, 4, 5), (.r3x2, 3, 2), (.r16x9, 16, 9)] as [(CropGeometry.Aspect, CGFloat, CGFloat)] {
                    enter()
                    self.rotationBar.debugSelectAspect(a)
                    expect(ratioOK(px(), w, h) && inside(), "\(file) \(RotationBar.title(a, swapped: false)): \(sizeText(px()))")
                    self.finishStraighten(apply: false)
                }
            }
        }

        // ---- 3. 自定义：非法输入点不了、取消不改动、5:7 应用并记住
        at(0.8) { go("land.jpg") }
        at(0.8) {
            enter()
            expect(CropMemory.customWidth == 5 && CropMemory.customHeight == 7, "custom defaults to 5:7 before anything is set")
            self.rotationBar.debugSelectAspect(.custom)
        }
        at(0.6) {
            guard let alert = self.rotationBar.customAlert, let sheet = self.view.window?.attachedSheet else { expect(false, "custom: sheet did not appear"); return }
            if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(lang)-custom-sheet.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
            func fields(_ v: NSView) -> [NSTextField] { v.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] } + v.subviews.flatMap { fields($0) } }
            let all = fields(sheet.contentView!)
            guard let wf = all.first(where: { $0.accessibilityIdentifier() == "cropCustomW" }), let hf = all.first(where: { $0.accessibilityIdentifier() == "cropCustomH" }),
                  let box = wf.delegate as? CustomRatioFields else { expect(false, "custom: fields not found"); return }
            let apply = alert.buttons[0]
            expect(apply.isEnabled && wf.stringValue == "5" && hf.stringValue == "7", "custom: opens with 5 and 7, Apply enabled")
            for (w, h) in [("0", "7"), ("5", "0"), ("101", "7"), ("5", "-3"), ("abc", "7"), ("", "7"), ("5", ""), ("5.5", "7"), ("5", "1e1"), ("  ", "  ")] {
                wf.stringValue = w; hf.stringValue = h
                box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: wf))
                expect(!apply.isEnabled && box.value == nil, "custom: \"\(w)\" x \"\(h)\" cannot be confirmed")
            }
            // 点不了的按钮点了也没用，对话框还在
            apply.performClick(nil)
            expect(self.view.window?.attachedSheet != nil && CropMemory.customWidth == 5 && self.imageView.cropAspect != .custom, "custom: invalid Apply does nothing")
            for (w, h) in [("1", "100"), ("100", "1"), (" 8 ", "3")] {
                wf.stringValue = w; hf.stringValue = h
                box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: wf))
                expect(apply.isEnabled && box.value != nil, "custom: \"\(w)\" x \"\(h)\" is valid")
            }
            // 取消：比例和记住的宽高都不变
            alert.buttons[1].performClick(nil)
        }
        at(0.6) {
            expect(self.view.window?.attachedSheet == nil && self.imageView.cropAspect == .original && CropMemory.customWidth == 5 && CropMemory.customHeight == 7
                   && self.rotationBar.debugCrop.contains("aspect=\(L10n.t("crop.original", "原比例"))"), "custom: Cancel leaves ratio and memory alone | \(self.rotationBar.debugCrop)")
            self.rotationBar.debugSelectAspect(.custom)
        }
        at(0.6) {
            guard let alert = self.rotationBar.customAlert, let sheet = self.view.window?.attachedSheet else { expect(false, "custom: second sheet did not appear"); return }
            func fields(_ v: NSView) -> [NSTextField] { v.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] } + v.subviews.flatMap { fields($0) } }
            let all = fields(sheet.contentView!)
            guard let wf = all.first(where: { $0.accessibilityIdentifier() == "cropCustomW" }), let hf = all.first(where: { $0.accessibilityIdentifier() == "cropCustomH" }),
                  let box = wf.delegate as? CustomRatioFields else { expect(false, "custom: fields not found"); return }
            wf.stringValue = "5"; hf.stringValue = "7"
            box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: wf))
            expect(alert.buttons[0].isEnabled, "custom: 5 x 7 enabled")
            alert.buttons[0].performClick(nil)
        }
        at(0.6) {
            let s = px()
            expect(self.view.window?.attachedSheet == nil && self.imageView.cropAspect == .custom && ratioOK(s, 5, 7) && inside(), "custom 5:7 on land.jpg: \(sizeText(s)) | \(self.rotationBar.debugCrop)")
            expect(abs(s.width - 571) <= 1 && s.height == 800, "custom 5:7 on land.jpg: size \(sizeText(s)) want ~571x800")
            expect(self.rotationBar.debugCrop.contains("aspect=5:7") && self.rotationBar.debugCrop.contains("swap=1"), "custom: picker shows 5:7 | \(self.rotationBar.debugCrop)")
            let items = self.rotationBar.debugMenuItems
            expect(items.last?.checked == true && items.filter { $0.checked }.count == 1, "custom: ticked in the menu")
            self.rotationBar.onSwap?()
            expect(ratioOK(px(), 7, 5) && inside() && self.rotationBar.debugCrop.contains("aspect=7:5"), "custom: swap gives 7:5 \(sizeText(px())) | \(self.rotationBar.debugCrop)")
            self.rotationBar.onSwap?()
            key(36, "\r")
        }
        at(0.5) {
            expect(CropMemory.aspect == .custom && CropMemory.customWidth == 5 && CropMemory.customHeight == 7 && CropMemory.againstPhoto,
                   "memory: Return stores custom 5:7, portrait frame cut from a landscape photo (against=\(CropMemory.againstPhoto))")
            // 重新打开偏好设置（下次启动）
            CropMemory.defaults.synchronize()
            CropMemory.defaults = UserDefaults(suiteName: suiteName)!
            expect(CropMemory.aspect == .custom && CropMemory.customWidth == 5 && CropMemory.customHeight == 7 && CropMemory.againstPhoto, "memory: custom 5:7 survives re-opening the preferences")
            self.imageView.resetRotation()
        }
        // 下一张是竖照片：「相对照片转过」的框是横的 7:5
        at(0.8) { go("port.jpg") }
        at(0.8) {
            self.straighten(nil)
            expect(self.imageView.cropAspect == .custom && ratioOK(px(), 7, 5) && inside() && self.rotationBar.debugCrop.contains("aspect=7:5"),
                   "memory: against-photo custom 5:7 starts as 7:5 on a portrait photo \(sizeText(px())) | \(self.rotationBar.debugCrop)")
            self.finishStraighten(apply: false)
        }
        // 竖照片上裁竖的 5:7，再回横照片：跟着照片走，横的 7:5
        at(0.6) {
            CropMemory.forget()
            self.straighten(nil)
            CropMemory.setCustom(width: 5, height: 7)
            self.rotationBar.debugSelectAspect(.custom)
        }
        at(0.6) {
            // 对话框里点应用
            if let alert = self.rotationBar.customAlert, self.view.window?.attachedSheet != nil { alert.buttons[0].performClick(nil) } else { expect(false, "custom: sheet on portrait") }
        }
        at(0.6) {
            expect(ratioOK(px(), 5, 7) && inside(), "custom 5:7 on port.jpg: \(sizeText(px()))")
            expect(px() == CGSize(width: 800, height: 1120), "custom 5:7 on port.jpg: size \(sizeText(px())) want 800x1120")
            want = px()
            key(36, "\r")
            expect(CropMemory.aspect == .custom && !CropMemory.againstPhoto, "memory: portrait 5:7 on portrait photo is not against the photo")
        }
        at(0.6) {
            before = listing()
            save(copy: true)
        }
        idle {
            let new = listing().subtracting(before)
            let s = new.first.map { fileSize(dir.appendingPathComponent($0)) } ?? .zero
            expect(new.count == 1 && s == want && s == CGSize(width: 800, height: 1120), "custom 5:7 saved copy \(new.first ?? "-") \(sizeText(s)) want 800x1120")
            go("land.jpg")
        }
        at(0.8) {
            self.straighten(nil)
            expect(self.imageView.cropAspect == .custom && ratioOK(px(), 7, 5) && inside(), "memory: next landscape photo starts custom as 7:5 \(sizeText(px())) | \(self.rotationBar.debugCrop)")
            self.finishStraighten(apply: false)
        }
        // 新比例的「相对照片」：9:16 在横照片上裁 = 相对照片转过，下一张竖照片从 16:9 开始；在竖照片上裁则不算
        at(0.8) {
            CropMemory.forget()
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r9x16)
            key(36, "\r")
            expect(CropMemory.aspect == .r9x16 && CropMemory.againstPhoto, "memory: 9:16 cut from a landscape photo is against the photo")
            self.imageView.resetRotation()
        }
        at(0.8) { go("port.jpg") }
        at(0.8) {
            self.straighten(nil)
            expect(self.imageView.cropAspect == .r9x16 && ratioOK(px(), 16, 9) && inside(), "memory: against-photo 9:16 on a portrait photo starts as 16:9 \(sizeText(px()))")
            self.finishStraighten(apply: false)
            CropMemory.forget()
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r3x4)
            key(36, "\r")
            expect(CropMemory.aspect == .r3x4 && !CropMemory.againstPhoto, "memory: 3:4 on a portrait photo follows the photo")
            self.imageView.resetRotation()
        }
        at(0.8) { go("land.jpg") }
        at(0.8) {
            self.straighten(nil)
            expect(self.imageView.cropAspect == .r3x4 && ratioOK(px(), 4, 3) && inside(), "memory: portrait-photo 3:4 on a landscape photo starts as 4:3 \(sizeText(px()))")
            self.finishStraighten(apply: false)
        }
        // 拉直（角度）和新比例一起用：框不出照片
        at(0.8) {
            enter()
            self.rotationBar.debugSelectAspect(.r2x3)
            self.rotationBar.onDegrees?(7.3)
            expect(ratioOK(px(), 2, 3) && inside(), "straighten 7.3 deg with 2:3: \(sizeText(px()))")
            self.rotationBar.onDegrees?(-12)
            self.rotationBar.debugSelectAspect(.r9x16)
            expect(ratioOK(px(), 9, 16) && inside(), "straighten -12 deg with 9:16: \(sizeText(px()))")
            self.finishStraighten(apply: false)
        }

        // ---- 4. 截图：菜单展开（窗口号截菜单本身和整个窗口）
        at(0.8) {
            enter()
            self.rotationBar.debugSelectAspect(.r3x4)
            expect(self.imageView.crop == nil, "picker shot: setup")
        }
        at(0.5) {
            var captured = 0
            for attempt in 1...4 where captured == 0 {
                let shown = self.rotationBar.debugPopMenu { _ in
                    let pid = Int(ProcessInfo.processInfo.processIdentifier)
                    let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                    for w in infos where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) >= 101 {
                        guard let id = w[kCGWindowNumber as String] as? Int,
                              let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(id), [.bestResolution, .boundsIgnoreFraming]),
                              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(lang)-picker-menu.png") as CFURL, "public.png" as CFString, 1, nil) else { continue }
                        CGImageDestinationAddImage(dest, img, nil)
                        captured += CGImageDestinationFinalize(dest) ? 1 : 0
                    }
                }
                NSLog("CROPRATIO    [%@] picker attempt %d shown=%d captured=%d", lang, attempt, shown ? 1 : 0, captured)
            }
            expect(captured >= 1, "picker shot: menu window captured by window id (\(captured))")
        }
        at(0.5) {
            shot("picker-closed")
            self.finishStraighten(apply: false)
        }
        at(0.8) {
            Straighten.saveTarget = savedTarget
            Straighten.remindUnsaved = savedRemind
            CropMemory.defaults.removePersistentDomain(forName: suiteName)
            CropMemory.defaults = savedMemory
            NSLog("CROPRATIO end [%@] checks=%d failures=%d", lang, checks, failures)
            NSApp.terminate(nil)
        }
        runNext()
    }
}

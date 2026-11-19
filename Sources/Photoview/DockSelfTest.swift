import AppKit

/// `Flipic --docktest <工作文件夹> <照片文件夹>`：照片信息贴边、照片铺满窗口两项设置的截图和检查。
/// 照片文件夹里放一张横的、一张竖的（按文件名排，横的在前）。窗口放到屏幕可用区域那么大，逐步截图到工作文件夹，
/// 每步打印 DOCK 行，最后一行 DOCK summary checks=N failures=M
extension ViewerViewController {
    func runDockTest(outDir: String, folderPath: String) {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "infoPanelDocked"), d.object(forKey: "fitFills"))
        d.removeObject(forKey: "infoPanelDocked")
        d.removeObject(forKey: "fitFills")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        open(url: URL(fileURLWithPath: folderPath))
        guard let w = view.window, let screen = w.screen ?? NSScreen.main else { exit(1) }
        w.setFrame(screen.visibleFrame, display: true)

        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("DOCK \(ok ? "PASS" : "FAIL") \(what)")
        }
        func r(_ f: NSRect) -> String { "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))" }
        /// 照片在照片区里的位置（照片区自己的坐标）
        func photoRect() -> NSRect { imageView.imageFrame }
        func shot(_ name: String) {
            view.layoutSubtreeIfNeeded()
            captureWindow(to: "\(outDir)/\(name).png", raw: true)
            let file = folder.current?.url.lastPathComponent ?? "-"
            print("DOCK shot \(name) file=\(file) window=\(Int(w.frame.width))x\(Int(w.frame.height)) image=\(r(imageView.frame)) photo=\(r(photoRect())) panel=\(exifPanel.isHidden ? "hidden" : r(exifPanel.frame)) docked=\(infoDocked) fit=\(imageView.isFit)")
        }
        func checkDocked(_ tag: String) {
            check(infoDocked && !exifPanel.isHidden, "\(tag): panel docked")
            check(!imageView.frame.insetBy(dx: 0.5, dy: 0.5).intersects(exifPanel.frame),
                  "\(tag): image area \(r(imageView.frame)) does not overlap panel \(r(exifPanel.frame))")
            check(abs(exifPanel.frame.maxX - view.bounds.maxX) < 0.5 && abs(exifPanel.frame.maxY - view.bounds.maxY) < 0.5,
                  "\(tag): panel flush with right and top edge")
            check(abs(exifPanel.frame.minY - filmstrip.frame.maxY) < 0.5, "\(tag): panel reaches down to the filmstrip")
            for (name, c) in [("next arrow", nextArrowContainerForTest), ("toolbar", toolbarForTest)] where c.alphaValue > 0 && !c.isHidden {
                check(!c.frame.intersects(exifPanel.frame), "\(tag): \(name) \(r(c.frame)) clear of panel")
            }
        }
        func checkInside(_ tag: String) {
            check(imageView.bounds.insetBy(dx: -1, dy: -1).contains(photoRect()),
                  "\(tag): photo \(r(photoRect())) inside image area \(r(imageView.bounds))")
        }
        /// 铺满按长边：横图宽度正好铺满，竖图高度正好铺满（两边留边，不裁）
        func checkCovers(_ tag: String) {
            let p = photoRect(), b = imageView.bounds
            if p.width >= p.height {
                check(abs(p.width - b.width) <= 1.5, "\(tag): landscape width fills \(r(p)) in \(r(b))")
            } else {
                check(abs(p.height - b.height) <= 1.5 && p.width <= b.width + 1, "\(tag): portrait height fills, sides not cropped \(r(p)) in \(r(b))")
            }
            check(imageView.isFit, "\(tag): fill counts as fit")
        }
        func notify(_ what: String) { SettingsWindowController.notify(what) }

        var steps: [(Double, () -> Void)] = []
        var t = 2.5
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; steps.append((t, f)) }

        at(0) {
            self.pokeControls()
            shot("01-hidden-landscape")
            check(!self.infoDocked && abs(self.imageView.frame.width - self.view.bounds.width) < 0.5, "hidden: image area full width")
            checkInside("hidden landscape")
        }
        at(0.3) { self.toggleInfoPanel(nil) }
        at(1.5) {
            self.pokeControls()
            shot("02-docked-landscape")
            checkDocked("docked landscape")
            checkInside("docked landscape")
            let p = photoRect()
            check(abs(p.midX - self.imageView.bounds.midX) < 1 && abs(p.midY - self.imageView.bounds.midY) < 1, "docked landscape: photo centred in image area")
            check(abs(p.width - self.imageView.bounds.width) < 1 || abs(p.height - self.imageView.bounds.height) < 1, "docked landscape: photo re-fitted to new width")
        }
        at(0.2) { self.navigateForward(nil) }
        at(2.0) {
            self.pokeControls()
            shot("03-docked-portrait")
            checkDocked("docked portrait")
            checkInside("docked portrait")
        }
        at(0.2) {
            ViewerViewController.infoPanelDocked = false
            notify("infoDock")
        }
        at(1.0) {
            self.pokeControls()
            shot("04-floating-portrait")
            check(!self.infoDocked && !self.exifPanel.isHidden, "floating: panel open, not docked")
            check(abs(self.imageView.frame.width - self.view.bounds.width) < 0.5, "floating: image area full width")
            check(abs(self.exifPanel.frame.maxX - (self.view.bounds.maxX - 12)) < 0.5 && abs(self.exifPanel.frame.maxY - (self.view.bounds.maxY - 46)) < 0.5,
                  "floating: panel back at the old card position \(r(self.exifPanel.frame))")
            checkInside("floating portrait")
        }
        at(0.2) {
            ViewerViewController.infoPanelDocked = true
            notify("infoDock")
            self.toggleInfoPanel(nil)
            ZoomableImageView.fitFills = true
            notify("fitFills")
        }
        at(1.0) {
            self.pokeControls()
            shot("05-fill-portrait")
            checkCovers("fill portrait")
        }
        at(0.2) { self.navigateBackward(nil) }
        at(2.0) {
            self.pokeControls()
            shot("06-fill-landscape")
            checkCovers("fill landscape")
        }
        at(0.2) { self.toggleInfoPanel(nil) }
        at(1.5) {
            self.pokeControls()
            shot("07-fill-docked-landscape")
            checkDocked("fill docked landscape")
            checkCovers("fill docked landscape")
        }
        at(0.2) { self.navigateForward(nil) }
        at(2.0) {
            self.pokeControls()
            shot("08-fill-docked-portrait")
            checkDocked("fill docked portrait")
            checkCovers("fill docked portrait")
        }
        // 铺满时双击（0 键）还是在适应窗口和 100% 之间切换
        at(0.2) { self.imageView.toggleFitActual(at: nil) }
        at(0.6) { check(!self.imageView.isFit, "fill: toggle goes to actual size") }
        at(0.1) { self.imageView.toggleFitActual(at: nil) }
        at(0.6) {
            check(self.imageView.isFit, "fill: toggle comes back to fill")
            checkCovers("fill after toggle")
        }
        at(0.2) {
            ZoomableImageView.fitFills = false
            notify("fitFills")
            self.navigateBackward(nil)
        }
        at(2.0) { self.toggleCompare(nil) }
        at(2.5) {
            shot("09-compare-docked")
            if let cv = self.compareView {
                check(!cv.frame.insetBy(dx: 0.5, dy: 0.5).intersects(self.exifPanel.frame), "compare: panes \(r(cv.frame)) beside the docked panel")
                for (i, p) in cv.panes.enumerated() {
                    let iv = p.imageView
                    check(iv.bounds.insetBy(dx: -1, dy: -1).contains(iv.imageFrame), "compare pane \(i): photo \(r(iv.imageFrame)) aspect-fit inside \(r(iv.bounds))")
                }
            } else {
                check(false, "compare: opened")
            }
        }
        at(0.2) { self.exitCompare() }
        // 放大着开关面板：画面中心看的还是照片上同一处
        at(1.0) { self.imageView.zoomActual(centeredOn: CGPoint(x: 0.3, y: 0.4), animated: false) }
        var before = CGPoint.zero
        at(0.6) {
            before = self.imageView.viewState.center
            self.toggleInfoPanel(nil)
        }
        at(0.8) {
            let after = self.imageView.viewState.center
            check(abs(after.x - before.x) < 0.01 && abs(after.y - before.y) < 0.01 && !self.imageView.isFit,
                  "zoomed: hiding panel keeps the same centre (\(String(format: "%.3f,%.3f → %.3f,%.3f", before.x, before.y, after.x, after.y)))")
            before = after
            self.toggleInfoPanel(nil)
        }
        at(0.8) {
            let after = self.imageView.viewState.center
            check(abs(after.x - before.x) < 0.01 && abs(after.y - before.y) < 0.01,
                  "zoomed: showing panel keeps the same centre (\(String(format: "%.3f,%.3f → %.3f,%.3f", before.x, before.y, after.x, after.y)))")
            self.pokeControls()
            shot("10-zoomed-docked")
            self.imageView.fit()
        }
        // 窗口太窄：改回浮动；再拉宽贴回去
        at(0.3) {
            var f = w.frame
            f.size.width = max(w.minSize.width, 600)
            w.setFrame(f, display: true)
        }
        at(1.0) {
            self.pokeControls()
            shot("11-narrow-floating")
            check(!self.infoDocked && !self.exifPanel.isHidden, "narrow (\(Int(self.view.bounds.width)) pt): panel floats")
            checkInside("narrow")
            w.setFrame(screen.visibleFrame, display: true)
        }
        at(1.0) {
            checkDocked("wide again")
            checkInside("wide again")
        }
        at(0.3) {
            print("DOCK summary checks=\(checks) failures=\(failures)")
            if let v = saved.0 { d.set(v, forKey: "infoPanelDocked") } else { d.removeObject(forKey: "infoPanelDocked") }
            if let v = saved.1 { d.set(v, forKey: "fitFills") } else { d.removeObject(forKey: "fitFills") }
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        for (dt, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: f) }
    }
}

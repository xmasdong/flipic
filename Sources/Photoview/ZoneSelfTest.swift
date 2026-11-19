import AppKit

/// `Flipic --zonetest <工作文件夹>`：看照片时控件按区域出现的自测。
/// 生成 3 张 JPEG 打开，用和真鼠标同一个入口（pointerMoved）喂假的鼠标位置，再按键翻页、评分，
/// 每步看哪几组控件露出来；中间、底部、顶部各截一张图。最后一行 ZONE summary checks=N failures=M
extension ViewerViewController {
    func runZoneTest(outDir: String) {
        let d = UserDefaults.standard
        let savedMode = d.object(forKey: "toolbarMode"), savedHidden = d.object(forKey: "toolbarHidden")
        let savedFileName = d.object(forKey: "showFileName")
        d.removeObject(forKey: "toolbarMode")
        d.removeObject(forKey: "toolbarHidden")
        d.removeObject(forKey: "showFileName")
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: outDir).appendingPathComponent("photos")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, (a, b)) in [(NSColor.systemTeal, NSColor.systemIndigo), (.systemOrange, .systemBrown), (.systemGreen, .systemGray)].enumerated() {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1200, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGradient(starting: a, ending: b)?.draw(in: NSRect(x: 0, y: 0, width: 1800, height: 1200), angle: 60)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])?
                .write(to: dir.appendingPathComponent(String(format: "zone_%02d.jpg", i + 1)))
        }

        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("ZONE \(ok ? "PASS" : "FAIL") \(what)")
        }
        func visible(_ v: NSView) -> Bool { !v.isHidden && v.alphaValue > 0.5 }
        func groupVisible(_ z: ControlZone) -> Bool { zoneViewsForTest(z).contains(where: visible) }
        func state() -> String {
            ControlZone.allCases.map { "\($0)=\(groupVisible($0) ? 1 : 0)" }.joined(separator: " ")
        }
        /// 只有这几组露出来
        func expect(_ want: Set<ControlZone>, _ what: String) {
            let got = Set(ControlZone.allCases.filter(groupVisible))
            check(got == want, "\(what): \(state())")
        }
        let area = { self.imageView.frame }
        func pt(_ name: String) -> CGPoint {
            let a = area()
            switch name {
            case "bottom": return CGPoint(x: a.midX, y: a.minY + 100)
            case "top": return CGPoint(x: a.midX, y: a.maxY - 30)
            case "left": return CGPoint(x: a.minX + 30, y: a.midY)
            case "right": return CGPoint(x: a.maxX - 30, y: a.midY)
            default: return CGPoint(x: a.midX, y: a.midY)
            }
        }
        func move(_ name: String) { pointerMoved(to: pt(name)) }
        func key(_ chars: String, _ code: UInt16) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            imageView.keyDown(with: e)
        }
        func keyboardBurst() {
            key(String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!)), 124)   // →
            key("3", 20)                                                // 评 3 星
            navigateForward(nil)
            setRating(2)
            navigateBackward(nil)
        }
        func shot(_ name: String) {
            view.layoutSubtreeIfNeeded()
            captureWindow(to: "\(outDir)/\(name).png", raw: true)
            print("ZONE shot \(outDir)/\(name).png \(state())")
        }
        func mode(_ m: ToolbarMode) {
            ViewerViewController.toolbarMode = m
            SettingsWindowController.notify("toolbar")
        }

        var steps: [(Double, () -> Void)] = []
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; steps.append((t, f)) }

        open(url: dir)
        at(2.0) {
            if let w = self.view.window, let s = w.screen ?? NSScreen.main {
                w.setFrame(NSRect(x: s.visibleFrame.minX + 40, y: s.visibleFrame.minY + 40, width: 1100, height: 760), display: true)
            }
            check(ViewerViewController.toolbarMode == .edges, "default mode is edges")
            check(self.folder.count == 3, "opened 3 photos (count=\(self.folder.count))")
            self.setControlsVisible(false)
        }
        // 1 鼠标在中间，按键翻页、评分：什么都不出来
        at(0.8) { move("middle"); keyboardBurst() }
        at(0.7) { expect([], "keyboard paging/rating with pointer in middle") }
        // 2 鼠标在中间移动：什么都不出来
        at(0.1) { move("middle") }
        at(0.6) { expect([], "pointer moves in middle"); shot("zone-middle") }
        // 3 到底部：只出工具条
        at(0.2) { move("bottom") }
        at(0.6) { expect([.bottom], "pointer in bottom zone"); shot("zone-bottom") }
        // 底部区域里按键：工具条还在，别的不出来
        at(0.1) { keyboardBurst() }
        at(0.5) { expect([.bottom], "keyboard while toolbar shown changes nothing") }
        // 4 离开底部：0.6 秒时还在，约 1 秒后收起
        at(0.1) { move("middle") }
        at(0.6) { expect([.bottom], "0.6 s after leaving bottom zone, still shown") }
        at(1.0) { expect([], "1.6 s after leaving bottom zone, hidden") }
        // 5 到顶部：只出右上角按钮和文件名
        at(0.2) { move("top") }
        at(0.6) {
            expect([.top], "pointer in top zone")
            let top = self.zoneViewsForTest(.top)
            check(top.allSatisfy(visible), "top zone shows both corner buttons and file name")
            shot("zone-top")
        }
        // 6 左边、右边：各出一边的箭头
        at(0.1) { move("left") }
        at(1.6) { expect([.left], "pointer at left edge (top bar gone 1 s after leaving)") }
        at(0.1) { move("right") }
        at(1.6) { expect([.right], "pointer at right edge") }
        // 7 在底部区域停着不动 3 秒收起；指着工具条本身不收
        at(0.1) { move("bottom") }
        at(3.6) { expect([], "3 s without movement in bottom zone (not over toolbar), hidden") }
        at(0.1) {
            let tb = self.toolbarForTest.frame
            self.pointerMoved(to: CGPoint(x: tb.midX, y: tb.midY))
        }
        at(3.6) { expect([.bottom], "pointer resting on the toolbar keeps it after 3 s") }
        at(0.1) { move("middle") }
        at(1.6) { expect([], "left the toolbar, hidden") }
        // 8 滚轮 / 触控板不算移进区域
        at(0.1) {
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 30, wheel3: 0),
               let e = NSEvent(cgEvent: cg) {
                self.imageView.scrollWheel(with: e)
            }
        }
        at(0.6) { expect([], "horizontal scroll does not reveal"); self.imageView.fit() }
        // 9 「移动鼠标就显示」：中间一动全出来；按键仍然不出来
        at(0.3) { mode(.mouseMove); self.setControlsVisible(false) }
        at(0.3) { move("middle") }
        at(0.6) { expect(Set(ControlZone.allCases), "mouseMove mode: middle move shows all") }
        at(0.1) { self.setControlsVisible(false) }
        at(0.6) { keyboardBurst() }
        at(0.7) { expect([], "mouseMove mode: keyboard shows none") }
        // 10 「不显示」：底部没有工具条；顶部只有文件名；箭头照旧
        at(0.3) { mode(.never); self.setControlsVisible(false) }
        at(0.3) { move("bottom") }
        at(0.6) { expect([], "never mode: bottom zone shows no toolbar") }
        at(0.1) { move("top") }
        at(0.6) {
            let top = self.zoneViewsForTest(.top)
            check(!visible(top[0]) && visible(top[1]), "never mode: top zone shows file name only (corner=\(visible(top[0]) ? 1 : 0) name=\(visible(top[1]) ? 1 : 0))")
        }
        at(0.1) { move("left") }
        at(1.6) { check(groupVisible(.left), "never mode: left arrow still appears") }
        at(0.3) {
            if let v = savedMode { d.set(v, forKey: "toolbarMode") } else { d.removeObject(forKey: "toolbarMode") }
            if let v = savedHidden { d.set(v, forKey: "toolbarHidden") } else { d.removeObject(forKey: "toolbarHidden") }
            if let v = savedFileName { d.set(v, forKey: "showFileName") } else { d.removeObject(forKey: "showFileName") }
            print("ZONE summary checks=\(checks) failures=\(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        for (dt, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: f) }
    }
}

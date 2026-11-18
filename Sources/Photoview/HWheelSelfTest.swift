import AppKit

/// `Flipic --hwheeltest <工作文件夹>`：鼠标横向滚轮 / 侧键翻页自测。最后一行 HWHEEL summary
extension ViewerViewController {
    func runHWheelTest(outDir: String) {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("HWHEEL \(ok ? "ok  " : "FAIL") \(what)")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("hwheel")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        func writeJPEG(_ url: URL, _ color: NSColor) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill(); NSRect(x: 0, y: 0, width: 320, height: 240).fill()
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .jpeg, properties: [:])?.write(to: url)
        }
        let urls = ["a", "b", "c"].map { root.appendingPathComponent("\($0).jpg") }
        for (u, c) in zip(urls, [NSColor.systemRed, .systemGreen, .systemBlue]) { writeJPEG(u, c) }

        let ud = UserDefaults.standard
        let savedKeys = ["hWheelNavigates", "wheelNavigates", "wheelNavInverted"]
        let saved = savedKeys.map { ud.object(forKey: $0) }
        func finish() {
            for (k, v) in zip(savedKeys, saved) { if let v = v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } }
            print("HWHEEL summary checks=\(checks) failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }

        func hwheel(_ dx: Int32) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0),
                  let e = NSEvent(cgEvent: cg) else { check(false, "合成横向滚轮事件失败"); return }
            imageView.scrollWheel(with: e)
        }
        func vwheel(_ dy: Int32) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0),
                  let e = NSEvent(cgEvent: cg) else { check(false, "合成纵向滚轮事件失败"); return }
            imageView.scrollWheel(with: e)
        }
        func side(_ n: Int) {
            guard let button = CGMouseButton(rawValue: UInt32(n)),
                  let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: button),
                  let e = NSEvent(cgEvent: cg) else { check(false, "合成侧键事件失败"); return }
            check(e.buttonNumber == n, "合成的侧键 buttonNumber=\(e.buttonNumber) 期望 \(n)")
            imageView.otherMouseDown(with: e)
        }
        func name() -> String { folder.current?.url.lastPathComponent ?? "-" }

        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

        ud.set(false, forKey: "wheelNavigates")
        ud.set(false, forKey: "wheelNavInverted")
        ud.removeObject(forKey: "hWheelNavigates")
        open(url: urls[0])
        at(1.5) { check(name() == "a.jpg", "打开后显示 a.jpg（实际 \(name())）") ; check(ZoomableImageView.hWheelNavigates, "横向滚动默认切换照片") }
        at(0.3) { hwheel(-1) }
        at(0.5) { check(name() == "b.jpg", "横向滚轮向左一格 -> 下一张（实际 \(name())）") }
        at(0.3) { hwheel(-1) }
        at(0.5) { check(name() == "c.jpg", "再向左一格 -> c.jpg（实际 \(name())）") }
        at(0.3) { hwheel(1) }
        at(0.5) { check(name() == "b.jpg", "横向滚轮向右一格 -> 上一张（实际 \(name())）") }
        at(0.3) { ZoomableImageView.wheelNavInverted = true; hwheel(-1) }
        at(0.5) { check(name() == "a.jpg", "反转翻页方向后，向左一格 -> 上一张（实际 \(name())）"); ZoomableImageView.wheelNavInverted = false }
        // 设成「左右移动图片」：适应窗口时不动
        at(0.3) { ZoomableImageView.hWheelNavigates = false; self.imageView.fit() }
        at(0.3) { hwheel(-1) }
        at(0.5) { check(name() == "a.jpg", "设成移动图片、适应窗口时横向滚轮不翻页（实际 \(name())）"); ZoomableImageView.hWheelNavigates = true }
        // 侧键
        at(0.3) { side(4) }
        at(0.5) { check(name() == "b.jpg", "侧键 4（前进）-> 下一张（实际 \(name())）") }
        at(0.3) { side(3) }
        at(0.5) { check(name() == "a.jpg", "侧键 3（后退）-> 上一张（实际 \(name())）") }
        // 纵向滚轮不受影响：默认缩放
        var before = ""
        at(0.3) { before = self.imageView.fitDiagnostics; vwheel(1) }
        at(0.5) {
            check(self.imageView.fitDiagnostics != before, "纵向滚轮仍缩放（\(before) -> \(self.imageView.fitDiagnostics)）")
            check(name() == "a.jpg", "纵向滚轮没翻照片（实际 \(name())）")
        }
        at(0.3) { finish() }
    }
}

import AppKit

/// `Flipic --keyclosetest <工作文件夹>`：⌘W、⌃Z、⌘Z 落下后窗口去哪了。
/// 分别模拟从访达打开单张照片、打开整个文件夹两种情况，按键走菜单快捷键（⌘ 组合）或窗口（其余）这条真实分发路径，
/// 每步打印看图窗口个数、是否显示开始页、当前照片、进程是否还在。最后一行 KEYCLOSE summary
extension AppDelegate {
    func runKeyCloseTest(outDir: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("photos")
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
        let a = root.appendingPathComponent("a.jpg")
        writeJPEG(a, .systemRed)
        writeJPEG(root.appendingPathComponent("b.jpg"), .systemBlue)

        func viewers() -> [ViewerViewController] {
            NSApp.windows.filter { $0.isVisible }.compactMap { $0.contentViewController as? ViewerViewController }
        }
        func state(_ tag: String) {
            let v = viewers()
            let desc = v.map { "[\($0.folder.current?.url.lastPathComponent ?? "-") start=\(!$0.emptyState.isHidden)]" }.joined()
            print("KEYCLOSE \(tag): windows=\(v.count) \(desc)")
            if let w = v.first?.view.window, let sc = w.screen ?? NSScreen.main {
                let vf = sc.visibleFrame
                print(String(format: "KEYCLOSE   center dx=%.1f dy=%.1f (window %.0fx%.0f)", w.frame.midX - vf.midX, w.frame.midY - vf.midY, w.frame.width, w.frame.height))
            }
        }
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) {
            guard let w = viewers().first?.view.window else { print("KEYCLOSE   (no window to send to)"); return }
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            // ⌘W 就是菜单「关闭窗口」的动作，直接调；其余按键交给窗口当前的第一响应者（测试进程不在前台，菜单快捷键不分发）
            if code == 13, mods == .command { viewers().first?.closePhotosOrWindow(nil); return }
            w.sendEvent(e)
        }
        func closeAll() { for v in viewers() { v.view.window?.close() } }

        var steps: [(Double, () -> Void)] = []
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; steps.append((t, f)) }

        // 1. 从访达打开单张
        at(0.2) { self.application(NSApp, open: [a]) }
        at(1.5) { state("1 opened file from Finder") }
        at(0.1) { key("w", 13, .command) }
        at(1.0) { state("1a after ⌘W") }
        at(0.1) { closeAll() }
        // 2. 从访达打开单张，按 ⌃Z
        at(0.5) { self.application(NSApp, open: [a]) }
        at(1.5) { state("2 opened file from Finder") }
        at(0.1) { key("\u{1A}", 6, .control) }
        at(1.0) { state("2a after ⌃Z") }
        at(0.1) { key("z", 6, .command) }
        at(1.0) { state("2b after ⌘Z") }
        at(0.1) { closeAll() }
        // 3. 打开整个文件夹
        at(0.5) { self.application(NSApp, open: [root]) }
        at(1.5) { state("3 opened folder") }
        at(0.1) { key("\u{1A}", 6, .control) }
        at(1.0) { state("3a after ⌃Z") }
        at(0.1) { key("w", 13, .command) }
        at(1.0) { state("3b after ⌘W") }
        at(0.1) { key("w", 13, .command) }
        at(1.0) { state("3c after second ⌘W") }
        at(0.5) {
            print("KEYCLOSE summary done keepRunning=\(AppDelegate.keepRunning)")
            exit(0)
        }
        for (dt, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: f) }
    }
}


/// `Flipic --fillshot <工作文件夹> <照片文件夹>`：窗口放到屏幕可用区域那么大，逐张翻页截图，看照片四周有没有黑边。FILLSHOT done
extension ViewerViewController {
    func runFillShot(outDir: String, folderPath: String) {
        open(url: URL(fileURLWithPath: folderPath))
        guard let w = view.window, let screen = w.screen ?? NSScreen.main else { exit(1) }
        // FILLMODE=zoom：点绿灯旁「缩放」那样最大化；fullscreen：进全屏；默认直接设成屏幕可用区域大小
        switch ProcessInfo.processInfo.environment["FILLMODE"] {
        case "zoom": w.zoom(nil)
        case "fullscreen": w.toggleFullScreen(nil)
        default: w.setFrame(screen.visibleFrame, display: true)
        }
        var n = 0
        func shoot() {
            n += 1
            let name = folder.current?.url.lastPathComponent ?? "-"
            captureWindow(to: "\(outDir)/\(n)-\(name).png", raw: true)
            let m = imageView.debugImageTransform
            print("FILLSHOT \(n) \(name) window=\(Int(w.frame.width))x\(Int(w.frame.height)) full=\(w.styleMask.contains(.fullScreen)) view=\(Int(imageView.bounds.width))x\(Int(imageView.bounds.height)) fit=\(imageView.isFit) scaleX=\(String(format: "%.3f", m.a)) layer=\(imageView.debugImageFrame)")
            if n < min(folder.count, 4) {
                navigateForward(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { shoot() }
            } else { print("FILLSHOT done"); exit(0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { shoot() }
    }
}

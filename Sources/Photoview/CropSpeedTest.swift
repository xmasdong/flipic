import AppKit
import ImageIO

extension ViewerViewController {
    /// --cropspeedtest <工作文件夹> <照片文件夹>：照片文件夹里每张照片（a-dummy 之外）裁成 4:5、按「覆盖原图」存 3 遍，
    /// 量「点了覆盖」到「裁好的照片在屏幕上、界面能响应」的时间，以及主线程被卡住多久。每遍之前从 工作文件夹/pristine 还原
    func runCropSpeedTest(outDir: String, folder path: String) {
        let savedTarget = Straighten.saveTarget
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path), pristine = URL(fileURLWithPath: outDir).appendingPathComponent("pristine")
        try? fm.createDirectory(at: pristine, withIntermediateDirectories: true)
        let names = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("a-dummy") }.sorted()
        for n in names { try? fm.removeItem(at: pristine.appendingPathComponent(n)); try? fm.copyItem(at: dir.appendingPathComponent(n), to: pristine.appendingPathComponent(n)) }
        let runs = Int(ProcessInfo.processInfo.environment["CROPSPEED_RUNS"] ?? "") ?? 3
        var results: [String: [[String: Double]]] = [:]
        var stages: [String: Double] = [:]
        let lock = NSLock()
        Straighten.profile = { name, dt in
            lock.lock(); defer { lock.unlock() }
            stages[name] = (name == "file.done" || name.hasPrefix("at.")) ? CFAbsoluteTimeGetCurrent() : (stages[name] ?? 0) + dt
        }
        func go(_ name: String) {
            if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == name }) { goTo(i) }
        }
        func fileSize(_ name: String) -> CGSize {
            guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return .zero }
            return CGSize(width: p["PixelWidth"] as? Int ?? 0, height: p["PixelHeight"] as? Int ?? 0)
        }
        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 820, width: 1180, height: 800), display: true)
        }
        Straighten.saveTarget = .ask
        Straighten.remindUnsaved = false
        open(url: dir)

        var jobs: [(String, Int)] = []
        for n in names { for r in 1...runs { jobs.append((n, r)) } }
        func after(_ dt: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: f) }

        func finishAll() {
            func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            for n in names {
                guard let rs = results[n], !rs.isEmpty else { continue }
                let keys = ["sheet", "screen", "sharp", "file", "ready", "mainMax", "mainStall"] + rs[0].keys.filter { $0.hasPrefix("s.") || $0.hasPrefix("at.") }.sorted()
                let cols = keys.map { k in String(format: "%@=%.0f", k, median(rs.map { $0[k] ?? 0 }) * 1000) }
                NSLog("CROPSPEED median %@ (ms, n=%d) %@", n, rs.count, cols.joined(separator: " "))
            }
            Straighten.profile = nil
            Straighten.saveTarget = savedTarget
            NSApp.terminate(nil)
        }

        func runJob(_ i: Int) {
            guard i < jobs.count else { finishAll(); return }
            let (name, run) = jobs[i]
            let url = dir.appendingPathComponent(name)
            // 还原 → 先翻走再翻回来，保证是干净载入的状态
            try? fm.removeItem(at: url)
            try? fm.copyItem(at: pristine.appendingPathComponent(name), to: url)
            after(1.5) {
                go("a-dummy.jpg")
                after(0.6) {
                    go(name)
                    after(3.5) {
                        self.straighten(nil)
                        self.rotationBar.debugSelectAspect(.r4x5)
                        self.finishStraighten(apply: true)
                        after(0.6) {
                            let want = self.imageView.pixelSize
                            Straighten.saveTarget = .ask
                            self.rotationBar.onSave?()
                            after(0.5) {
                                guard let sheet = self.view.window?.attachedSheet else { NSLog("CROPSPEED FAIL no sheet for %@", name); runJob(i + 1); return }
                                lock.lock(); stages = [:]; lock.unlock()
                                let t0 = CFAbsoluteTimeGetCurrent()
                                var last = t0, maxGap = 0.0, stall = 0.0
                                var started = false, tScreen = 0.0, tSharp = 0.0, tReady = 0.0, tSheet = 0.0, blank = false
                                var done = false
                                var segments: [String] = []
                                let timer = Timer(timeInterval: 0.001, repeats: true) { t in
                                    let now = CFAbsoluteTimeGetCurrent()
                                    let sz = self.imageView.pixelSize
                                    let gap = now - last
                                    last = now
                                    maxGap = max(maxGap, gap)
                                    if tSheet == 0 { tSheet = now - t0 }
                                    if gap > 0.016 { stall += gap; segments.append(String(format: "%.0f+%.0f", (now - gap - t0) * 1000, gap * 1000)) }
                                    if self.isProcessing { started = true }
                                    if started, sz == .zero { blank = true }
                                    lock.lock(); let fileAt = stages["file.done"]; lock.unlock()
                                    // 裁好的照片已经在屏幕上：没有待保存的修改、尺寸是裁好的、清晰图
                                    let final = !self.imageView.hasPendingRotation && sz == want
                                    if tScreen == 0, started || fileAt != nil, final { tScreen = now - t0 }
                                    if tSharp == 0, tScreen > 0, final, self.debugShownSharp { tSharp = now - t0 }
                                    if tReady == 0, tSharp > 0, fileAt != nil, !self.isProcessing { tReady = now - t0 }
                                    if tReady > 0, now - t0 > tReady + 1.3, !done {
                                        done = true
                                        t.invalidate()
                                        var r: [String: Double] = ["screen": tScreen, "file": (fileAt ?? now) - t0, "ready": tReady, "sharp": tSharp, "sheet": tSheet, "mainMax": maxGap, "mainStall": stall]
                                        lock.lock(); for (k, v) in stages where k != "file.done" { r[k.hasPrefix("at.") ? k : "s.\(k)"] = k.hasPrefix("at.") ? v - t0 : v }; lock.unlock()
                                        results[name, default: []].append(r)
                                        let st = r.keys.sorted().map { String(format: "%@=%.0f", $0, r[$0]! * 1000) }.joined(separator: " ")
                                        NSLog("CROPSPEED %@ run=%d blank=%d size=%@ %@ stalls(start+len ms)=[%@]", name, run, blank ? 1 : 0, "\(Int(fileSize(name).width))x\(Int(fileSize(name).height))", st, segments.joined(separator: " "))
                                        after(0.3) { runJob(i + 1) }
                                    } else if !done, now - t0 > 15 {
                                        done = true; t.invalidate(); NSLog("CROPSPEED FAIL timeout %@ started=%d screen=%f ready=%f pending=%d size=%@ want=%@ processing=%d sharp=%d cur=%@ crop=%d deg=%f turns=%d file=%@", name, started ? 1 : 0, tScreen, tReady, self.imageView.hasPendingRotation ? 1 : 0, NSStringFromSize(sz), NSStringFromSize(want), self.isProcessing ? 1 : 0, self.debugShownSharp ? 1 : 0, self.folder.current?.url.lastPathComponent ?? "-", self.imageView.crop != nil ? 1 : 0, self.imageView.fineDegrees, self.imageView.rotationTurns, "\(Int(fileSize(name).width))x\(Int(fileSize(name).height))")
                                        runJob(i + 1)
                                    }
                                }
                                RunLoop.main.add(timer, forMode: .common)
                                self.view.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                            }
                        }
                    }
                }
            }
        }
        // a-dummy.jpg 不在照片文件夹时补一张小的，翻走用
        after(1.5) { runJob(0) }
    }
}

extension ViewerViewController {
    /// --cropquittest <照片文件夹>：5400 万像素的 big.jpg 裁成 4:5 覆盖保存，写盘期间马上退出（⌘Q 一样走 NSApp.terminate）。
    /// 应该等写完才退出：big.jpg 是完整的 4800×6000，文件夹里没有留下临时文件。结果由外面的脚本检查
    func runCropQuitTest(folder path: String) {
        let dir = URL(fileURLWithPath: path)
        let bigW = 9000, bigH = 6000
        guard let grid = CropSelfTest.makeGrid(),
              let ctx = CGContext(data: nil, width: bigW, height: bigH, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { NSApp.terminate(nil); return }
        ctx.interpolationQuality = .none
        ctx.draw(grid, in: CGRect(x: 0, y: 0, width: bigW, height: bigH))
        if let big = ctx.makeImage() { CropSelfTest.write(big, to: dir.appendingPathComponent("big.jpg"), type: .jpeg) }
        open(url: dir)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r4x5)
            self.finishStraighten(apply: true)
            guard let url = self.folder.current?.url else { NSLog("QUITTEST FAIL no photo"); NSApp.terminate(nil); return }
            self.performRotationSave(url: url, turns: 0, degrees: 0, crop: self.imageView.cropSpec, overwrite: true, then: nil)
            NSLog("QUITTEST terminate requested, save running=%d", Straighten.hasActiveSave ? 1 : 0)
            // 定时器回调里退出（和菜单 ⌘Q 一样在事件循环里，不在主队列的块里：块里等的话，写完后回主队列的块要等这个块返回才能跑）
            Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { _ in
                NSLog("QUITTEST calling terminate, save running=%d", Straighten.hasActiveSave ? 1 : 0)
                NSApp.terminate(nil)
            }
        }
    }
}

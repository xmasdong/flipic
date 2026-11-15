import AppKit
import ImageIO
import UniformTypeIdentifiers

/// --peektest 之外的翻页回归：--peekpagingtest <工作文件夹>
/// 在贴合预览里横图竖图来回翻 20 次，每次等窗口动画停稳后记录窗口内容尺寸和照片显示尺寸，
/// 同一张照片每次回来窗口尺寸必须一样、照片必须贴合窗口。最后一行 PEEKTEST checks=N failures=M
extension ViewerViewController {
    static func makePeekPagingPhotos(workDir: String) {
        let dir = URL(fileURLWithPath: workDir).appendingPathComponent("photos")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int, Int)] = [("01-land", 6000, 4000), ("02-port", 4000, 6000), ("03-land", 1200, 800),
                                          ("04-port", 800, 1200), ("05-square", 1000, 1000)]
        for (n, w, h) in specs {
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w / 4, height: h / 4))   // 左下角橙色块，认方向
            guard let img = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(n + ".jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    func runPeekPagingTest(workDir: String) {
        guard let window = view.window else { return }
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
            checks += 1
            if !ok { failures += 1; NSLog("PEEKTEST FAIL %@", msg()) }
        }
        func spin(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
        func settle() {
            var last = window.frame, stable = 0
            let deadline = Date(timeIntervalSinceNow: 4)
            while stable < 5, Date() < deadline {
                spin(0.1)
                if window.frame == last { stable += 1 } else { stable = 0; last = window.frame }
            }
            spin(0.3)
        }
        func goto(_ i: Int) {
            let d = i - folder.index
            if abs(d) == 1 {
                // 真实按键走响应链：← → 方向键
                let ch = d > 0 ? "\u{F703}" : "\u{F702}"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                            isARepeat: false, keyCode: d > 0 ? 124 : 123) { imageView.keyDown(with: e) }
            } else if d != 0 { goTo(i) }
            settle()
        }
        func snapshot(_ tag: String) -> (win: CGSize, shown: CGSize, fit: Bool, zoom: CGFloat) {
            let c = imageView.bounds.size
            let px = imageView.pixelSize
            let s = imageView.debugScale
            let st = imageView.viewState
            let shown = CGSize(width: px.width * s, height: px.height * s)
            NSLog("PEEKTEST %@ idx=%d window=%.0fx%.0f view=%.0fx%.0f px=%.0fx%.0f scale=%.4f shown=%.0fx%.0f isFit=%d zoom=%.3f",
                  tag, folder.index, window.frame.width, window.frame.height, c.width, c.height, px.width, px.height, s,
                  shown.width, shown.height, imageView.isFit ? 1 : 0, st.zoom)
            return (c, shown, imageView.isFit, st.zoom)
        }
        let savedKeep = Self.peekKeepsPosition
        #if FLIPIC_PRO
        // 测试进程的偏好域是 Flipic（不是正式的 com.xmasdong.photoview），这里改的是测试域
        let savedZoomKeep = Self.keepZoomOnPage
        Self.keepZoomOnPage = true
        // 测试进程的偏好域是 Flipic，不碰正式的 com.xmasdong.photoview；PEEKTEST_PRO=expired 时试用已过期
        License.debugSetTrialStart(daysAgo: ProcessInfo.processInfo.environment["PEEKTEST_PRO"] == "expired" ? 30 : 0)
        NSLog("PEEKTEST pro status=%@ unlocked=%d keepZoomOnPage=%d", "\(License.status)", License.isUnlocked ? 1 : 0, Self.keepZoomOnPage ? 1 : 0)
        #endif
        let outDir = workDir
        window.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 760), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        // 想定尺寸：像素 / 缩放因子，90% 可见区封顶，长边至少 360
        func expected(_ px: CGSize) -> CGSize {
            guard let screen = window.screen ?? NSScreen.main else { return .zero }
            let v = screen.visibleFrame
            var w = px.width / window.backingScaleFactor, h = px.height / window.backingScaleFactor
            let k = min(1, v.width * 0.9 / w, v.height * 0.9 / h)
            w *= k; h *= k
            if max(w, h) < 360 { let g = 360 / max(w, h); w *= g; h *= g }
            return CGSize(width: w, height: h)
        }
        for (keep, zoomMode) in [(true, "none"), (false, "none"), (true, "x1.6"), (false, "x1.6"), (true, "actual"), (false, "actual")] {
            Self.peekKeepsPosition = keep
            for round in 0..<(zoomMode == "none" ? 2 : 1) {
                let tagBase = "keep=\(keep ? 1 : 0) zoom=\(zoomMode)"
                goto(0)
                imageView.enterPeek()
                settle()
                // 用户在预览里先放大，再翻页：放大不能带到下一张上越翻越小
                if zoomMode == "x1.6" { imageView.zoom(toFitMultiple: 1.6) } else if zoomMode == "actual" { imageView.actualSize() }
                settle()
                if zoomMode != "none" { check(!imageView.isFit, "\(tagBase) zoom did not take effect") }
                var first: [Int: CGSize] = [:]
                // 第一轮：横竖来回 20 次（0 <-> 1）；第二轮：沿着 0...4 来回走
                let seq: [Int] = round == 0 ? (0..<20).map { $0 % 2 == 0 ? 1 : 0 } : [1, 2, 3, 4, 3, 2, 1, 0, 1, 2, 3, 4, 3, 2, 1, 0, 4, 0, 4, 0]
                for (n, idx) in seq.enumerated() {
                    goto(idx)
                    let r = snapshot("\(tagBase) round=\(round) step=\(n + 1)")
                    let px = imageView.pixelSize
                    let want = expected(px)
                    check(abs(r.win.width - want.width) < 3 && abs(r.win.height - want.height) < 3,
                          "\(tagBase) step \(n + 1) idx \(idx): view \(r.win) != expected \(want)")
                    check(r.fit, "\(tagBase) step \(n + 1) idx \(idx): not fit (zoom \(r.zoom))")
                    check(abs(r.shown.width - r.win.width) < 3 || abs(r.shown.height - r.win.height) < 3,
                          "\(tagBase) step \(n + 1) idx \(idx): photo \(r.shown) does not fill view \(r.win)")
                    if let f = first[idx] {
                        check(abs(f.width - r.win.width) < 2 && abs(f.height - r.win.height) < 2,
                              "\(tagBase) step \(n + 1) idx \(idx): window changed from \(f) to \(r.win)")
                    } else { first[idx] = r.win }
                    if n == seq.count - 1 {
                        captureWindow(to: "\(outDir)/\(tagBase)-round\(round)-final.png", raw: true)
                    }
                }
                // 退出预览，窗口回到进入前的大小
                imageView.endPeek()
                settle()
                check(abs(window.frame.width - 1100) < 2 && abs(window.frame.height - 760) < 2,
                      "\(tagBase) exit peek: window \(window.frame.size) != 1100x760")
            }
        }
        Self.peekKeepsPosition = savedKeep
        #if FLIPIC_PRO
        Self.keepZoomOnPage = savedZoomKeep
        #endif
        NSLog("PEEKTEST checks=%d failures=%d", checks, failures)
        NSApp.terminate(nil)
    }
}

extension ViewerViewController {
    /// --peekpagingtest <工作文件夹> <照片文件夹>：用真实照片按用户的步骤走一遍：
    /// 进入预览，到一张横图（hebei-S3），放大，翻到相邻的大竖图（sheet-1），再来回翻 20 次。
    /// 第一次翻页就要断言：照片贴合窗口、窗口尺寸 = 照片像素尺寸（90% 封顶）
    func runPeekPagingRealTest(workDir: String) {
        guard let window = view.window else { return }
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
            checks += 1
            if !ok { failures += 1; NSLog("PEEKTEST FAIL %@", msg()) }
        }
        func spin(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
        func settle() {
            var last = window.frame, stable = 0
            let deadline = Date(timeIntervalSinceNow: 4)
            while stable < 5, Date() < deadline {
                spin(0.1)
                if window.frame == last { stable += 1 } else { stable = 0; last = window.frame }
            }
            spin(0.3)
        }
        func press(_ d: Int) {
            let ch = d > 0 ? "\u{F703}" : "\u{F702}"
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: d > 0 ? 124 : 123) { imageView.keyDown(with: e) }
            settle()
        }
        func expected(_ px: CGSize) -> CGSize {
            guard let screen = window.screen ?? NSScreen.main else { return .zero }
            let v = screen.visibleFrame
            var w = px.width / window.backingScaleFactor, h = px.height / window.backingScaleFactor
            let k = min(1, v.width * 0.9 / w, v.height * 0.9 / h)
            w *= k; h *= k
            if max(w, h) < 360 { let g = 360 / max(w, h); w *= g; h *= g }
            return CGSize(width: w, height: h)
        }
        func snap(_ tag: String) -> (win: CGSize, shown: CGSize, fit: Bool) {
            let c = imageView.bounds.size, px = imageView.pixelSize, s = imageView.debugScale
            let shown = CGSize(width: px.width * s, height: px.height * s)
            NSLog("PEEKTEST %@ idx=%d window=%.0fx%.0f px=%.0fx%.0f scale=%.4f shown=%.0fx%.0f isFit=%d zoom=%.3f", tag, folder.index,
                  window.frame.width, window.frame.height, px.width, px.height, s, shown.width, shown.height,
                  imageView.isFit ? 1 : 0, imageView.viewState.zoom)
            return (c, shown, imageView.isFit)
        }
        func verify(_ tag: String) -> CGSize {
            let r = snap(tag), want = expected(imageView.pixelSize)
            check(abs(r.win.width - want.width) < 3 && abs(r.win.height - want.height) < 3, "\(tag): view \(r.win) != expected \(want)")
            check(r.fit, "\(tag): not fit")
            check(abs(r.shown.width - r.win.width) < 3 || abs(r.shown.height - r.win.height) < 3, "\(tag): photo \(r.shown) does not fill view \(r.win)")
            return r.win
        }
        let names = folder.items.map { $0.url.lastPathComponent }
        guard let land = names.firstIndex(of: "hebei-S3.jpg"), let big = names.firstIndex(of: "sheet-1.jpg"), big == land + 1 else {
            NSLog("PEEKTEST FAIL folder layout unexpected: %@", names.joined(separator: ","))
            NSApp.terminate(nil); return
        }
        #if FLIPIC_PRO
        let savedZoomKeep = Self.keepZoomOnPage
        Self.keepZoomOnPage = true
        // 测试进程的偏好域是 Flipic，不碰正式的 com.xmasdong.photoview；PEEKTEST_PRO=expired 时试用已过期
        License.debugSetTrialStart(daysAgo: ProcessInfo.processInfo.environment["PEEKTEST_PRO"] == "expired" ? 30 : 0)
        NSLog("PEEKTEST pro status=%@ unlocked=%d", "\(License.status)", License.isUnlocked ? 1 : 0)
        #endif
        let savedKeep = Self.peekKeepsPosition
        window.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 760), display: true)
        for keep in [true, false] {
            Self.peekKeepsPosition = keep
            for zoomMode in ["x1.6", "actual"] {
                let tag = "real keep=\(keep ? 1 : 0) zoom=\(zoomMode)"
                goTo(land); settle()
                imageView.enterPeek(); settle()
                let landWin = verify("\(tag) enter-land")
                func zoomIn() {
                    if zoomMode == "x1.6" { imageView.zoom(toFitMultiple: 1.6) } else { imageView.actualSize() }
                    settle()
                    check(!imageView.isFit, "\(tag): zoom did not take effect")
                }
                zoomIn()
                // 第一次翻页：放大着的横图 -> 大竖图
                press(1)
                var bigWin = verify("\(tag) turn1-big")
                captureWindow(to: "\(workDir)/\(tag.replacingOccurrences(of: " ", with: "_"))-turn1.png", raw: true)
                var firstBig = bigWin
                for n in 2...20 {
                    // 偶数次回横图，奇数次到大图；每次在横图上重新放大，模拟用户继续放大着翻
                    if n % 2 == 0 {
                        press(-1)
                        let w = verify("\(tag) turn\(n)-land")
                        check(abs(w.width - landWin.width) < 2 && abs(w.height - landWin.height) < 2, "\(tag) turn\(n): land window \(w) != first \(landWin)")
                        if n % 4 == 0 { zoomIn() }
                    } else {
                        press(1)
                        bigWin = verify("\(tag) turn\(n)-big")
                        check(abs(bigWin.width - firstBig.width) < 2 && abs(bigWin.height - firstBig.height) < 2, "\(tag) turn\(n): big window \(bigWin) != first \(firstBig)")
                        firstBig = bigWin
                    }
                }
                captureWindow(to: "\(workDir)/\(tag.replacingOccurrences(of: " ", with: "_"))-final.png", raw: true)
                imageView.endPeek(); settle()
            }
        }
        Self.peekKeepsPosition = savedKeep
        #if FLIPIC_PRO
        Self.keepZoomOnPage = savedZoomKeep
        #endif
        NSLog("PEEKTEST checks=%d failures=%d", checks, failures)
        NSApp.terminate(nil)
    }
}

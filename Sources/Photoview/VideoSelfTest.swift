import AppKit
import AVFoundation
import VideoToolbox

/// 自测用的视频：AVAssetWriter 现场生成，不依赖 ffmpeg
enum TestClip {
    struct Spec {
        var width: Int
        var height: Int
        var fps: Int
        var seconds: Double
        var codec: AVVideoCodecType = .h264
        /// HEVC Main10 + HLG（相机、手机的 HDR 视频）
        var tenBitHLG = false
        /// 写进轨道的拍摄方向（手机竖拍：画面按横的存，转 90° 显示）
        var transform: CGAffineTransform = .identity
        var bitrate: Int?
        /// 满屏移动的噪点：码率压不下去，模拟高码率素材
        var noise = false
        /// 帧号 → 纯色（BGRA 8 位才用）
        var color: (Int) -> (UInt8, UInt8, UInt8) = { _ in (128, 128, 128) }
    }

    /// 写到 url，成功返回 true。很慢（4K 噪点十几秒），别在主线程调
    static func write(_ spec: Spec, to url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let type: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: type) else { return false }
        var comp: [String: Any] = [AVVideoExpectedSourceFrameRateKey: spec.fps]
        if let b = spec.bitrate { comp[AVVideoAverageBitRateKey] = b }
        if spec.tenBitHLG { comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        var settings: [String: Any] = [AVVideoCodecKey: spec.codec, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
                                       AVVideoCompressionPropertiesKey: comp]
        if spec.tenBitHLG {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                  AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                                                  AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = spec.transform
        let pf = spec.tenBitHLG ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pf,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else {
            NSLog("TESTCLIP startWriting failed %@", writer.error?.localizedDescription ?? "-")
            return false
        }
        writer.startSession(atSourceTime: .zero)
        var noise = [UInt8]()
        if spec.noise {
            noise = [UInt8](repeating: 0, count: 1 << 23)
            noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        }
        let frames = Int(Double(spec.fps) * spec.seconds)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            let planes = max(CVPixelBufferGetPlaneCount(pb), 1)
            for p in 0..<planes {
                let planar = CVPixelBufferIsPlanar(pb)
                guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb) else { continue }
                let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb)
                let rows = planar ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb)
                if spec.noise {
                    // 每帧错开一段：整幅画面都在动
                    noise.withUnsafeBytes { n in
                        let span = n.count - rowBytes
                        for y in 0..<rows {
                            let off = (i * 7919 * 13 + y * 4099 + p * 1_000_003) % span
                            memcpy(base + y * rowBytes, n.baseAddress! + off, rowBytes)
                        }
                    }
                } else if !spec.tenBitHLG {
                    let (r, g, b) = spec.color(i)
                    let w = CVPixelBufferGetWidth(pb)
                    var row = [UInt8](repeating: 255, count: rowBytes)
                    for x in 0..<w { row[x * 4] = b; row[x * 4 + 1] = g; row[x * 4 + 2] = r }
                    row.withUnsafeBytes { src in
                        for y in 0..<rows { memcpy(base + y * rowBytes, src.baseAddress!, rowBytes) }
                    }
                } else {
                    memset(base, p == 0 ? 0x40 : 0x80, rowBytes * rows)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(spec.fps))) {
                NSLog("TESTCLIP append failed %@", writer.error?.localizedDescription ?? "-")
                return false
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return writer.status == .completed
    }
}

/// `Flipic --videotest <工作文件夹> [perf]`：
/// (a) 视频第一帧（封面）不能在播放时从画面后面露出来：红色第一秒、之后变绿的三段视频（横 H.264、竖拍 HEVC 带 90° 方向、4:3 MOV），
///     暂停和播放时各截一次窗口数像素；也试贴边信息面板、放大、铺满。
/// (b) 大疆 / GoPro / 索尼的附属文件跟着视频删除、⌘Z、废纸篓浏览器放回、复制、移动、改名；别的视频的附属文件不动。
/// (c) 带 perf 时再测 4K60 HEVC 10 位 HLG、1080p120 高码率的播放：丢帧、卡顿、主线程空转、CPU。
/// 最后一行 VIDEOTEST summary
extension ViewerViewController {
    func runVideoSelfTest(outDir: String, perfOnly: Bool, withPerf: Bool) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir)
        let clipsDir = root.appendingPathComponent("clips")
        let shotsDir = root.appendingPathComponent("shots")
        try? fm.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("VIDEOTEST \(ok ? "ok  " : "FAIL") \(what)")
            fflush(stdout)
        }
        let d = UserDefaults.standard
        let savedDock = d.object(forKey: "infoPanelDocked"), savedFill = d.object(forKey: "fitFillMode"), savedMute = d.object(forKey: "videoMuted")
        d.set(true, forKey: "videoMuted")
        func finish() {
            for (k, v) in [("infoPanelDocked", savedDock), ("fitFillMode", savedFill), ("videoMuted", savedMute)] {
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
            print("VIDEOTEST summary checks=\(checks) failures=\(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }

        // 红色一秒再变绿：播放一秒以后画面上不该再有红色（封面是红的）
        func rg(_ fps: Int) -> (Int) -> (UInt8, UInt8, UInt8) { { $0 < fps ? (255, 0, 0) : (0, 200, 0) } }
        let ghostDir = clipsDir.appendingPathComponent("ghost")
        try? fm.createDirectory(at: ghostDir, withIntermediateDirectories: true)
        let ghost: [(String, TestClip.Spec)] = [
            ("a-land-h264.mp4", .init(width: 1920, height: 1080, fps: 30, seconds: 4, codec: .h264, color: rg(30))),
            // 手机竖拍：按 1920×1080 存，轨道带 90° 方向，显示成 1080×1920
            ("b-portrait-hevc.mp4", .init(width: 1920, height: 1080, fps: 30, seconds: 4, codec: .hevc,
                                          transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0), color: rg(30))),
            ("c-4x3.mov", .init(width: 1440, height: 1080, fps: 25, seconds: 4, codec: .h264, color: rg(25))),
        ]
        let perfDir = clipsDir.appendingPathComponent("perf")
        try? fm.createDirectory(at: perfDir, withIntermediateDirectories: true)
        let perf: [(String, TestClip.Spec)] = [
            ("p1-4k60-hevc10-hlg.mov", .init(width: 3840, height: 2160, fps: 60, seconds: 10, codec: .hevc, tenBitHLG: true,
                                             bitrate: 120_000_000, noise: true)),
            ("p2-1080p120-h264.mp4", .init(width: 1920, height: 1080, fps: 120, seconds: 10, codec: .h264, bitrate: 60_000_000, noise: true)),
            ("p3-4k60-hevc8.mp4", .init(width: 3840, height: 2160, fps: 60, seconds: 10, codec: .hevc, bitrate: 100_000_000, noise: true)),
        ]

        guard let w = view.window, let screen = w.screen ?? NSScreen.main else { exit(1) }
        let vf = screen.visibleFrame
        w.setFrame(NSRect(x: vf.minX + 40, y: vf.minY + 40, width: min(1280, vf.width - 80), height: min(800, vf.height - 80)), display: true)

        // MARK: 截图分析
        struct Counts { var red = 0, green = 0, total = 0
            var redFrac: Double { total > 0 ? Double(red) / Double(total) : 0 }
            var greenFrac: Double { total > 0 ? Double(green) / Double(total) : 0 } }
        struct Analysis { var inside = Counts(), letterbox = Counts(), outside = Counts(), region = Counts(); var greenBox = CGRect.null; var photo = CGRect.zero }
        func analyze(_ path: String, region: CGRect? = nil, retry: Int = 3) -> Analysis? {
            view.layoutSubtreeIfNeeded()
            captureWindow(to: path, raw: true)
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let W = img.width, H = img.height
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            // 窗口正在换后备缓冲时偶尔截到一张全白（连窗口边框都没有）：不是画面，换一张重截
            if retry > 0 {
                var white = 0
                for k in stride(from: 0, to: buf.count, by: 4 * 97) where buf[k] > 250 && buf[k + 1] > 250 && buf[k + 2] > 250 { white += 1 }
                if white * 97 > W * H * 99 / 100 {
                    print("VIDEOTEST info blank capture (window backing swap), retry \(path)")
                    usleep(20_000)
                    return analyze(path, region: region, retry: retry - 1)
                }
            }
            let s = CGFloat(W) / w.frame.width
            func toPx(_ r: NSRect) -> CGRect {
                let win = imageView.convert(r, to: nil)
                return CGRect(x: win.minX * s, y: (w.frame.height - win.maxY) * s, width: win.width * s, height: win.height * s)
            }
            let viewPx = toPx(imageView.bounds)
            let photoPx = toPx(imageView.imageFrame)
            var a = Analysis()
            a.photo = photoPx
            let visible = photoPx.intersection(viewPx)
            let core = visible.insetBy(dx: 3, dy: 3)
            var gx0 = Int.max, gy0 = Int.max, gx1 = -1, gy1 = -1
            let y0 = max(0, Int(viewPx.minY)), y1 = min(H, Int(viewPx.maxY))
            let x0 = max(0, Int(viewPx.minX)), x1 = min(W, Int(viewPx.maxX))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * W + x) * 4
                    let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
                    let isRed = r > 110 && g < 70 && b < 70 && r > 2 * g
                    let isGreen = g > 110 && r < 90 && b < 90
                    let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    if isGreen { gx0 = min(gx0, x); gy0 = min(gy0, y); gx1 = max(gx1, x); gy1 = max(gy1, y) }
                    if let region, region.contains(p) { a.region.total += 1; if isRed { a.region.red += 1 }; if isGreen { a.region.green += 1 } }
                    if core.contains(p) {
                        a.inside.total += 1; if isRed { a.inside.red += 1 }; if isGreen { a.inside.green += 1 }
                    } else if visible.contains(p) {
                        a.letterbox.total += 1; if isRed { a.letterbox.red += 1 }; if isGreen { a.letterbox.green += 1 }
                    } else {
                        a.outside.total += 1; if isRed { a.outside.red += 1 }; if isGreen { a.outside.green += 1 }
                    }
                }
            }
            if gx1 >= 0 { a.greenBox = CGRect(x: gx0, y: gy0, width: gx1 - gx0 + 1, height: gy1 - gy0 + 1) }
            return a
        }
        func f(_ r: CGRect) -> String { r.isNull ? "-" : "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
        func desc(_ a: Analysis) -> String {
            String(format: "inside red=%.3f green=%.3f | edge red=%d/%d green=%d | outside red=%.3f green=%.3f | photo=%@ greenBox=%@",
                   a.inside.redFrac, a.inside.greenFrac, a.letterbox.red, a.letterbox.total, a.letterbox.green,
                   a.outside.redFrac, a.outside.greenFrac, f(a.photo), f(a.greenBox))
        }

        var t = 0.0
        var pausedPhoto = CGRect.zero
        func at(_ dt: Double, _ fn: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: fn) }
        func go(_ name: String) {
            if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == name }) { goTo(i) }
        }

        // 一段视频：暂停截一张、播放 1.6 秒后截一张，查封面露没露出来
        func ghostCase(_ name: String, tag: String, setup: (() -> Void)? = nil, after: (() -> Void)? = nil, expectAspect: CGFloat) {
            at(0.3) { [self] in
                video.clear()
                go(name)
            }
            at(2.0) { [self] in
                setup?()
            }
            at(1.2) { [self] in
                guard let a = analyze(shotsDir.appendingPathComponent("\(tag)-paused.png").path) else { check(false, "\(tag) capture"); return }
                print("VIDEOTEST info \(tag) paused: \(desc(a))")
                check(video.isActive && !video.isPlaying, "\(tag): 打开后挂着暂停的播放器")
                check(a.inside.redFrac > 0.95, "\(tag): 暂停时画面是红色第一帧（red=\(String(format: "%.3f", a.inside.redFrac))）")
                let ph = imageView.imageFrame
                check(abs(ph.width / ph.height - expectAspect) < 0.01, "\(tag): 照片框比例 \(String(format: "%.4f", ph.width / ph.height)) = 视频 \(String(format: "%.4f", expectAspect))")
                pausedPhoto = a.photo.insetBy(dx: 3, dy: 3)
                video.toggle()
                // 按下播放到画面真动起来要多久
                let pressed = CACurrentMediaTime()
                func poll() {
                    if video.debugTime > 0.02 {
                        print(String(format: "VIDEOTEST info %@ startLatency=%.0fms", tag, (CACurrentMediaTime() - pressed) * 1000))
                    } else if CACurrentMediaTime() - pressed > 3 {
                        print("VIDEOTEST info \(tag) startLatency>3s status=\(video.debugPlayer?.timeControlStatus.rawValue ?? -1) reason=\(video.debugPlayer?.reasonForWaitingToPlay?.rawValue ?? "-")")
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
                    }
                }
                poll()
            }
            // 刚按播放的几帧：缩略图栏收起、照片框变大的那一下，原来照片框里要么还是封面、要么已经是视频画面，不能闪一下空底
            for (k, dt) in [0.05, 0.1, 0.15].enumerated() {
                at(dt) { [self] in
                    // 缩略图栏收起时照片框会挪：只看前后两个照片框重叠的地方（截图可能还是上一帧的布局）
                    let s = CGFloat(view.window.map { CGFloat(0) + $0.backingScaleFactor } ?? 2)
                    let cur = imageView.convert(imageView.imageFrame, to: nil)
                    let curPx = CGRect(x: cur.minX * s, y: (w.frame.height - cur.maxY) * s, width: cur.width * s, height: cur.height * s)
                    let region = pausedPhoto.intersection(curPx.insetBy(dx: 3, dy: 3))
                    guard let a = analyze(shotsDir.appendingPathComponent("\(tag)-start\(k).png").path, region: region) else { return }
                    check(a.region.redFrac + a.region.greenFrac > 0.99,
                          "\(tag): 开始播放 \(k) 没有闪空底（原照片框里 red=\(String(format: "%.3f", a.region.redFrac)) green=\(String(format: "%.3f", a.region.greenFrac))）")
                }
            }
            at(1.6) { [self] in
                after?()
            }
            // 截图分析会占住主线程，按下播放可能比排的时间晚：等真播到 1.4 秒（已经是绿色）再截
            func playingCheck() {
                if video.isPlaying, video.debugTime < 1.4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, 1.45 - video.debugTime)) { playingCheck() }
                    return
                }
                guard let a = analyze(shotsDir.appendingPathComponent("\(tag)-playing.png").path) else { check(false, "\(tag) capture"); return }
                let pl = video.debugPlayer
                print("VIDEOTEST info \(tag) playing t=\(String(format: "%.2f", video.debugTime)) rate=\(pl?.rate ?? -1) status=\(pl?.timeControlStatus.rawValue ?? -1) reason=\(pl?.reasonForWaitingToPlay?.rawValue ?? "-") item=\(pl?.currentItem?.status.rawValue ?? -1) err=\(pl?.currentItem?.error?.localizedDescription ?? "-"): \(desc(a))")
                check(video.isPlaying && video.debugTime > 1.2, "\(tag): 在播放（t=\(String(format: "%.2f", video.debugTime))）")
                check(a.inside.red == 0 && a.letterbox.red == 0,
                      "\(tag): 播放到绿色后照片框里没有红色封面（inside \(a.inside.red) edge \(a.letterbox.red)）")
                check(a.outside.red == 0, "\(tag): 照片框外（背景）也没有红色封面的颜色（\(a.outside.red) px）")
                check(a.inside.greenFrac > 0.99, "\(tag): 视频画面铺满照片框（green=\(String(format: "%.3f", a.inside.greenFrac))）")
                if let o = imageView.debugOverlayFrame {
                    let ph = imageView.imageFrame
                    check(abs(o.width - ph.width) < 0.5 && abs(o.height - ph.height) < 0.5 && abs(o.minX) < 0.5 && abs(o.minY) < 0.5,
                          "\(tag): 视频图层 \(f(o)) 和照片框 \(f(CGRect(origin: .zero, size: ph.size))) 一样大")
                } else {
                    check(false, "\(tag): 视频图层在")
                }
                video.pause()
            }
            at(0.6) { playingCheck() }
            at(1.5) {}
        }

        func ghostTests(then next: @escaping () -> Void) {
            open(url: ghostDir)
            at(1.5) { [self] in
                let names = folder.items.map(\.url.lastPathComponent)
                check(names.count == 3, "视频文件夹列出 3 段视频（\(names.joined(separator: ","))）")
                exifPanel.isHidden = true
                updateInfoDock()
            }
            ghostCase("a-land-h264.mp4", tag: "land", expectAspect: 1920.0 / 1080)
            ghostCase("b-portrait-hevc.mp4", tag: "portrait", expectAspect: 1080.0 / 1920)
            ghostCase("c-4x3.mov", tag: "4x3", expectAspect: 1440.0 / 1080)
            // 贴边的信息面板：照片区变窄
            ghostCase("a-land-h264.mp4", tag: "land-docked", setup: { [self] in
                UserDefaults.standard.set(true, forKey: "infoPanelDocked")
                if exifPanel.isHidden { toggleInfoPanel(nil) }
                updateInfoDock()
            }, expectAspect: 1920.0 / 1080)
            at(0.3) { [self] in
                check(infoDocked, "信息面板贴边（docked=\(infoDocked)）")
            }
            ghostCase("b-portrait-hevc.mp4", tag: "portrait-docked", expectAspect: 1080.0 / 1920)
            // 播放中放大两倍
            ghostCase("a-land-h264.mp4", tag: "land-zoom", after: { [self] in
                imageView.zoom(toFitMultiple: 2)
            }, expectAspect: 1920.0 / 1080)
            // 播放中关掉信息面板（照片区变宽）
            ghostCase("c-4x3.mov", tag: "4x3-undock", after: { [self] in
                toggleInfoPanel(nil)
                updateInfoDock()
            }, expectAspect: 1440.0 / 1080)
            // 铺满：竖视频在横窗口里按长边铺满，上下超出窗口
            ghostCase("b-portrait-hevc.mp4", tag: "portrait-fill", setup: { [self] in
                if !exifPanel.isHidden { toggleInfoPanel(nil); updateInfoDock() }
                ZoomableImageView.fillMode = 2
                imageView.fit()
            }, after: { [self] in
                imageView.fit()
            }, expectAspect: 1080.0 / 1920)
            ghostCase("a-land-h264.mp4", tag: "land-fill", expectAspect: 1920.0 / 1080)
            at(0.3) { [self] in
                ZoomableImageView.fillMode = 0
                imageView.fit()
                // 翻走再翻回来：封面还在（没被藏掉）
                navigate(1)
            }
            at(1.5) { [self] in
                go("a-land-h264.mp4")
            }
            at(2.0) { [self] in
                guard let a = analyze(shotsDir.appendingPathComponent("back-paused.png").path) else { return }
                check(a.inside.redFrac > 0.95, "翻走再翻回来，暂停画面还是第一帧（red=\(String(format: "%.3f", a.inside.redFrac))）")
                video.clear()
                video.show(folder.current?.url)
            }
            at(1.0) { [self] in
                // 停掉（拆掉播放器）以后封面照样显示
                video.clear()
                guard let a = analyze(shotsDir.appendingPathComponent("cleared.png").path) else { return }
                check(a.inside.redFrac > 0.95, "拆掉播放器后封面还在（red=\(String(format: "%.3f", a.inside.redFrac))）")
                t = 0
                next()
            }
        }

        // MARK: 附属文件
        func companionTests(then next: @escaping () -> Void) {
            let dir = root.appendingPathComponent("companions")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tiny = clipsDir.appendingPathComponent("tiny.mp4")
            if !fm.fileExists(atPath: tiny.path) {
                _ = TestClip.write(.init(width: 160, height: 90, fps: 10, seconds: 1, codec: .h264, color: { _ in (40, 80, 200) }), to: tiny)
            }
            func put(_ name: String) {
                let u = dir.appendingPathComponent(name)
                if Video.isVideoName(name) { try? fm.copyItem(at: tiny, to: u) } else { try? Data(name.utf8).write(to: u) }
            }
            let names = ["DJI_20231012_0001_D.MP4", "DJI_20231012_0001_D.LRF", "DJI_20231012_0001_D.SRT",
                         "DJI_20231012_0002_D.MP4", "DJI_20231012_0002_D.LRF",
                         "GX010123.MP4", "GL010123.LRV", "GX010123.THM",
                         "C0001.MP4", "C0001M01.XML", "C0002M01.XML",
                         "a.jpg"]
            for n in names where n != "a.jpg" { put(n) }
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                try? rep.representation(using: .jpeg, properties: [:])?.write(to: dir.appendingPathComponent("a.jpg"))
            }
            func exists(_ n: String, in d: URL? = nil) -> Bool { fm.fileExists(atPath: (d ?? dir).appendingPathComponent(n).path) }
            func listing(_ d: URL) -> String { ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted().joined(separator: ",") }

            // 纯规则
            let m = { (v: String, all: [String]) in VideoCompanions.match(video: v, among: all) }
            check(m("DJI_20231012_0001_D.MP4", names) == ["DJI_20231012_0001_D.LRF", "DJI_20231012_0001_D.SRT"], "规则：大疆 LRF + SRT")
            check(m("GX010123.MP4", names) == ["GL010123.LRV", "GX010123.THM"], "规则：GoPro GL…LRV + THM")
            check(m("GH010124.mp4", ["GH010124.mp4", "gl010124.lrv", "gh010124.thm"]) == ["gh010124.thm", "gl010124.lrv"], "规则：GoPro GH，小写")
            check(m("C0001.MP4", names) == ["C0001M01.XML"], "规则：索尼 C0001M01.XML，不带 C0002M01.XML")
            check(m("dji_0003.mp4", ["dji_0003.mp4", "DJI_0003.MOV", "DJI_0003.LRF"]).isEmpty, "规则：同名的另一个视频在时 LRF 不动")
            check(m("GX010125.MP4", ["GX010125.MP4", "GH010125.MP4", "GL010125.LRV"]).isEmpty, "规则：GL 同时可能属于 GH 的视频时不动")
            check(m("a.jpg", names).isEmpty && VideoCompanions.files(of: dir.appendingPathComponent("a.jpg")).isEmpty, "规则：照片没有视频附属文件")
            check(m("C0001.MP4", ["C0001.MP4", "C0001M00.XML", "C0001X01.XML", "C0001M1.XML"]).isEmpty, "规则：索尼只认 M01…M99")
            check(VideoCompanions.renamed("GL010123.LRV", oldStem: "GX010123", newStem: "GX010999") == "GL010999.LRV", "改名规则：GoPro GL 跟着编号")
            check(VideoCompanions.renamed("C0001M01.XML", oldStem: "C0001", newStem: "Trip") == "TripM01.XML", "改名规则：索尼后缀保留")
            check(Trash.photoCount(in: [dir.appendingPathComponent("DJI_20231012_0001_D.MP4"), dir.appendingPathComponent("DJI_20231012_0001_D.LRF"),
                                        dir.appendingPathComponent("DJI_20231012_0001_D.SRT")]) == 1, "张数：视频 + LRF + SRT 算 1 个")

            let dji = "DJI_20231012_0001_D"
            open(url: dir)
            at(1.5) { [self] in
                let listed = folder.items.map(\.url.lastPathComponent).sorted()
                check(listed == ["C0001.MP4", "DJI_20231012_0001_D.MP4", "DJI_20231012_0002_D.MP4", "GX010123.MP4", "a.jpg"],
                      "缩略图栏只列视频和照片，附属文件不进（\(listed.joined(separator: ","))）")
                #if FLIPIC_PRO
                let wb = WorkbenchViewController.listPhotos(dir).map(\.url.lastPathComponent)
                check(wb == ["a.jpg"], "工作台不列视频，也不列附属文件（\(wb.joined(separator: ","))）")
                #endif
                go("\(dji).MP4")
            }
            at(1.0) { [self] in
                trashCurrent(nil)
            }
            at(1.5) { [self] in
                check(!exists("\(dji).MP4") && !exists("\(dji).LRF") && !exists("\(dji).SRT"), "删除大疆视频：MP4 + LRF + SRT 都进了废纸篓（剩 \(listing(dir))）")
                check(exists("DJI_20231012_0002_D.LRF") && exists("DJI_20231012_0002_D.MP4"), "另一段大疆视频和它的 LRF 没动")
                let rec = Self.lastTrash
                check(rec?.moved.count == 3 && rec.map { Trash.photoCount(in: $0.moved.keys) } == 1, "删除记录 3 个文件、算 1 个视频（\(rec?.moved.count ?? 0)）")
                if let rec { print("VIDEOTEST info trash summary: \(Trash.summary(Trash.Outcome(moved: rec.moved), count: Trash.photoCount(in: rec.moved.keys)))") }
                undo(nil)
            }
            at(1.5) { [self] in
                check(exists("\(dji).MP4") && exists("\(dji).LRF") && exists("\(dji).SRT"), "⌘Z 放回：MP4 + LRF + SRT 都回来了")
                go("GX010123.MP4")
            }
            at(1.0) { [self] in trashCurrent(nil) }
            at(1.5) { [self] in
                check(!exists("GX010123.MP4") && !exists("GL010123.LRV") && !exists("GX010123.THM"), "删除 GoPro：MP4 + GL…LRV + THM 都走了")
                // 废纸篓浏览器「放回原处」：附属文件跟着视频回来
                if let rec = Self.lastTrash, let orig = rec.moved.keys.first(where: { $0.lastPathComponent == "GX010123.MP4" }), let trashed = rec.moved[orig] {
                    let found = TrashBrowserWindowController.Found(url: trashed, date: Date(), place: "", original: orig)
                    check(TrashBrowserWindowController.videoCompanions(of: found).count == 2, "废纸篓浏览器认出 2 个附属文件")
                    let n = TrashBrowserWindowController.moveBackToOriginals([found])
                    check(n == 1 && exists("GX010123.MP4") && exists("GL010123.LRV") && exists("GX010123.THM"),
                          "废纸篓浏览器放回原处：视频 + 附属文件都回来了（\(listing(dir))）")
                } else {
                    check(false, "GoPro 删除记录")
                }
                Self.lastTrash = nil
                go("C0001.MP4")
            }
            at(1.0) { [self] in trashCurrent(nil) }
            at(1.5) { [self] in
                check(!exists("C0001.MP4") && !exists("C0001M01.XML") && exists("C0002M01.XML"), "删除索尼：MP4 + M01.XML 走了，C0002M01.XML 没动")
                restoreLastTrash(nil)
            }
            at(1.5) { [self] in
                check(exists("C0001.MP4") && exists("C0001M01.XML"), "放回刚才删掉的：索尼 MP4 + XML 回来了")
                // 复制、移动
                let copyDir = root.appendingPathComponent("companions-copy")
                let moveDir = root.appendingPathComponent("companions-move")
                try? fm.removeItem(at: copyDir); try? fm.removeItem(at: moveDir)
                let r1 = Self.transfer([dir.appendingPathComponent("GX010123.MP4"), dir.appendingPathComponent("C0001.MP4")], to: copyDir, move: false)
                check(r1.done.count == 2 && exists("GL010123.LRV", in: copyDir) && exists("GX010123.THM", in: copyDir) && exists("C0001M01.XML", in: copyDir)
                      && !exists("C0002M01.XML", in: copyDir) && exists("GL010123.LRV"),
                      "复制：附属文件跟着复制、原处还在（\(listing(copyDir))）")
                // 目标里已有同名：整组换成「… 2」
                let r2 = Self.transfer([dir.appendingPathComponent("GX010123.MP4")], to: copyDir, move: false)
                check(r2.done.count == 1 && exists("GX010123 2.MP4", in: copyDir) && exists("GL010123 2.LRV", in: copyDir) && exists("GX010123 2.THM", in: copyDir),
                      "复制到已有同名的文件夹：整组改成「… 2」（\(listing(copyDir))）")
                let r3 = Self.transfer([dir.appendingPathComponent("\(dji).MP4")], to: moveDir, move: true)
                check(r3.done.count == 1 && exists("\(dji).LRF", in: moveDir) && exists("\(dji).SRT", in: moveDir) && !exists("\(dji).LRF") && !exists("\(dji).SRT")
                      && exists("DJI_20231012_0002_D.LRF"), "移动：LRF + SRT 跟着移走，另一段的 LRF 留下（\(listing(moveDir))）")
                // 移回来接着测改名
                _ = Self.transfer([moveDir.appendingPathComponent("\(dji).MP4")], to: dir, move: true)
                check(exists("\(dji).LRF") && exists("\(dji).SRT"), "移回来：附属文件也回来")
                folderDidChange(removing: true)
            }
            at(1.5) { [self] in
                go("\(dji).MP4")
            }
            at(1.0) { [self] in
                renameCurrent(to: "Trip")
                check(exists("Trip.MP4") && exists("Trip.LRF") && exists("Trip.SRT") && !exists("\(dji).LRF"), "改名：Trip.MP4 + Trip.LRF + Trip.SRT（\(listing(dir))）")
                go("GX010123.MP4")
            }
            at(1.0) { [self] in
                renameCurrent(to: "GX010999")
                check(exists("GX010999.MP4") && exists("GL010999.LRV") && exists("GX010999.THM"), "改名：GoPro GL…LRV 跟着编号")
                go("C0001.MP4")
            }
            at(1.0) { [self] in
                renameCurrent(to: "C0100")
                check(exists("C0100.MP4") && exists("C0100M01.XML") && exists("C0002M01.XML"), "改名：索尼 C0100M01.XML，C0002M01.XML 没动")
                t = 0
                next()
            }
        }

        // MARK: 播放流畅度
        func perfTests(then next: @escaping () -> Void) {
            open(url: perfDir)
            var idx = 0
            func runOne() {
                guard idx < perf.count else { next(); return }
                let name = perf[idx].0
                idx += 1
                t = 0
                at(0.3) { [self] in video.clear(); go(name) }
                at(2.5) { [self] in
                    guard video.isActive else { check(false, "perf \(name): 播放器挂上"); runOne(); return }
                    // 数解出来的帧：按显示时刻取，取到新帧就算一帧；漏掉的就是来不及解 / 读盘慢的
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                    video.debugPlayer?.currentItem?.add(output)
                    let fps = Double(perf[idx - 1].1.fps)
                    var frames = 0, lateGaps = 0
                    var lastFrameTime = -1.0
                    video.toggle()
                    let start = CACurrentMediaTime()
                    var last = start, maxGap = 0.0, hitches = 0
                    var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
                    let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
                        let now = CACurrentMediaTime()
                        let gap = now - last
                        maxGap = max(maxGap, gap)
                        if gap > 0.05 { hitches += 1 }
                        last = now
                        let it = output.itemTime(forHostTime: now)
                        if output.hasNewPixelBuffer(forItemTime: it) {
                            var shown = CMTime.zero
                            if output.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: &shown) != nil {
                                frames += 1
                                let st = shown.seconds
                                // 相邻两帧之间隔了一帧以上：中间那帧丢了
                                if lastFrameTime >= 0, st - lastFrameTime > 1.5 / fps { lateGaps += Int(((st - lastFrameTime) * fps).rounded()) - 1 }
                                lastFrameTime = st
                            }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    let t0 = video.debugTime
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [self] in
                        timer.invalidate()
                        let wall = CACurrentMediaTime() - start
                        let played = video.debugTime - t0
                        var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
                        func sec(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
                        let cpu = (sec(ru1.ru_utime) - sec(ru0.ru_utime) + sec(ru1.ru_stime) - sec(ru0.ru_stime)) / wall * 100
                        let ev = video.debugPlayer?.currentItem?.accessLog()?.events.last
                        let p = video.debugPlayer
                        let expected = Int(played * fps)
                        print(String(format: "VIDEOPERF %@ wall=%.2f played=%.2f ratio=%.3f frames=%d/%d skipped=%d occluded=%@ dropped=%d stalls=%d mainMaxGapMs=%.1f mainHitches=%d cpu=%.0f%% buffer=%.1f waits=%@",
                                     name, wall, played, played / wall, frames, expected, lateGaps, (view.window?.occlusionState.contains(.visible) ?? false) ? "no" : "yes",
                                     ev?.numberOfDroppedVideoFrames ?? -1, ev?.numberOfStalls ?? -1,
                                     maxGap * 1000, hitches, cpu, p?.currentItem?.preferredForwardBufferDuration ?? -1,
                                     (p?.automaticallyWaitsToMinimizeStalling ?? false) ? "yes" : "no"))
                        fflush(stdout)
                        check(played / wall > 0.95, "perf \(name): 播放进度跟得上时间（\(String(format: "%.3f", played / wall))）")
                        // 暂停、拖动要立刻响应
                        let pt = CACurrentMediaTime()
                        video.toggle()
                        check(!video.isPlaying, "perf \(name): 暂停立刻生效")
                        video.seek(by: -3)
                        video.debugPlayer?.currentItem?.remove(output)
                        let seekMs = (CACurrentMediaTime() - pt) * 1000
                        check(seekMs < 50, "perf \(name): 暂停 + 快退在主线程上 \(String(format: "%.1f", seekMs)) ms")
                        runOne()
                    }
                }
            }
            at(1.5) { runOne() }
        }

        // MARK: 生成视频，然后按顺序跑
        DispatchQueue.global(qos: .userInitiated).async {
            func ensure(_ list: [(String, TestClip.Spec)], in dir: URL) {
                for (name, spec) in list {
                    let u = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: u.path), AVURLAsset(url: u).tracks(withMediaType: .video).first != nil { continue }
                    let t0 = CACurrentMediaTime()
                    let ok = TestClip.write(spec, to: u)
                    let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0
                    print(String(format: "VIDEOTEST info generated %@ ok=%@ %.1fs %.1f MB", name, ok ? "yes" : "no", CACurrentMediaTime() - t0, Double(size) / 1e6))
                    fflush(stdout)
                }
            }
            if !perfOnly { ensure(ghost, in: ghostDir) }
            if withPerf || perfOnly { ensure(perf, in: perfDir) }
            DispatchQueue.main.async {
                if perfOnly {
                    perfTests { finish() }
                } else {
                    ghostTests {
                        companionTests {
                            if withPerf { perfTests { finish() } } else { finish() }
                        }
                    }
                }
            }
        }
    }
}

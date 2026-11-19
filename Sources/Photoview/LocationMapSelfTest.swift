import AppKit
import ImageIO

/// `Flipic --maptest <输出文件夹> <一张 JPEG>`：信息面板位置小地图的自测。
/// 照片是把那张 JPEG 复制到输出文件夹里，用 ImageIO 写进（或去掉）GPS。地图图片默认由假的提供者生成，不联网；
/// 环境变量 MAPTEST_LIVE=1 时改用真的 MKMapSnapshotter，只请求测试里那几个公开坐标。
/// 设置读写的是当前包的偏好设置，要用换了包名的测试包跑。打 MAPTEST 行，最后一行 MAPTEST summary
enum MapSelfTest {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("MAPTEST \(ok ? "ok  " : "FAIL") \(what)")
        fflush(stdout)
    }

    static func finish() -> Never {
        print("MAPTEST summary checks=\(checks) failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    static func fail(_ what: String) -> Never {
        check(false, what)
        finish()
    }

    static let photos: [(name: String, coord: (lat: Double, lon: Double)?)] = [
        ("a_nogps", nil),
        ("b_shanghai", (31.2304, 121.4737)),
        ("c_paris", (48.8584, 2.2945)),
        ("d_tokyo", (35.6586, 139.7454)),
        ("e_newyork", (40.6892, -74.0445)),
        ("f_sydney", (-33.8568, 151.2153)),
        ("g_london", (51.5007, -0.1246)),
        ("h_rio", (-22.9519, -43.2105)),
        ("i_nogps", nil),
    ]

    /// 把 src 重新编码成 JPEG 放到 dst；coord 有值就写成这个 GPS，没有就把原来的 GPS 去掉
    static func writeCopy(src: URL, dst: URL, coord: (lat: Double, lon: Double)?) -> Bool {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
              let d = CGImageDestinationCreateWithURL(dst as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [:]
        if let c = coord {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(c.lat), kCGImagePropertyGPSLatitudeRef: c.lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(c.lon), kCGImagePropertyGPSLongitudeRef: c.lon >= 0 ? "E" : "W",
            ] as [CFString: Any]
        } else {
            props[kCGImagePropertyGPSDictionary] = kCFNull
        }
        CGImageDestinationAddImageFromSource(d, s, 0, props as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    /// 假地图：按坐标和深浅色定一个底色，写上坐标，一眼看得出是哪张
    static func fakeImage(_ r: LocationMap.Request) -> NSImage {
        let dark = r.appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hue = CGFloat(abs(Int((r.latitude * 7919 + r.longitude * 104729).rounded())) % 360) / 360
        let fill = NSColor(calibratedHue: hue, saturation: 0.35, brightness: dark ? 0.35 : 0.85, alpha: 1)
        let text = String(format: "FAKE %.4f, %.4f %@", r.latitude, r.longitude, dark ? "dark" : "light")
        return NSImage(size: r.size, flipped: false) { rect in
            fill.setFill()
            rect.fill()
            (text as NSString).draw(at: NSPoint(x: 10, y: rect.height - 22),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dark ? NSColor.white : NSColor.black])
            return true
        }
    }

    /// 图的明暗起伏：全是一个颜色（空白、纯色底）接近 0，真的地图明显大于 0
    static func contrast(_ image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lum: [Double] = []
        for i in 0..<(w * h) { lum.append(0.299 * Double(px[i * 4]) + 0.587 * Double(px[i * 4 + 1]) + 0.114 * Double(px[i * 4 + 2])) }
        let mean = lum.reduce(0, +) / Double(lum.count)
        return (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count)).squareRoot()
    }
}

extension ViewerViewController {
    func runMapTest(outDir: String, photo: String) {
        typealias T = MapSelfTest
        let live = ProcessInfo.processInfo.environment["MAPTEST_LIVE"] == "1"
        let fm = FileManager.default
        let out = URL(fileURLWithPath: outDir)
        let photoDir = out.appendingPathComponent("photos")
        let shotDir = out.appendingPathComponent("shots")
        do {
            try fm.createDirectory(at: photoDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: shotDir, withIntermediateDirectories: true)
        } catch { T.fail("cannot create output folders in \(outDir)") }
        guard fm.fileExists(atPath: photo) else { T.fail("input photo missing: \(photo)") }
        print("MAPTEST mode=\(live ? "LIVE (real Apple snapshots)" : "fake provider") bundle=\(Bundle.main.bundleIdentifier ?? "?") lang=\(Bundle.main.preferredLocalizations.first ?? "?")")

        // 照片：有位置的和没位置的
        for p in T.photos {
            let dst = photoDir.appendingPathComponent(p.name + ".jpg")
            if !T.writeCopy(src: URL(fileURLWithPath: photo), dst: dst, coord: p.coord) { T.fail("cannot write fixture \(p.name)") }
            let read = ExifReader.info(url: dst).common.first { $0.coordinate != nil }?.coordinate
            let okRead = p.coord == nil ? read == nil : (read.map { abs($0.lat - p.coord!.lat) < 1e-4 && abs($0.lon - p.coord!.lon) < 1e-4 } ?? false)
            T.check(okRead, "fixture \(p.name) \(p.coord == nil ? "has no GPS" : "has GPS written")")
        }
        if T.failures > 0 { T.finish() }

        // 测试包的偏好设置：开头先把相关项摆到已知状态
        LocationMap.autoShow = false
        LocationMap.sessionAuto = false
        let savedLevel = InfoLevel.current
        InfoLevel.current = .common

        var calls: [(lat: Double, lon: Double, dark: Bool)] = []
        var cancels = 0
        var delay = 0.15
        var failNext = false
        let realProvider = LocationMap.provider
        if live {
            LocationMap.provider = { req, done in
                calls.append((req.latitude, req.longitude, req.appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
                return realProvider(req, done)
            }
        } else {
            LocationMap.provider = { req, done in
                calls.append((req.latitude, req.longitude, req.appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
                let work = DispatchWorkItem { done(failNext ? nil : T.fakeImage(req)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                // 故意不真的取消：这样「晚到的结果被丢掉」测的是视图自己的核对，不是取消
                return { cancels += 1 }
            }
        }
        var opened: [URL] = []
        LocationMap.opener = { opened.append($0) }

        // 步骤：每步给出等待时间，动作里调 next 才进下一步
        var steps: [(Double, (@escaping () -> Void) -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, { next in f(); next() })) }
        func poll(_ timeout: Double, _ cond: @escaping () -> Bool) {
            steps.append((0.05, { next in
                let t0 = Date()
                func tick() {
                    if cond() || Date().timeIntervalSince(t0) > timeout { next() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: tick) }
                }
                tick()
            }))
        }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f { runNext() } }
        }
        func index(_ name: String) -> Int { folder.items.firstIndex { $0.url.deletingPathExtension().lastPathComponent == name } ?? 0 }
        func go(_ name: String) { goTo(index(name)) }
        var map: LocationMapView? { exifPanel.debugMapView }
        func shot(_ name: String) {
            at(0.0) { self.exifPanel.debugScrollToBottom() }
            at(0.3) { self.shotPanel(to: shotDir.appendingPathComponent(name + ".png").path) }
        }
        func key(_ lat: Double, _ lon: Double) -> String { String(format: "%.4f,%.4f", lat, lon) }
        let shanghai = key(31.2304, 121.4737), paris = key(48.8584, 2.2945), tokyo = key(35.6586, 139.7454)
        let newyork = key(40.6892, -74.0445), rio = key(-22.9519, -43.2105)

        at(0.0) {
            if let w = self.view.window {
                let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 800, width: 1180, height: 780), display: true)
            }
            self.open(url: photoDir)
        }
        at(1.5) {
            T.check(self.folder.count == T.photos.count, "folder opened with \(self.folder.count) photos")
            if self.exifPanel.isHidden { self.toggleInfoPanel(nil) }
            go("a_nogps")
        }

        if live {
            at(0.8) {
                LocationMap.autoShow = true
                go("b_shanghai")
            }
            poll(40) { map?.state == .loaded || map?.state == .failed }
            at(0.3) {
                T.check(map?.state == .loaded, "LIVE shanghai: real snapshot loaded (state=\(String(describing: map?.state)))")
                if let img = map?.debugImage {
                    let rep = img.representations.first
                    T.check(T.contrast(img) > 12, String(format: "LIVE shanghai: image has real map detail (contrast %.1f, size %.0fx%.0f pt, rep %dx%d px)",
                                                         T.contrast(img), img.size.width, img.size.height, rep?.pixelsWide ?? 0, rep?.pixelsHigh ?? 0))
                }
            }
            shot("live-01-shanghai")
            at(0.2) { go("c_paris") }
            poll(40) { map?.state == .loaded || map?.state == .failed }
            at(0.3) {
                T.check(map?.state == .loaded && map?.shownCoordinateKey == paris, "LIVE paris: real snapshot loaded for paris")
                if let img = map?.debugImage { T.check(T.contrast(img) > 12, String(format: "LIVE paris: image has real map detail (contrast %.1f)", T.contrast(img))) }
            }
            shot("live-02-paris")
            // 窗口原本是哪种外观就换成另一种
            var wasDark = true
            at(0.2) {
                wasDark = calls.last?.dark ?? true
                self.view.window?.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)
            }
            poll(40) { map?.state == .loaded || map?.state == .failed }
            at(0.3) {
                T.check(map?.state == .loaded && calls.last?.dark == !wasDark, "LIVE paris \(wasDark ? "light" : "dark"): snapshot for the other appearance requested and loaded")
                T.check(calls.count == 3, "LIVE requests so far = \(calls.count) (expected 3: shanghai, paris, paris other appearance)")
                if let img = map?.debugImage { T.check(T.contrast(img) > 12, String(format: "LIVE paris other appearance: image has real map detail (contrast %.1f)", T.contrast(img))) }
            }
            shot("live-03-paris-other-appearance")
            at(0.2) {
                self.view.window?.appearance = nil
                InfoLevel.current = savedLevel
                T.finish()
            }
            runNext()
            return
        }

        // MARK: 假提供者的全套检查

        // 1 没有位置：没有地图，没有请求
        at(1.0) {
            T.check(map == nil, "no GPS: no map area in the panel")
            T.check(calls.isEmpty, "no GPS: zero provider calls")
        }
        shot("01-no-gps")

        // 2 自动显示关着：占位 + 按钮，不联网
        at(0.1) { go("b_shanghai") }
        at(0.7) {
            T.check(map != nil, "GPS photo: map area present")
            T.check(map?.state == .placeholder, "auto-show off: placeholder state (state=\(String(describing: map?.state)))")
            T.check(map?.debugButton.title == L10n.t("info.map.show", "显示地图") && map?.debugButton.isHidden == false, "placeholder shows the Show Map button")
            T.check(map?.debugNoteText == L10n.t("info.map.note", "地图来自 Apple 地图，需要联网加载"), "placeholder shows the Apple note")
            T.check(map?.debugAlwaysButton.title == L10n.t("info.map.always", "以后自动显示"), "placeholder offers the always-show link")
            T.check(calls.isEmpty, "placeholder: zero provider calls before click")
            T.check(map.map { $0.frame.height == 140 && $0.frame.width == 268 } ?? false, "map area is 268 x 140 pt (is \(map.map { "\($0.frame.width) x \($0.frame.height)" } ?? "none"))")
            T.check(!UserDefaults.standard.bool(forKey: LocationMap.autoKey), "auto-show setting is off by default")
        }
        shot("02-placeholder")

        // 3 点按钮：加载，本次运行里之后自动
        at(0.1) { map?.debugShowClicked() }
        at(0.7) {
            T.check(map?.state == .loaded, "after Show Map click: map loaded")
            T.check(calls.count == 1 && calls.first.map { key($0.lat, $0.lon) } == shanghai, "exactly one provider call, for the shanghai coordinate")
            T.check(map?.shownCoordinateKey == shanghai, "displayed map belongs to this photo")
            T.check(LocationMap.sessionAuto, "click turned on session auto-load")
            T.check(!UserDefaults.standard.bool(forKey: LocationMap.autoKey), "click did not write the persisted setting")
        }
        shot("03-loaded-after-click")

        // 4 点地图：打开同一个网址
        at(0.1) { map?.debugClick() }
        at(0.1) {
            // 上海在中国大陆：链接里是换算成地图坐标后的值
            let expect = ChinaCoordinate.mapsURL(latitude: 31.2304, longitude: 121.4737)?.absoluteString
            T.check(opened.last?.absoluteString == expect && expect?.contains("ll=31.2304") == false, "click opens the converted maps.apple.com URL (\(opened.last?.absoluteString ?? "nothing"))")
            // 换算和区域边界：蛇口那张 iPhone 照片换算后应落在邮轮母港一带（约 22.4692, 113.9149）
            let sk = ChinaCoordinate.forMap(latitude: 22.47223333333333, longitude: 113.9100333333333)
            T.check(abs(sk.lat - 22.46918) < 0.0002 && abs(sk.lon - 113.91489) < 0.0002, String(format: "Shekou converts to %.5f, %.5f", sk.lat, sk.lon))
            for (name, la, lo, mainland) in [("Shekou", 22.4722, 113.9100, true), ("Futian", 22.5400, 114.0500, true), ("Beijing", 39.9087, 116.3975, true),
                                             ("HK Central", 22.2800, 114.1600, false), ("Tuen Mun", 22.3900, 113.9700, false), ("Lo Wu HK", 22.5200, 114.1100, false),
                                             ("Macau", 22.1900, 113.5400, false), ("Taipei", 25.0330, 121.5654, false), ("Kinmen", 24.4400, 118.3200, false),
                                             ("Tokyo", 35.6812, 139.7671, false), ("Paris", 48.8566, 2.3522, false)] {
                T.check(ChinaCoordinate.inMainlandChina(latitude: la, longitude: lo) == mainland, "\(name) mainland=\(mainland)")
            }
            let paris = ChinaCoordinate.forMap(latitude: 48.8566, longitude: 2.3522)
            T.check(paris.lat == 48.8566 && paris.lon == 2.3522, "outside China unchanged")
        }

        // 5 下一张有位置的照片自动加载
        at(0.1) { go("c_paris") }
        at(1.0) {
            T.check(map?.state == .loaded && map?.shownCoordinateKey == paris, "next GPS photo loaded automatically in the session")
            T.check(calls.count == 2, "provider calls = \(calls.count) (expected 2)")
        }
        shot("04-auto-in-session")

        // 6 回到看过的：用缓存
        at(0.1) { go("b_shanghai") }
        at(0.7) {
            T.check(map?.state == .loaded && map?.shownCoordinateKey == shanghai, "revisit shows the map again")
            T.check(calls.count == 2, "revisit is a cache hit: provider calls still \(calls.count)")
        }

        // 7 防抖：连翻 5 张没看过的，最多 1-2 次请求
        var n0 = 0
        at(0.1) {
            n0 = calls.count
            for (i, name) in ["d_tokyo", "e_newyork", "f_sydney", "g_london", "h_rio"].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) { go(name) }
            }
        }
        at(1.2) {
            T.check(calls.count - n0 <= 2, "debounce: 5 rapid switches made \(calls.count - n0) provider call(s)")
            T.check(map?.state == .loaded && map?.shownCoordinateKey == rio, "after rapid switching the last photo's map is shown")
        }

        // 8 晚到的结果：慢的假请求还没回来就翻走
        at(0.1) { delay = 1.0; n0 = calls.count; go("d_tokyo") }
        at(0.55) { T.check(calls.count - n0 == 1, "slow request for tokyo is in flight") }
        at(0.0) { go("e_newyork") }
        at(0.9) {
            T.check(map?.state == .loaded ? false : map?.shownCoordinateKey != tokyo, "stale guard: tokyo's late result was discarded (shown key \(map?.shownCoordinateKey ?? "none"), state \(String(describing: map?.state)))")
        }
        at(0.7) {
            T.check(map?.state == .loaded && map?.shownCoordinateKey == newyork, "stale guard: the current photo's own result is shown")
            T.check(calls.count - n0 == 2, "stale guard: two requests were made in total (\(calls.count - n0))")
            T.check(cancels >= 1, "in-flight request was cancelled on switch (cancels=\(cancels))")
        }
        var detached: LocationMapView?
        at(0.1) { go("f_sydney") }
        at(0.55) { detached = map; go("i_nogps") }
        at(1.2) {
            T.check(map == nil, "switching to a photo without GPS removes the map")
            T.check(detached?.state == .idle && detached?.shownCoordinateKey == nil, "late result for a photo that was left is discarded (state \(String(describing: detached?.state)))")
            delay = 0.15
        }

        // 9 失败：一行小字，不重试
        at(0.1) { failNext = true; n0 = calls.count; go("f_sydney") }
        at(0.9) {
            T.check(map?.state == .failed, "offline/failed request shows the failure state")
            T.check(map?.debugFailedText == L10n.t("info.map.failed", "地图加载不了"), "failure text is shown")
            T.check(calls.count - n0 == 1, "failure: one request")
        }
        shot("05-failed")
        at(1.2) {
            T.check(calls.count - n0 == 1, "failure: no retry loop (calls \(calls.count - n0))")
            failNext = false
        }

        // 10 设置里打开了自动显示：直接加载
        at(0.1) { LocationMap.sessionAuto = false; LocationMap.autoShow = true; n0 = calls.count; go("g_london") }
        at(0.9) {
            T.check(map?.state == .loaded, "auto-show setting on: loads without a click")
            T.check(calls.count - n0 == 1, "auto-show: one request")
            T.check(UserDefaults.standard.bool(forKey: LocationMap.autoKey), "setting persisted in the test bundle's own preferences")
        }
        shot("06-auto-show-setting-on")

        // 11 设置窗口里的开关
        at(0.1) { LocationMap.autoShow = false; LocationMap.sessionAuto = true; SettingsWindowController.shared.show(.viewing) }
        at(0.6) {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == L10n.t("set.infoMap", "在信息面板里显示位置地图") { return b }
                for s in v.subviews { if let b = find(s) { return b } }
                return nil
            }
            let box = SettingsWindowController.shared.window?.contentView.flatMap(find)
            T.check(box != nil, "Settings > Viewing has the location map checkbox")
            T.check(box?.state == .off, "checkbox reflects the off setting")
            box?.performClick(nil)
            T.check(LocationMap.autoShow, "checking it turns the persisted setting on")
            box?.performClick(nil)
            T.check(!LocationMap.autoShow && !LocationMap.sessionAuto, "unchecking it turns the setting off and ends session auto-load")
            SettingsWindowController.shared.window?.orderOut(nil)
        }

        // 12 「以后自动显示」：占位里点它，写进设置并加载（这时看过的地方走缓存）
        at(0.1) { n0 = calls.count; go("c_paris") }
        at(0.7) {
            T.check(map?.state == .placeholder, "session and setting both off: back to the placeholder even for a cached place")
            T.check(calls.count == n0, "placeholder again: no request")
            map?.debugAlwaysClicked()
        }
        at(0.5) {
            T.check(UserDefaults.standard.bool(forKey: LocationMap.autoKey), "always-show link turned the persisted setting on")
            T.check(map?.state == .loaded && map?.shownCoordinateKey == paris, "always-show link loads the map")
        }

        // 13 深浅色：窗口原本是哪种，就换成另一种，要新请求一张；换回来用缓存
        var startDark = true
        at(0.1) {
            startDark = calls.last?.dark ?? true
            n0 = calls.count
            self.view.window?.appearance = NSAppearance(named: startDark ? .aqua : .darkAqua)
        }
        at(0.8) {
            T.check(calls.count - n0 == 1 && calls.last?.dark == !startDark, "appearance change requested a \(startDark ? "light" : "dark") snapshot (calls \(calls.count - n0))")
            T.check(map?.state == .loaded, "snapshot for the other appearance shown")
        }
        shot("07-other-appearance")
        at(0.1) { n0 = calls.count; self.view.window?.appearance = NSAppearance(named: startDark ? .darkAqua : .aqua) }
        at(0.6) {
            T.check(calls.count == n0 && map?.state == .loaded, "back to the first appearance: cache hit, no request")
            self.view.window?.appearance = nil
        }

        // 14 面板收起：不请求；再打开才请求
        at(0.1) { n0 = calls.count; go("d_tokyo") }
        at(0.05) { self.exifPanel.isHidden = true }
        at(0.8) {
            T.check(calls.count == n0, "panel hidden before the debounce ended: zero requests (\(calls.count - n0))")
            T.check((map?.state ?? .idle) == .idle, "hidden panel: map is idle (no pending work)")
            self.toggleInfoPanel(nil)
        }
        at(0.9) {
            T.check(map?.state == .loaded && map?.shownCoordinateKey == tokyo && calls.count - n0 == 1, "reopened panel loads the map once (calls \(calls.count - n0))")
        }

        // 15 「全部」级别里也排在拍摄地点下面
        at(0.1) { InfoLevel.current = .all }
        at(0.7) { T.check(map?.state == .loaded, "info level All shows the map as well") }
        shot("08-all-level")
        at(0.1) {
            InfoLevel.current = savedLevel
            LocationMap.autoShow = false
            LocationMap.sessionAuto = false
            T.finish()
        }
        runNext()
    }

    /// 只截信息面板这一块：按窗口号取整个窗口，再裁出面板的范围
    func shotPanel(to path: String) {
        guard let w = view.window,
              let full = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            MapSelfTest.check(false, "screenshot failed for \(path)")
            return
        }
        let scale = CGFloat(full.width) / w.frame.width
        let r = exifPanel.convert(exifPanel.bounds, to: nil).insetBy(dx: -10, dy: -10)
        let crop = CGRect(x: max(0, r.minX * scale), y: max(0, (w.frame.height - r.maxY) * scale), width: r.width * scale, height: r.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard let img = full.cropping(to: crop), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
            MapSelfTest.check(false, "screenshot crop failed for \(path)")
            return
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("MAPTEST shot \(path)")
    }
}

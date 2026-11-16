import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --watermarktest <工作文件夹>`：导出水印的自测。工作文件夹里要有 data/small（几张小图，一张横的一张竖的）。
/// 渲染器（覆盖、位置、大小随分辨率、不透明度 0、占位符、色彩空间、位深、速度）、导出流程（⌘S、批量、预设、大小限制、元数据、原文件不变、
/// 视频和动图跳过）、样式存取、logo、三个导出窗口里的「水印」一行、编辑窗口和菜单，以及各处截图。
/// 要在带自己 bundle id 的测试 .app 里跑。最后一行 WATERMARKTEST checks=N failures=M 是汇总
enum WatermarkSelfTest {
    static var checks = 0
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("WATERMARKTEST \(ok ? "ok  " : "FAIL") \(what)")
    }
    static func info(_ s: String) { print("WATERMARKTEST info \(s)") }

    static func spin(_ timeout: Double, until cond: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }

    static func sha(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "-" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func finish(_ reason: String? = nil) -> Never {
        if let reason { check(false, reason) }
        print("WATERMARKTEST checks=\(checks) failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 像素

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 纯色图
    static func solid(_ w: Int, _ h: Int, space: CGColorSpace = srgb, deep: Bool = false, rgb: [CGFloat] = [0.50, 0.55, 0.60]) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: rgb + [1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// 画进 sRGB 8 位 RGBA（比较用）
    static func rgba(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: srgb,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
        }
        return buf
    }

    struct Change {
        var count = 0
        /// 有变化的范围（图像坐标，原点在左上）
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var w = 0, h = 0
        var quadrants = [0, 0, 0, 0]   // 左上 右上 左下 右下
        var center = 0
        var fraction: Double { Double(count) / Double(max(1, w * h)) }
        var box: CGRect { maxX < 0 ? .zero : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) }
    }

    /// 两张图哪些像素不一样（任一通道差超过 threshold）
    static func changes(_ a: CGImage, _ b: CGImage, threshold: Int = 2) -> Change {
        var c = Change()
        // 大小限制的导出两边高度可能差一个像素：裁成一样大再比
        guard abs(a.width - b.width) <= 2, abs(a.height - b.height) <= 2 else { return c }
        let w = min(a.width, b.width), h = min(a.height, b.height)
        let a = a.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? a, b = b.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? b
        c.w = w; c.h = h
        let pa = rgba(a), pb = rgba(b)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if abs(Int(pa[o]) - Int(pb[o])) > threshold || abs(Int(pa[o + 1]) - Int(pb[o + 1])) > threshold || abs(Int(pa[o + 2]) - Int(pb[o + 2])) > threshold {
                    c.count += 1
                    c.minX = min(c.minX, x); c.maxX = max(c.maxX, x); c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                    c.quadrants[(y >= h / 2 ? 2 : 0) + (x >= w / 2 ? 1 : 0)] += 1
                    if x > w * 2 / 5 && x < w * 3 / 5 && y > h * 2 / 5 && y < h * 3 / 5 { c.center += 1 }
                }
            }
        }
        return c
    }

    /// 原始像素字节（不经过色彩转换），比较「没动的地方一个字节都没变」用
    static func rawBytes(_ img: CGImage, x: Int, y: Int, w: Int, h: Int) -> [UInt8] {
        guard let data = img.dataProvider?.data as Data? else { return [] }
        let bpp = img.bitsPerPixel / 8
        var out: [UInt8] = []
        for yy in y..<(y + h) {
            let o = yy * img.bytesPerRow + x * bpp
            out.append(contentsOf: data[o..<(o + w * bpp)])
        }
        return out
    }

    static func bytesEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == b.bitsPerPixel else { return false }
        return rawBytes(a, x: 0, y: 0, w: a.width, h: a.height) == rawBytes(b, x: 0, y: 0, w: b.width, h: b.height)
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    /// 两张图各缩成 200×300 的小图，平均每个通道差多少
    static func thumbDiff(_ a: CGImage, _ b: CGImage) -> Double {
        func thumb(_ i: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: 200 * 300 * 4)
            buf.withUnsafeMutableBytes { p in
                if let c = CGContext(data: p.baseAddress, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    c.interpolationQuality = .high
                    c.draw(i, in: CGRect(x: 0, y: 0, width: 200, height: 300))
                }
            }
            return buf
        }
        let pa = thumb(a), pb = thumb(b)
        var sum = 0, n = 0
        for i in stride(from: 0, to: pa.count, by: 4) { for c in 0..<3 { sum += abs(Int(pa[i + c]) - Int(pb[i + c])); n += 1 } }
        return Double(sum) / Double(n)
    }

    static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

    static func writePNG(_ img: CGImage, _ url: URL) {
        guard let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
        try? d.write(to: url)
    }

    /// 本进程窗口（连同面板）抓成 PNG，按窗口号取图
    @discardableResult
    static func shootWindow(_ w: NSWindow?, _ path: URL) -> Bool {
        guard let w, let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
              let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        return (try? d.write(to: path)) != nil
    }

    // MARK: - 造图

    /// 证件样的测试图：灰桌面上一张浅色卡片，照片位、几条线、几行假文字（全是虚构的示意内容）
    static func makeIDCard(_ url: URL) {
        let w = 1800, h = 1200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.36, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let card = CGRect(x: 110, y: 130, width: 1580, height: 940)
        ctx.setFillColor(CGColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 46, cornerHeight: 46, transform: nil)); ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.20, green: 0.38, blue: 0.62, alpha: 1))
        ctx.fill(CGRect(x: card.minX, y: card.maxY - 150, width: card.width, height: 150))
        ctx.setFillColor(CGColor(gray: 0.62, alpha: 1))
        ctx.fill(CGRect(x: card.maxX - 480, y: card.minY + 130, width: 360, height: 480))
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: card.maxX - 400, y: card.minY + 330, width: 200, height: 200))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor(white: 0.12, alpha: 1)]
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 54, color: NSColor = NSColor(white: 0.12, alpha: 1)) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(a)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        _ = attrs
        text("SAMPLE CARD  /  示意证件", card.minX + 60, card.maxY - 100, size: 62, color: .white)
        text("NAME   ZHANG SAN (SAMPLE)", card.minX + 70, card.maxY - 280)
        text("DATE OF BIRTH   2000-01-01", card.minX + 70, card.maxY - 380)
        text("NUMBER   0000 0000 0000 0000", card.minX + 70, card.maxY - 480)
        text("VALID   2030-12-31", card.minX + 70, card.maxY - 580)
        text("ADDRESS   NO. 0 SAMPLE ROAD", card.minX + 70, card.maxY - 680)
        ctx.setFillColor(CGColor(gray: 0.7, alpha: 1))
        ctx.fill(CGRect(x: card.minX + 70, y: card.minY + 90, width: 900, height: 22))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// 带透明背景的 logo：红色圆环 + 里面一个实心圆，圆环以外全透明
    static func makeLogoPNG(_ url: URL) {
        let n = 400
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)); ctx.setLineWidth(40)
        ctx.strokeEllipse(in: CGRect(x: 40, y: 40, width: n - 80, height: n - 80))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 150, y: 150, width: 100, height: 100))
        writePNG(ctx.makeImage()!, url)
    }

    static func makeGIF(_ url: URL, frames: Int) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        for i in 0..<frames { CGImageDestinationAddImage(dest, solid(64, 48, rgb: [CGFloat(i) / 4, 0.5, 0.5]), nil) }
        CGImageDestinationFinalize(dest)
    }
}

extension ViewerViewController {
    func runWatermarkTest(outDir: String) {
        typealias T = WatermarkSelfTest
        typealias X = ExportSelfTest
        setvbuf(stdout, nil, _IOLBF, 0)
        let fm = FileManager.default
        let work = URL(fileURLWithPath: outDir)
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        let data = work.appendingPathComponent("data/small")
        let uiOnly = CommandLine.arguments.contains("--ui-only")
        T.info("language=\(lang) bundle=\(bundleID) exiftool=\(X.exiftoolPath ?? "none") uiOnly=\(uiOnly)")
        T.check(bundleID != "com.xmasdong.photoview" && !bundleID.isEmpty, "isolated: test bundle id is \(bundleID), not the real prefs domain")
        let jpgs = ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
        guard jpgs.count >= 2 else { T.finish("test data missing: \(data.path) needs at least two .jpg files (see the header of WatermarkSelfTest.swift)") }
        guard X.exiftoolPath != nil else { T.finish("exiftool missing (brew install exiftool)") }

        // 一切都在自己的文件夹里：水印样式、记住的选择、预设都不碰真的
        let run = work.appendingPathComponent("run")
        let shots = work.appendingPathComponent("shots-\(lang)")
        let outs = work.appendingPathComponent("exports-\(lang)")
        for d in [run, shots, outs] {
            try? fm.removeItem(at: d)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let suite = UserDefaults(suiteName: "\(bundleID).wm.\(UUID().uuidString)")!
        WatermarkMemory.defaults = suite
        let storeDir = run.appendingPathComponent("store")
        WatermarkStore.shared = WatermarkStore(directory: storeDir)
        let store = WatermarkStore.shared
        #if FLIPIC_PRO
        ExportPresetStore.shared = ExportPresetStore(defaults: UserDefaults(suiteName: "\(bundleID).wm.presets.\(UUID().uuidString)")!)
        #endif

        // 测试照片
        let photos = run.appendingPathComponent("photos")
        try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let src = photos.appendingPathComponent("p3.jpg")
        X.makeSource(src)
        let idcard = photos.appendingPathComponent("idcard-sample.jpg")
        T.makeIDCard(idcard)
        let portraitURL = jpgs.first { X.size($0).1 > X.size($0).0 } ?? jpgs[0]
        let landscapeURL = jpgs.first { X.size($0).0 > X.size($0).1 } ?? jpgs[1]
        let portrait = photos.appendingPathComponent("portrait.jpg"), landscape = photos.appendingPathComponent("landscape.jpg")
        try? fm.copyItem(at: portraitURL, to: portrait)
        try? fm.copyItem(at: landscapeURL, to: landscape)
        let originals = [src, idcard, portrait, landscape]
        let shaBefore = originals.map { T.sha($0) }

        let builtIn = { (b: WatermarkBuiltIn) -> WatermarkStyle in store.styles.first { $0.builtIn == b.rawValue }! }

        // ===== 1. 样式模型与存取 =====
        T.check(store.styles.count == 3 && store.styles.map { $0.builtIn ?? "" } == ["id", "proof", "sign"], "store: first use creates the three built-in styles")
        T.check(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("styles.json").path), "store: styles.json written in the store directory")
        let id = builtIn(.id), proof = builtIn(.proof), sign = builtIn(.sign)
        T.check(id.layout == .tiled && proof.layout == .tiled && sign.layout == .single && sign.anchor == .bottomRight, "store: built-in layouts (tiled, tiled, single bottom-right)")
        T.check(id.displayName == WatermarkBuiltIn.id.defaultName && id.resolvedText == WatermarkBuiltIn.id.defaultText, "store: built-in name and text follow the UI language (\(id.displayName) / \(id.resolvedText))")
        T.check(abs(id.opacity - 0.32) < 0.05 && abs(proof.opacity - 0.24) < 0.05 && abs(sign.opacity - 0.7) < 0.05, "store: built-in opacities ~28% / ~22% / ~70% family")
        T.info("built-in names: \(store.styles.map(\.displayName)) texts: \(store.styles.map(\.resolvedText))")
        // 容错读取
        let weird = #"{"id":"6F1D5A10-0000-4000-8000-000000000999","opacity":"oops","size":99,"angle":"x","layout":"spiral","customColor":[1,2],"extra":true}"#
        let w1 = try? JSONDecoder().decode(WatermarkStyle.self, from: Data(weird.utf8))
        T.check(w1 != nil && w1!.opacity == 0.3 && w1!.size == WatermarkStyle.sizeRange.upperBound && w1!.angle == -30 && w1!.layout == .tiled && w1!.customColor.count == 3, "style: tolerant decoding (bad types and unknown values fall back, numbers clamped)")
        let empty = try? JSONDecoder().decode(WatermarkStyle.self, from: Data("{}".utf8))
        T.check(empty != nil && empty! == { var e = WatermarkStyle(); e.id = empty!.id; return e }(), "style: empty JSON decodes to the defaults")
        // 增删改复制
        let added = store.addNew()
        T.check(added != nil && store.styles.count == 4 && added!.displayName.contains("1"), "store: add creates a new style named \(added?.displayName ?? "-")")
        var edited = added!; edited.text = "Line one\nLine two"; edited.opacity = 0.5
        store.update(edited)
        let dup = store.duplicate(id: edited.id)
        T.check(dup != nil && dup!.id != edited.id && dup!.text == edited.text && dup!.builtIn == nil && store.styles.count == 5, "store: duplicate copies the style, new id")
        let dupBuiltIn = store.duplicate(id: id.id)
        T.check(dupBuiltIn?.builtIn == nil && dupBuiltIn?.text == id.resolvedText, "store: duplicating a built-in gives an ordinary style with the text frozen")
        let reloaded = WatermarkStore(directory: storeDir)
        T.check(reloaded.styles == store.styles, "store: round trip through styles.json (\(reloaded.styles.count) styles equal)")
        store.remove(id: dup!.id); store.remove(id: dupBuiltIn!.id); store.remove(id: edited.id)
        T.check(store.styles.count == 3, "store: delete")
        store.remove(id: sign.id)
        T.check(store.styles.count == 2 && WatermarkStore(directory: storeDir).styles.count == 2, "store: delete a built-in persists")
        var changedID = id; changedID.opacity = 0.9; changedID.text = "custom"
        store.update(changedID)
        store.resetBuiltIns()
        T.check(store.styles.count == 3 && store.style(id: id.id)?.opacity == id.opacity && store.style(id: id.id)?.text == "" && store.styles.contains { $0.builtIn == "sign" }, "store: reset built-ins restores edited and deleted ones")
        try? Data("not json".utf8).write(to: storeDir.appendingPathComponent("styles.json"))
        T.check(WatermarkStore(directory: storeDir).styles.count == 3, "store: corrupt file falls back to the built-ins, no crash")
        store.reload()
        T.check(store.styles.count == 3, "store: reload after corrupt file")
        // 占位符
        let day = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 3, day: 5).date!
        T.check(WatermarkTokens.expand("A {date} B {NAME} C {other} D {", fileName: "IMG_1", date: day) == "A 2026-03-05 B IMG_1 C {other} D {", "tokens: {date} {name} expand, unknown braces stay")
        T.check(WatermarkTokens.expand("no tokens", fileName: nil, date: day) == "no tokens", "tokens: plain text unchanged")

        // ===== 2. 渲染器 =====
        let flat = T.solid(1200, 800)
        let tiledID = id.frozen()
        let r1 = WatermarkRenderer.render(flat, style: tiledID, fileName: "x")
        let r1b = WatermarkRenderer.render(flat, style: tiledID, fileName: "x")
        T.check(r1 != nil && r1!.width == 1200 && r1!.height == 800, "render: output has the same pixel size")
        let ch = r1.map { T.changes(flat, $0) } ?? T.Change()
        T.check(ch.count > 1000, "render: tiled output differs from the input (\(ch.count) pixels changed)")
        T.check(r1 != nil && r1b != nil && T.bytesEqual(r1!, r1b!), "render: deterministic (two runs, identical bytes)")
        T.check(ch.quadrants.allSatisfy { Double($0) > Double(ch.w * ch.h / 4) * 0.02 } && Double(ch.center) > Double(ch.w * ch.h) * 0.2 * 0.02,
                "render: tiled covers all four quadrants and the centre \(ch.quadrants) centre=\(ch.center)")
        T.check(ch.minX < 60 && ch.minY < 60 && ch.maxX > 1200 - 60 && ch.maxY > 800 - 60, "render: tiled reaches the corners box=\(ch.box)")
        // 一张证件上，任意一条水平的「字段」（横条）都被盖到：把图分成 8 条横带，每条都有水印
        var bandsHit = 0
        if let r1 {
            let pa = T.rgba(flat), pb = T.rgba(r1)
            for band in 0..<8 {
                var hit = 0
                for y in (band * 100)..<(band * 100 + 100) { for x in stride(from: 0, to: 1200, by: 2) { let o = (y * 1200 + x) * 4; if abs(Int(pa[o]) - Int(pb[o])) > 2 { hit += 1 } } }
                if hit > 20 { bandsHit += 1 }
            }
        }
        T.check(bandsHit == 8, "render: every horizontal band of the photo carries the mark (\(bandsHit)/8)")
        // 不透明度 0：原样
        var zero = tiledID; zero.opacity = 0
        let r0 = WatermarkRenderer.render(flat, style: zero, fileName: "x")
        T.check(r0 != nil && T.bytesEqual(r0!, flat), "render: opacity 0 returns the input unchanged")
        T.check(WatermarkRenderer.render(flat, style: tiledID, text: "   \n ", fileName: "x") == nil, "render: blank text cannot be drawn (nil, never a silent no-op)")
        // 单个：九个位置
        var one = sign.frozen(); one.opacity = 1; one.size = 0.05; one.edge = .none; one.margin = 0.03
        var anchorOK = 0
        for a in WatermarkStyle.Anchor.allCases {
            one.anchor = a
            guard let r = WatermarkRenderer.render(flat, style: one, text: "MARK", fileName: nil) else { continue }
            let c = T.changes(flat, r)
            let cx = Double(c.box.midX) / 1200, cy = Double(c.box.midY) / 800
            let col = Int(cx * 3), row = Int(cy * 3)
            if col == a.column && row == a.row && c.count > 100 {
                // 离边的距离 ≈ 边距（占长边的比例），中间的不看
                let m = 0.03 * 1200
                var ok = true
                if a.column == 0 { ok = ok && abs(Double(c.minX) - m) < 6 }
                if a.column == 2 { ok = ok && abs(1200 - Double(c.maxX + 1) - m) < 6 }
                if a.row == 0 { ok = ok && abs(Double(c.minY) - m) < 8 }
                if a.row == 2 { ok = ok && abs(800 - Double(c.maxY + 1) - m) < 8 }
                if ok { anchorOK += 1 } else { T.info("anchor \(a) box=\(c.box) margin off") }
            } else { T.info("anchor \(a): cell (\(col),\(row)) expected (\(a.column),\(a.row)) count=\(c.count)") }
        }
        T.check(anchorOK == 9, "render: single mark lands in the right cell, at the margin, for all 9 anchors (\(anchorOK)/9)")
        // 大小随分辨率
        let small = T.solid(1000, 667), big = T.solid(6000, 4000)
        let sSmall = WatermarkRenderer.render(small, style: tiledID, fileName: "x"), sBig = WatermarkRenderer.render(big, style: tiledID, fileName: "x")
        let cS = sSmall.map { T.changes(small, $0) } ?? T.Change(), cB = sBig.map { T.changes(big, $0) } ?? T.Change()
        func cells(_ a: CGImage, _ b: CGImage) -> Double {
            // 60×40 的格子里有多少格被动过：和像素大小无关，只看水印铺了多大一片
            let pa = T.rgba(a), pb = T.rgba(b), w = a.width, h = a.height
            var touched = Set<Int>()
            for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) {
                let o = (y * w + x) * 4
                if abs(Int(pa[o]) - Int(pb[o])) > 2 || abs(Int(pa[o + 1]) - Int(pb[o + 1])) > 2 { touched.insert((y * 40 / h) * 60 + x * 60 / w) }
            } }
            return Double(touched.count) / 2400
        }
        let covS = sSmall.map { cells(small, $0) } ?? 0, covB = sBig.map { cells(big, $0) } ?? 0
        T.check(cS.count > 0 && abs(covS - covB) < 0.06 && covS > 0.5, "render: tiled coverage is the same at 1000 px and 6000 px (grid cells touched \(String(format: "%.3f", covS)) vs \(String(format: "%.3f", covB)); pixel share \(String(format: "%.3f", cS.fraction)) vs \(String(format: "%.3f", cB.fraction)))")
        let oS = WatermarkRenderer.render(small, style: one, text: "MARK", fileName: nil), oB = WatermarkRenderer.render(big, style: one, text: "MARK", fileName: nil)
        let bS = oS.map { T.changes(small, $0).box } ?? .zero, bB = oB.map { T.changes(big, $0).box } ?? .zero
        T.check(bS.width > 0 && abs(bS.width / 1000 - bB.width / 6000) < 0.01 && abs(bS.height / 667 - bB.height / 4000) < 0.01,
                "render: single mark is the same relative size at 1000 px and 6000 px (\(String(format: "%.3f", bS.width / 1000)) vs \(String(format: "%.3f", bB.width / 6000)))")
        // 占位符 = 手写的字
        let t1 = WatermarkRenderer.render(flat, style: sign.frozen(), text: "{date} {name}", fileName: "IMG_1", date: day)
        let t2 = WatermarkRenderer.render(flat, style: sign.frozen(), text: "2026-03-05 IMG_1", fileName: nil, date: day)
        T.check(t1 != nil && t2 != nil && T.bytesEqual(t1!, t2!), "render: {date} and {name} render exactly like the literal text")
        // 色彩空间、位深
        let spaces: [(String, CGColorSpace)] = [("sRGB", T.srgb), ("Display P3", CGColorSpace(name: CGColorSpace.displayP3)!), ("Adobe RGB", CGColorSpace(name: CGColorSpace.adobeRGB1998)!)]
        for (name, cs) in spaces {
            let vivid = T.solid(900, 600, space: cs, rgb: [0.9, 0.2, 0.3])
            guard let r = WatermarkRenderer.render(vivid, style: sign.frozen(), text: "TEST", fileName: nil) else { T.check(false, "colour space \(name): render failed"); continue }
            // 角上没盖到的像素一个字节都不变（没有色彩转换）
            let untouched = T.rawBytes(vivid, x: 0, y: 0, w: 40, h: 40) == T.rawBytes(r, x: 0, y: 0, w: 40, h: 40)
            T.check(r.colorSpace?.name == cs.name && r.bitsPerComponent == 8 && untouched,
                    "colour space \(name) preserved (\(r.colorSpace?.name as String? ?? "-")), 8-bit kept, untouched pixels byte-identical")
        }
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let deep = T.solid(900, 600, space: p3, deep: true, rgb: [0.9, 0.2, 0.3])
        let rDeep = WatermarkRenderer.render(deep, style: sign.frozen(), text: "TEST", fileName: nil)
        T.check(rDeep != nil && rDeep!.bitsPerComponent == 16 && rDeep!.colorSpace?.name == p3.name && T.rawBytes(deep, x: 0, y: 0, w: 40, h: 40) == T.rawBytes(rDeep!, x: 0, y: 0, w: 40, h: 40),
                "bit depth: a 16-bit Display P3 input stays 16-bit Display P3, untouched pixels identical")
        // 速度
        let mp24 = T.solid(6000, 4000, space: p3)
        var times: [Double] = []
        for _ in 0..<7 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = WatermarkRenderer.render(mp24, style: tiledID, fileName: "x")
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        var timesProof: [Double] = []
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = WatermarkRenderer.render(mp24, style: proof.frozen(), fileName: "x")
            timesProof.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        var timesSign: [Double] = []
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = WatermarkRenderer.render(mp24, style: sign.frozen(), fileName: "x")
            timesSign.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        #if DEBUG
        let budget = 600.0
        #else
        let budget = 60.0
        #endif
        var phases: [String: Double] = [:]
        WatermarkRenderer.profile = { phases[$0, default: 0] += $1 }
        _ = WatermarkRenderer.render(mp24, style: proof.frozen(), fileName: "x")
        WatermarkRenderer.profile = nil
        T.info("perf phases for 'proof' (ms, one run): " + phases.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " "))
        phases = [:]
        WatermarkRenderer.profile = { phases[$0, default: 0] += $1 }
        _ = WatermarkRenderer.render(mp24, style: tiledID, fileName: "x")
        WatermarkRenderer.profile = nil
        T.info("perf phases for 'id' (ms, one run): " + phases.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " "))
        T.info(String(format: "perf 24 MP (6000x4000 Display P3): tiled 'id' median %.1f ms (min %.1f, max %.1f); tiled 'proof' (shadow edge) median %.1f ms; single 'sign' median %.1f ms; budget %.0f ms",
                      T.median(times), times.min() ?? 0, times.max() ?? 0, T.median(timesProof), T.median(timesSign), budget))
        T.check(T.median(times) < budget && T.median(timesProof) < budget * 1.6, "perf: 24 MP tiled render median \(Int(T.median(times))) ms / \(Int(T.median(timesProof))) ms with shadow (budget \(Int(budget)) ms)")

        // logo（带透明背景的 PNG）
        let logoSrc = run.appendingPathComponent("logo.png")
        T.makeLogoPNG(logoSrc)
        guard let logoFile = store.importLogo(from: logoSrc) else { T.finish("logo import failed") }
        T.check(fm.fileExists(atPath: store.logoURL(logoFile).path) && store.logoURL(logoFile).deletingLastPathComponent().path == storeDir.path, "logo: copied into the store folder as \(logoFile)")
        T.check(store.importLogo(from: logoSrc) == logoFile, "logo: the same picture is stored once")
        var logoStyle = WatermarkStyle()
        logoStyle.kind = .image; logoStyle.imageFile = logoFile; logoStyle.layout = .single; logoStyle.anchor = .bottomRight; logoStyle.size = 0.18; logoStyle.opacity = 1; logoStyle.margin = 0.04
        let lr = WatermarkRenderer.render(flat, job: WatermarkJob(style: logoStyle), fileName: nil, store: store)
        let lc = lr.map { T.changes(flat, $0) } ?? T.Change()
        T.check(lc.count > 500 && lc.box.midX > 600 && lc.box.midY > 400, "logo: single image watermark drawn bottom-right (\(lc.count) px)")
        // 透明的地方不动：logo 的方形范围里，圆环以外的角上还是原来的灰
        if let lr {
            let a = T.rgba(flat), b = T.rgba(lr)
            let cornerX = Int(lc.box.minX) + 2, cornerY = Int(lc.box.minY) + 2
            let o = (cornerY * 1200 + cornerX) * 4
            T.check(a[o] == b[o] && a[o + 1] == b[o + 1] && a[o + 2] == b[o + 2], "logo: transparent corner of the logo leaves the photo untouched")
            T.check(b[(Int(lc.box.midY) * 1200 + Int(lc.box.midX)) * 4] > 150 && b[(Int(lc.box.midY) * 1200 + Int(lc.box.midX)) * 4 + 1] < 90, "logo: opaque centre is the logo's red")
        }
        var logoTiled = logoStyle; logoTiled.layout = .tiled; logoTiled.size = 0.08; logoTiled.opacity = 0.4
        let ltr = WatermarkRenderer.render(flat, job: WatermarkJob(style: logoTiled), fileName: nil, store: store)
        let ltc = ltr.map { T.changes(flat, $0) } ?? T.Change()
        T.check(ltc.quadrants.allSatisfy { $0 > 300 } && ltc.center > 100, "logo: tiled logo covers every quadrant and the centre \(ltc.quadrants)")
        try? fm.removeItem(at: logoSrc)
        let lr2 = WatermarkRenderer.render(flat, job: WatermarkJob(style: logoStyle), fileName: nil, store: store)
        T.check(lr != nil && lr2 != nil && T.bytesEqual(lr!, lr2!), "logo: still renders identically after the source file is deleted")
        var missing = logoStyle; missing.imageFile = "does-not-exist.png"
        T.check(WatermarkRenderer.render(flat, job: WatermarkJob(style: missing), fileName: nil, store: store) == nil, "logo: a missing logo file cannot be drawn (nil)")

        // ===== 3. 导出流程 =====
        let jobID = WatermarkJob(style: id, text: nil)
        let base = ExportOptions()
        func plain(_ n: String, _ o: ExportOptions = ExportOptions(), uti: String = "public.jpeg", from: URL = src) -> URL {
            let u = outs.appendingPathComponent(n)
            _ = X.uiExport(from, u, uti: uti, o)
            return u
        }
        var wmOpts = base; wmOpts.watermark = jobID
        let pPlain = plain("plain.jpg"), pMarked = plain("marked.jpg", wmOpts)
        T.check(fm.fileExists(atPath: pMarked.path) && X.size(pMarked) == X.size(pPlain), "export: watermarked file written, same pixel size \(X.size(pMarked))")
        if let a = T.decode(pPlain), let b = T.decode(pMarked) {
            let c = T.changes(a, b, threshold: 6)
            T.check(c.fraction > 0.05 && c.quadrants.allSatisfy { $0 > 1000 }, "export: watermark visible all over the exported photo (\(String(format: "%.1f", c.fraction * 100))% pixels changed)")
        } else { T.check(false, "export: could not decode outputs") }
        // 元数据
        let eM = X.exif(pMarked)
        T.check(X.val(eM, "Make") == "TESTCAM" && X.has(eM, "GPSLatitude") && X.val(eM, "CopyrightNotice") == "(c) 2024 Zhang San" && X.val(eM, "Custom") == "kept-through-export",
                "metadata: watermarked export keeps EXIF, GPS, IPTC and XMP like a plain export")
        T.check(X.profile(eM).contains("P3") && (X.props(pMarked)["Orientation"] as? Int ?? 1) == 1, "metadata: Display P3 profile kept, orientation 1")
        var noGPS = wmOpts; noGPS.stripGPS = true
        let eG = X.exif(plain("marked-nogps.jpg", noGPS))
        T.check(!X.anyKey(eG, prefix: "GPS") && !X.has(eG, "GPSLatitude") && X.val(eG, "Make") == "TESTCAM", "metadata: strip-GPS option still strips GPS on a watermarked export")
        var noMeta = wmOpts; noMeta.keepMetadata = false
        let eN = X.exif(plain("marked-nometa.jpg", noMeta))
        T.check(!X.has(eN, "Make") && !X.has(eN, "GPSLatitude") && !X.has(eN, "CopyrightNotice"), "metadata: keep-metadata off strips everything on a watermarked export")
        // sRGB 转换：水印在原色域里画，再转
        var toSRGB = wmOpts; toSRGB.toSRGB = true
        let uS = plain("marked-srgb.jpg", toSRGB)
        T.check(X.profile(X.exif(uS)).contains("sRGB"), "export: sRGB conversion applied after the watermark (\(X.profile(X.exif(uS))))")
        // 长边
        var long = wmOpts; long.maxLongEdge = 800
        let uL = plain("marked-800.jpg", long)
        T.check(X.size(uL) == (533, 800), "export: long-edge limit with watermark \(X.size(uL))")
        if let a = T.decode(plain("plain-800.jpg", { var o = base; o.maxLongEdge = 800; return o }())), let b = T.decode(uL) {
            let c = T.changes(a, b, threshold: 6)
            T.check(c.fraction > 0.05, "export: watermark relative size/coverage survives the resize (\(String(format: "%.1f", c.fraction * 100))%)")
        }
        // 大小限制
        var limited = wmOpts; limited.maxBytes = 120_000
        let uB = outs.appendingPathComponent("marked-120k.jpg")
        let rB = X.uiExport(src, uB, limited)
        T.check(rB != nil && rB!.limitMet && X.bytes(uB) <= 120_000, "size limit: watermarked result fits 120 KB (\(X.bytes(uB)) bytes, q=\(rB?.quality ?? -1), \(X.size(uB)))")
        if let a = T.decode(plain("plain-120k.jpg", { var o = base; o.maxBytes = 120_000; return o }())), let b = T.decode(uB) {
            // 两边压出来的像素尺寸可能差几个像素：都缩成同样大的小图再比，JPEG 的噪点被平均掉，剩下的差别就是水印
            let d = T.thumbDiff(a, b)
            T.check(d > 2.0, "size limit: the limit applies to the watermarked image and the mark is in it (thumbnail mean difference \(String(format: "%.1f", d)) levels vs the unmarked 120 KB export)")
        }
        var tight = wmOpts; tight.maxBytes = 40_000
        let uT = outs.appendingPathComponent("marked-40k.jpg")
        let rT = X.uiExport(src, uT, tight)
        T.check(rT != nil && X.bytes(uT) <= 40_000 && max(X.size(uT).0, X.size(uT).1) < 1800, "size limit: tight limit shrinks the watermarked image to fit (\(X.bytes(uT)) bytes, \(X.size(uT)))")
        // HEIC、PNG
        let uH = plain("marked.heic", wmOpts, uti: "public.heic")
        let uP = plain("marked.png", wmOpts, uti: "public.png")
        T.check(X.bytes(uH) > 0 && X.bytes(uP) > 0, "export: HEIC and PNG with watermark written")
        // 画不出水印：整张导出失败，不出没水印的副本
        var blank = WatermarkStyle(); blank.text = "   "
        var badOpts = base; badOpts.watermark = WatermarkJob(style: blank)
        T.check(X.uiExport(src, outs.appendingPathComponent("blank.jpg"), badOpts) == nil && !fm.fileExists(atPath: outs.appendingPathComponent("blank.jpg").path),
                "export: a watermark that cannot be drawn fails the export instead of writing an unmarked copy")
        // 动图和视频：批量里跳过
        let gif = photos.appendingPathComponent("anim.gif"); T.makeGIF(gif, frames: 3)
        let mov = photos.appendingPathComponent("clip.mov"); try? Data(count: 2048).write(to: mov)
        T.check(!WatermarkEligibility.isStill(gif) && !WatermarkEligibility.isStill(mov) && WatermarkEligibility.isStill(src), "eligibility: animated GIF and video are not still images, a JPEG is")

        // ===== 4. 批量转换 =====
        let batchOut = run.appendingPathComponent("batch")
        var bs = BatchConvert.Settings(uti: "public.jpeg", ext: "jpg", quality: 85, options: wmOpts, outDir: batchOut)
        let sumW = BatchConvert.run([src, portrait, landscape, gif, mov], settings: bs)
        T.check(sumW.converted == 3 && sumW.skippedMotion == 2 && sumW.failed == 0, "batch: watermark converts 3 stills, skips the GIF and the video (converted=\(sumW.converted) skippedMotion=\(sumW.skippedMotion) failed=\(sumW.failed))")
        T.check(BatchConvert.message(sumW, limit: nil).contains("2"), "batch: summary mentions the skipped video/animated files")
        var allMarked = !sumW.outputs.isEmpty
        for (i, u) in sumW.outputs.enumerated() { allMarked = allMarked && T.sha(u) != T.sha([src, portrait, landscape][i]) }
        T.check(allMarked, "batch: every output differs from its source file (JPEG→JPEG is not copied unchanged)")
        // 对照：同样是 JPEG→JPEG，没有水印、没有任何限制就原样不动（跳过）
        let sumPlain = BatchConvert.run([src], settings: BatchConvert.Settings(uti: "public.jpeg", ext: "jpg", quality: 85, options: base, outDir: run.appendingPathComponent("batch-plain")))
        T.check(sumPlain.converted == 0 && sumPlain.skipped == 1, "batch: control — without a watermark the same JPEG→JPEG is skipped as 'nothing to change'")
        T.check(BatchConvert.needsWork(src, settings: bs), "batch: needsWork is true for JPEG→JPEG with a watermark")
        bs.options.watermark = nil
        T.check(!BatchConvert.needsWork(src, settings: bs), "batch: needsWork stays false without a watermark (existing behaviour unchanged)")
        // 水印 + 预设式的 alwaysWrite
        var aw = BatchConvert.Settings(uti: "public.jpeg", ext: "jpg", quality: 85, options: wmOpts, outDir: run.appendingPathComponent("batch-aw"))
        aw.alwaysWrite = true
        let sumAW = BatchConvert.run([src], settings: aw)
        T.check(sumAW.converted == 1 && T.sha(sumAW.outputs[0]) != T.sha(src), "batch: alwaysWrite + watermark writes a re-rendered, marked file")

        // ===== 5. 预设 =====
        #if FLIPIC_PRO
        let legacy = #"{"id":"6F1D5A10-0000-4000-8000-0000000000F1","name":"old","format":"JPEG","quality":85,"options":{"keepMetadata":true,"stripGPS":false,"toSRGB":false,"maxLongEdge":1600},"destination":{"kind":"ask"}}"#
        let old = try? JSONDecoder().decode(ExportPreset.self, from: Data(legacy.utf8))
        T.check(old != nil && old!.options.watermark == nil && old!.options.maxLongEdge == 1600 && old!.options.exportOptions.watermark == nil, "preset: an old preset without the watermark key loads fine, no watermark")
        let tolerant = #"{"name":"x","options":{"watermark":{"style":"garbage","text":5}}}"#
        let tol = try? JSONDecoder().decode(ExportPreset.self, from: Data(tolerant.utf8))
        T.check(tol != nil && tol!.name == "x", "preset: a damaged watermark entry does not lose the whole preset")
        var po = ExportOptions(); po.watermark = WatermarkJob(style: id, text: "仅供租房使用 {date}"); po.maxLongEdge = 1000
        let preset = ExportPreset(name: "WM test", format: "JPEG", quality: 80, options: po, destination: PresetDestination(kind: .fixed, path: run.appendingPathComponent("preset-out").path))
        let enc = try? JSONEncoder().encode([preset])
        let back = enc.flatMap { try? JSONDecoder().decode([ExportPreset].self, from: $0) }
        T.check(back?.first == preset && back?.first?.options.watermark?.style.text == id.resolvedText && back?.first?.options.watermark?.text == "仅供租房使用 {date}", "preset: full style + this-export text round-trip through JSON")
        let psSuite = UserDefaults(suiteName: "\(bundleID).wm.pstore.\(UUID().uuidString)")!
        ExportPresetStore(defaults: psSuite).add(preset)
        T.check(ExportPresetStore(defaults: psSuite).presets.first?.options.watermark == preset.options.watermark, "preset: store round-trip keeps the watermark")
        // 样式之后被改、被删，预设不受影响
        let before = preset.options.exportOptions.watermark
        var ed = store.style(id: id.id)!; ed.text = "changed later"; ed.opacity = 0.9; store.update(ed)
        T.check(preset.options.exportOptions.watermark == before && before?.style.text == id.resolvedText, "preset: editing the saved style later does not change the preset")
        store.remove(id: id.id)
        T.check(preset.options.exportOptions.watermark == before, "preset: deleting the saved style does not change the preset")
        store.resetBuiltIns()
        let psettings = preset.batchSettings(outDir: run.appendingPathComponent("preset-out"))
        let sumP = BatchConvert.run([src, portrait], settings: psettings)
        T.check(sumP.converted == 2 && sumP.failed == 0, "preset: run produces 2 files (\(sumP.converted))")
        if let u = sumP.outputs.first, let a = T.decode(plain("preset-plain.jpg", { var o = base; o.maxLongEdge = 1000; return o }())), let b = T.decode(u) {
            T.check(a.width == b.width && T.changes(a, b, threshold: 6).fraction > 0.05, "preset: output carries the watermark and honours the long-edge option (\(b.width)x\(b.height))")
        } else { T.check(false, "preset: output missing") }
        T.check(max(X.size(sumP.outputs[0]).0, X.size(sumP.outputs[0]).1) == 1000, "preset: long edge 1000 respected \(X.size(sumP.outputs[0]))")
        // {date} 在预设里每次导出时取当天
        T.check(WatermarkTokens.expand(preset.options.watermark!.effectiveText, fileName: "a", date: day).contains("2026-03-05"), "preset: {date} in the saved text is expanded at export time")
        #endif

        // ===== 6. 导出窗口里的「水印」一行 =====
        let defaultsBefore = WatermarkMemory.last(WatermarkMemory.exportKey)
        T.check(defaultsBefore == nil, "memory: nothing remembered on first run")
        func accessory(preselect: Bool = false) -> ExportAccessory {
            WatermarkMemory.forceNextExport = preselect
            return ExportAccessory(formats: ["JPEG", "PNG", "HEIC"], formatIndex: 0, quality: 85) {}
        }
        let a0 = accessory()
        T.check(a0.options.options.watermark == nil && a0.options.watermarkRow.popup.indexOfSelectedItem == 0, "row: default is none (⌘S)")
        T.check(a0.options.options == ExportOptions(), "row: with none selected the options equal the plain defaults")
        T.check(a0.options.watermarkRow.popup.itemTitles == [WatermarkRowView.noneTitle] + store.styles.map(\.displayName) + ["", WatermarkRowView.editTitle], "row: popup lists none, the styles, a separator and the editor entry \(a0.options.watermarkRow.popup.itemTitles)")
        let h0 = a0.view.frame.height
        a0.options.watermarkRow.debugSelect(1)
        a0.view.layoutSubtreeIfNeeded()
        let h1 = a0.view.frame.height
        let wj = a0.options.options.watermark
        T.check(wj != nil && wj!.style.id == id.id && wj!.text == nil, "row: choosing a style gives the full style, no text override")
        T.check(a0.options.watermarkRow.field.stringValue == id.resolvedText && !a0.options.watermarkRow.field.isHidden, "row: the text field is pre-filled with the style's text (\(a0.options.watermarkRow.field.stringValue))")
        T.check(h1 > h0, "row: the accessory grows when the text field appears (\(h0) → \(h1))")
        a0.options.watermarkRow.field.stringValue = "仅供办理租房使用"
        let wj2 = a0.options.options.watermark
        T.check(wj2?.text == "仅供办理租房使用" && wj2?.effectiveText == "仅供办理租房使用" && store.style(id: id.id)?.text == "", "row: typed text is used for this export only, the saved style is unchanged")
        a0.options.watermarkRow.field.stringValue = ""
        T.check(a0.options.options.watermark?.effectiveText == id.resolvedText, "row: clearing the field falls back to the style's text")
        a0.options.watermarkRow.debugSelect(0)
        T.check(a0.options.options.watermark == nil && a0.view.frame.height == h0, "row: choosing none removes the field again and the accessory shrinks back")
        // 排在胶片下面
        #if FLIPIC_PRO
        let rows = a0.options.arrangedSubviews
        T.check(rows.last === a0.options.watermarkRow && rows.dropLast().last?.subviews.contains(where: { ($0 as? NSPopUpButton) === a0.options.debugFilmPopup }) == true, "row: sits directly under the Film row")
        let fx = a0.options.debugFilmPopup.convert(a0.options.debugFilmPopup.bounds, to: a0.options).minX
        let wx = a0.options.watermarkRow.popup.convert(a0.options.watermarkRow.popup.bounds, to: a0.options).minX
        T.check(abs(fx - wx) < 1.0, "row: the Watermark popup lines up with the Film popup (x \(fx) vs \(wx))")
        #else
        T.check(a0.options.arrangedSubviews.last === a0.options.watermarkRow, "row: last row in the options list (public build has no Film row)")
        #endif
        // 记住上次的选择（两个窗口各记各的）
        a0.options.watermarkRow.debugSelect(2)
        a0.options.watermarkRow.rememberChoice()
        T.check(WatermarkMemory.last(WatermarkMemory.exportKey) == proof.id && WatermarkMemory.last(WatermarkMemory.batchKey) == nil, "memory: ⌘S remembers its own choice (样片), batch untouched")
        let a1 = accessory()
        T.check(a1.options.options.watermark?.style.id == proof.id && a1.options.watermarkRow.field.stringValue == proof.resolvedText, "memory: the next ⌘S panel starts with the remembered style")
        let b1 = BatchAccessory(source: src, formatIndex: 0, quality: 85)
        T.check(b1.options.options.watermark == nil, "memory: batch dialog still defaults to none")
        b1.options.watermarkRow.debugSelect(3)
        b1.options.watermarkRow.rememberChoice()
        T.check(WatermarkMemory.last(WatermarkMemory.batchKey) == sign.id && WatermarkMemory.last(WatermarkMemory.exportKey) == proof.id, "memory: batch remembers 署名 separately")
        T.check(BatchAccessory(source: src, formatIndex: 0, quality: 85).options.options.watermark?.style.id == sign.id, "memory: next batch dialog starts with the remembered style")
        a1.options.watermarkRow.debugSelect(0); a1.options.watermarkRow.rememberChoice()
        T.check(accessory().options.options.watermark == nil, "memory: choosing none is remembered too")
        // 「加水印导出…」的预选
        WatermarkMemory.remember(nil, key: WatermarkMemory.exportKey)
        T.check(WatermarkMemory.preselectForMenu() == id.id, "menu preselect: with none remembered, the first choice is 证件用途")
        WatermarkMemory.defaults.removeObject(forKey: WatermarkMemory.exportKey)
        T.check(accessory(preselect: true).options.options.watermark?.style.id == id.id, "menu preselect: never used → 证件用途 is pre-selected in the ⌘S panel")
        WatermarkMemory.remember(proof.id, key: WatermarkMemory.exportKey)
        T.check(accessory(preselect: true).options.options.watermark?.style.id == proof.id && accessory().options.options.watermark?.style.id == proof.id, "menu preselect: last used style is pre-selected")
        WatermarkMemory.remember(UUID(), key: WatermarkMemory.exportKey)
        T.check(accessory(preselect: true).options.options.watermark?.style.id == id.id, "menu preselect: a remembered style that no longer exists falls back to 证件用途")
        WatermarkMemory.defaults.removeObject(forKey: WatermarkMemory.exportKey)
        // 菜单和快捷键
        let fileMenu = NSApp.mainMenu?.items.compactMap { $0.submenu }.first { $0.items.contains { $0.action == #selector(ViewerViewController.exportAs(_:)) } }
        let mi = fileMenu?.items.first { $0.action == #selector(ViewerViewController.exportWithWatermark(_:)) }
        let miIndex = fileMenu?.items.firstIndex { $0 === mi }, asIndex = fileMenu?.items.firstIndex { $0.action == #selector(ViewerViewController.exportAs(_:)) }
        T.check(mi != nil && miIndex == (asIndex ?? -5) + 1 && mi!.title == L10n.t("menu.exportWatermarked", "加水印导出…"), "menu: File › 「\(mi?.title ?? "-")」 sits right under Export As")
        T.check(ShortcutAction.exportWatermarked.group == .file && ShortcutAction.exportWatermarked.isAvailable && Shortcuts.owner(of: ShortcutAction.exportWatermarked.defaultCombo!, excluding: .exportWatermarked) == nil
                && ShortcutAction.allCases.filter { a in a != .exportWatermarked && a.defaultCombo.map { $0.keyCode == ShortcutAction.exportWatermarked.defaultCombo!.keyCode && $0.mods == ShortcutAction.exportWatermarked.defaultCombo!.mods } == true }.isEmpty,
                "shortcut: registered as a rebindable File action, default ⇧⌘S is unused by any other action")
        T.check(mi?.keyEquivalent == "s" && mi?.keyEquivalentModifierMask == [.command, .shift], "menu: key equivalent shows ⇧⌘S")

        if uiOnly {
            // 只看界面：不走 ⌘S 面板，但批量对话框要有照片
            open(url: src)
            T.spin(2) { self.folder.count > 0 }
        } else {
            // ===== 7. 真的走一遍 ⌘S 面板 =====
            runWatermarkPanelFlow(work: run, outs: outs, src: src, idcard: idcard)
        }
        // 原文件不变
        T.check(originals.map { T.sha($0) } == shaBefore, "originals: all four source photos are byte-identical after every export in this run")
        T.check(sumW.outputs.allSatisfy { $0.deletingLastPathComponent().path == batchOut.path }, "originals: batch wrote only into its output folder")
        wmFinishStage1(work: run, outs: outs, shots: shots, idcard: idcard, portrait: portrait, landscape: landscape, store: store, uiOnly: uiOnly)
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 裁剪与拉直的自测。
/// --cropgeomtest：只算几何（CropGeometry），不开窗口；
/// --croptest <输出文件夹> <照片文件夹>：从界面到存盘走一遍，见 ViewerViewController.runCropTest
enum CropSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok {
            failures += 1
            NSLog("CROPGEOM FAIL %@", what())
        }
    }

    /// 不靠 CropGeometry.contains：四个角各自转回照片坐标，看在不在 W×H 里
    static func cornersInside(_ c: CropGeometry.Crop, image: CGSize, degrees: Double, tolerance: CGFloat = 1e-3) -> Bool {
        let t = degrees * .pi / 180
        let r = c.rect
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            // 照片顺时针转了 t，转回去就是逆时针 t（y 朝下的坐标）
            let x = p.x * CGFloat(cos(t)) + p.y * CGFloat(sin(t)), y = -p.x * CGFloat(sin(t)) + p.y * CGFloat(cos(t))
            if abs(x) > image.width / 2 + tolerance || abs(y) > image.height / 2 + tolerance { return false }
        }
        return true
    }

    static func runGeometry() {
        failures = 0
        var checks = 0
        let sources: [(String, CGSize)] = [("landscape", CGSize(width: 6000, height: 4000)), ("portrait", CGSize(width: 4000, height: 6000)),
                                           ("square", CGSize(width: 4000, height: 4000))]
        let angles: [Double] = [0, 0.1, -0.1, 5, -5, 20, -20, 45, -45]
        var seed: UInt64 = 20261114
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1_000_000) / 1_000_000
        }
        for (name, img) in sources {
            for deg in angles {
                let tag = "\(name) \(deg)°"
                // 1. 默认框 = 现在的拉直（同比例、居中、最大）
                let auto = CropGeometry.automatic(image: img, degrees: deg)
                let k = Straighten.cropScale(width: img.width, height: img.height, degrees: deg)
                checks += 3
                check(abs(auto.size.width - img.width * k) < 1e-6 && abs(auto.size.height - img.height * k) < 1e-6, "\(tag) automatic != cropScale")
                check(cornersInside(auto, image: img, degrees: deg), "\(tag) automatic outside")
                check(auto.center == .zero, "\(tag) automatic off-centre")

                // 2. 各个比例、居中和偏心：在照片里、比例对、再大一点就出去
                for aspect in CropGeometry.Aspect.allCases where aspect != .free {
                    for swapped in [false, true] where !swapped || aspect.swappable {
                        let r = aspect.ratio(image: img, swapped: swapped)!
                        for center in [CGPoint.zero, CGPoint(x: img.width * 0.2, y: -img.height * 0.15)] {
                            let f = CropGeometry.fitted(CropGeometry.Crop(center: center, size: CGSize(width: r, height: 1)), image: img, degrees: deg, grow: true)
                            checks += 3
                            check(cornersInside(f, image: img, degrees: deg), "\(tag) \(aspect) swapped=\(swapped) center=\(center) outside \(f)")
                            check(abs(f.aspect - r) < 1e-9, "\(tag) \(aspect) ratio \(f.aspect) != \(r)")
                            let bigger = CropGeometry.Crop(center: f.center, size: CGSize(width: f.size.width * 1.002, height: f.size.height * 1.002))
                            check(!cornersInside(bigger, image: img, degrees: deg, tolerance: 0), "\(tag) \(aspect) not maximal")
                        }
                    }
                }

                // 3. 手动框（0° 时合法）在这个角度下重新放进去：在照片里、比例不变、不变大；放得下就原样
                let manual = CropGeometry.Crop(center: CGPoint(x: img.width * 0.2, y: img.height * 0.1), size: CGSize(width: img.width * 0.5, height: img.height * 0.4))
                let refit = CropGeometry.fitted(manual, image: img, degrees: deg, grow: false)
                checks += 4
                check(cornersInside(refit, image: img, degrees: deg), "\(tag) refit outside")
                check(abs(refit.aspect - manual.aspect) < 1e-9, "\(tag) refit ratio changed")
                check(refit.size.width <= manual.size.width + 1e-9, "\(tag) refit grew")
                if cornersInside(manual, image: img, degrees: deg, tolerance: 0) { check(refit == manual, "\(tag) refit changed a valid rect") }
                // 中心还在照片里够靠里的时候不该动
                let small = CropGeometry.Crop(center: CGPoint(x: img.width * 0.1, y: img.height * 0.1), size: CGSize(width: img.width * 0.5, height: img.height * 0.5))
                let smallFit = CropGeometry.fitted(small, image: img, degrees: deg, grow: false)
                checks += 1
                check(hypot(smallFit.center.x - small.center.x, smallFit.center.y - small.center.y) < 1e-6, "\(tag) refit moved the centre")
                // 角落里的框：角度大了中心会被挤出去，这时要挪进来，仍然在照片里
                let corner = CropGeometry.Crop(center: CGPoint(x: img.width * 0.42, y: -img.height * 0.42), size: CGSize(width: img.width * 0.15, height: img.height * 0.15))
                let cornerFit = CropGeometry.fitted(corner, image: img, degrees: deg, grow: false)
                checks += 2
                check(cornersInside(cornerFit, image: img, degrees: deg), "\(tag) corner refit outside")
                check(cornerFit.size.width >= 15.9, "\(tag) corner refit collapsed \(cornerFit.size)")

                // 4. 随机拖 300 次（八个手柄 + 移动，自由 / 固定比例）：每一步都在照片里
                var cur = auto
                for i in 0..<300 {
                    let p = CGPoint(x: (rnd() - 0.5) * img.width * 1.6, y: (rnd() - 0.5) * img.height * 1.6)
                    let lock: CGFloat? = i % 3 == 0 ? nil : (i % 3 == 1 ? cur.aspect : [1, 0.8, 1.5, 16.0 / 9.0][i % 4])
                    let next: CropGeometry.Crop
                    if i % 9 == 8 {
                        next = CropGeometry.moved(cur, to: p, image: img, degrees: deg)
                        checks += 1
                        check(abs(next.size.width - cur.size.width) < 1e-9 && abs(next.size.height - cur.size.height) < 1e-9, "\(tag) move changed size")
                    } else {
                        let h = CropGeometry.Handle.allCases[i % 8]
                        // 换比例时先像界面上那样重新放一次，再拖
                        let start = lock.map { CropGeometry.fitted(CropGeometry.Crop(center: cur.center, size: CGSize(width: $0, height: 1)), image: img, degrees: deg, grow: true) } ?? cur
                        next = CropGeometry.resized(start, handle: h, to: p, aspect: lock, image: img, degrees: deg, minSide: 40)
                        if let lock {
                            checks += 1
                            check(abs(next.aspect - lock) < 1e-6, "\(tag) drag \(h) ratio \(next.aspect) != \(lock)")
                        }
                    }
                    checks += 2
                    check(cornersInside(next, image: img, degrees: deg), "\(tag) drag step \(i) outside \(next)")
                    check(next.size.width > 0 && next.size.height > 0, "\(tag) drag step \(i) empty")
                    // 落到整像素以后也不出去
                    let px = CropGeometry.pixelRect(next, image: img, degrees: deg)
                    let back = CropGeometry.Crop(rect: px.offsetBy(dx: -img.width / 2, dy: -img.height / 2))
                    if next.size.width > 4, next.size.height > 4 {
                        checks += 1
                        check(cornersInside(back, image: img, degrees: deg, tolerance: 2e-3), "\(tag) pixel rect outside \(px)")
                    }
                    cur = next
                }
            }

            // 5. 没拉直时拖到照片外面：正好贴到照片边
            let half = CropGeometry.Crop(center: .zero, size: CGSize(width: img.width / 2, height: img.height / 2))
            let out = CropGeometry.resized(half, handle: .bottomRight, to: CGPoint(x: img.width * 3, y: img.height * 0.3), aspect: nil, image: img, degrees: 0, minSide: 40)
            checks += 2
            check(abs(out.rect.maxX - img.width / 2) < 1e-3, "\(name) clamp x \(out.rect.maxX)")
            check(abs(out.rect.maxY - img.height * 0.3) < 1e-3, "\(name) clamp keeps y \(out.rect.maxY)")

            // 6. R / L：转四次回到原样；转一次框住的还是同一块（框的角转回去是原来的角），仍在转过的照片里
            let c0 = CropGeometry.fitted(CropGeometry.Crop(center: CGPoint(x: img.width * 0.13, y: -img.height * 0.07), size: CGSize(width: img.width * 0.4, height: img.height * 0.3)),
                                         image: img, degrees: 7.3, grow: false)
            var c = c0
            var size = img
            for turn in 1...4 {
                c = CropGeometry.turned(c, clockwise: 1)
                size = CGSize(width: size.height, height: size.width)
                checks += 1
                check(cornersInside(c, image: size, degrees: 7.3), "\(name) turned \(turn) outside")
            }
            checks += 4
            check(c == c0, "\(name) four right turns \(c) != \(c0)")
            check(CropGeometry.turned(c0, clockwise: -4) == c0, "\(name) four left turns")
            check(CropGeometry.turned(CropGeometry.turned(c0, clockwise: 1), clockwise: -1) == c0, "\(name) R then L")
            let once = CropGeometry.turned(c0, clockwise: 1)
            check(once.center == CGPoint(x: -c0.center.y, y: c0.center.x) && once.size == CGSize(width: c0.size.height, height: c0.size.width), "\(name) one turn mapping")
        }

        // 7. 比例放进 6000×4000：输出像素
        let img = CGSize(width: 6000, height: 4000)
        let expect: [(CropGeometry.Aspect, Bool, CGSize)] = [
            (.original, false, CGSize(width: 6000, height: 4000)), (.original, true, CGSize(width: 2666, height: 4000)),
            (.square, false, CGSize(width: 4000, height: 4000)), (.r4x5, false, CGSize(width: 3200, height: 4000)),
            (.r4x5, true, CGSize(width: 5000, height: 4000)), (.r3x2, false, CGSize(width: 6000, height: 4000)),
            (.r3x2, true, CGSize(width: 2666, height: 4000)), (.r16x9, false, CGSize(width: 6000, height: 3375)),
            (.r16x9, true, CGSize(width: 2250, height: 4000)),
        ]
        for (a, sw, want) in expect {
            let f = CropGeometry.fitted(CropGeometry.Crop(center: .zero, size: CGSize(width: a.ratio(image: img, swapped: sw)!, height: 1)), image: img, degrees: 0, grow: true)
            let px = CropGeometry.pixelRect(f, image: img, degrees: 0).size
            checks += 1
            check(px == want, "ratio \(a) swapped=\(sw): \(px) != \(want)")
        }
        NSLog("CROPGEOM done checks=%d failures=%d", checks, failures)
    }

    // MARK: - 测试图

    static let cell = 100, cols = 30, rows = 20

    /// 格子的颜色：列、行各按 6 进制拆开，R、G 放低位（一级 40），B 放两个高位（一级 10）。
    /// 压两遍 JPEG 颜色会差三四级，这样还认得出是哪一格；三个通道都不低于 40，没有黑色
    static func cellColor(_ c: Int, _ r: Int) -> (r: Int, g: Int, b: Int) {
        (40 + 40 * (c % 6), 40 + 40 * (r % 6), 40 + 10 * ((c / 6) * 4 + r / 6))
    }

    static func cell(of p: (r: Int, g: Int, b: Int, a: Int)) -> (c: Int, r: Int) {
        let lowC = Int((Double(p.r - 40) / 40).rounded()), lowR = Int((Double(p.g - 40) / 40).rounded())
        let high = Int((Double(p.b - 40) / 10).rounded())
        return ((high / 4) * 6 + lowC, (high % 4) * 6 + lowR)
    }

    /// 3000×2000 的色块图，每格 100 像素，格子左上角写着「列,行」
    static func makeGrid() -> CGImage? {
        let w = cols * cell, h = rows * cell
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        for r in 0..<rows {
            for c in 0..<cols {
                // 位图左下原点：第 r 行（从上往下数）画在 y = h - (r + 1) * cell
                let rect = CGRect(x: c * cell, y: h - (r + 1) * cell, width: cell, height: cell)
                let k = cellColor(c, r)
                ctx.setFillColor(CGColor(srgbRed: CGFloat(k.r) / 255, green: CGFloat(k.g) / 255, blue: CGFloat(k.b) / 255, alpha: 1))
                ctx.fill(rect)
                ("\(c),\(r)" as NSString).draw(at: CGPoint(x: rect.minX + 4, y: rect.maxY - 20),
                                                 withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: orientation] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]
        /// 左上原点
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
    }

    /// 文件里存的像素（不按方向标记转），画进 sRGB 位图；透明的地方 alpha 留着
    static func pixels(of url: URL) -> Pixels? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return true
        }
        return ok ? Pixels(width: img.width, height: img.height, data: data) : nil
    }

    /// 存出来的色块图对不对：四个角不黑不透明；画面上 8×8 个点各自落在该落的格子里。
    /// turns：显示时比文件里存的多转了几个 90°（方向标记 6 算 1，再按一次 R 又加 1）；crop = nil 表示没裁（整张）
    static func checkGrid(_ url: URL, turns: Int, degrees: Double, crop: CropGeometry.Crop?) -> String {
        guard let px = pixels(of: url) else { return "unreadable" }
        let k = ((turns % 4) + 4) % 4
        let sw = CGFloat(cols * cell), sh = CGFloat(rows * cell)
        let turned = k % 2 == 0 ? CGSize(width: sw, height: sh) : CGSize(width: sh, height: sw)
        let rect = crop.map { CropGeometry.pixelRect($0, image: turned, degrees: degrees) } ?? CGRect(origin: .zero, size: turned)
        var corners = true
        var cornerText: [String] = []
        for (x, y) in [(0, 0), (px.width - 1, 0), (0, px.height - 1), (px.width - 1, px.height - 1)] {
            let p = px.at(x, y)
            // 往里 4 个像素的那个点一般在同一格里：角上混进了黑或透明的话，三个通道都会比它暗一截
            let q = px.at(x == 0 ? 4 : x - 4, y == 0 ? 4 : y - 4)
            let darker = Double(p.r) < Double(q.r) * 0.85 && Double(p.g) < Double(q.g) * 0.85 && Double(p.b) < Double(q.b) * 0.85
            if p.a != 255 || darker || min(p.r, p.g, p.b) < 30 { corners = false }
            cornerText.append("\(p.r),\(p.g),\(p.b),\(p.a)")
        }
        var hit = 0, total = 0
        var firstMiss = ""
        for j in 0..<8 {
            for i in 0..<8 {
                let u = (CGFloat(i) + 0.5) / 8 * CGFloat(px.width), v = (CGFloat(j) + 0.5) / 8 * CGFloat(px.height)
                // 输出像素 → 转好 90° 的照片（相对中心）→ 转回拉直前 → 文件里存的像素
                let f = CGPoint(x: rect.minX + u - turned.width / 2, y: rect.minY + v - turned.height / 2)
                let ti = CropGeometry.toImage(f, degrees: degrees)
                var p = CGPoint(x: ti.x + turned.width / 2, y: ti.y + turned.height / 2)
                var size = turned
                for _ in 0..<k {
                    // 顺时针转过一次的照片上的 (x, y)，转之前在 (y, 高 - x)
                    p = CGPoint(x: p.y, y: size.width - p.x)
                    size = CGSize(width: size.height, height: size.width)
                }
                let fx = p.x.truncatingRemainder(dividingBy: CGFloat(cell)), fy = p.y.truncatingRemainder(dividingBy: CGFloat(cell))
                // 离格子边太近的、压在左上角数字上的不比
                guard p.x > 0, p.y > 0, p.x < sw, p.y < sh, fx > 14, fx < 86, fy > 30, fy < 86 else { continue }
                total += 1
                let got = px.at(Int(u), Int(v))
                let (c, r) = Self.cell(of: got)
                if c == Int(p.x) / cell, r == Int(p.y) / cell {
                    hit += 1
                } else if firstMiss.isEmpty {
                    firstMiss = " miss@(\(Int(u)),\(Int(v))) got=\(c),\(r) want=\(Int(p.x) / cell),\(Int(p.y) / cell)"
                }
            }
        }
        return "corners=\(corners ? "ok" : "BAD")[\(cornerText.joined(separator: " "))] cells=\(hit)/\(total)\(firstMiss)"
    }

    /// 系统读出来的老式 IPTC 创建日期和 XMP 里的写法
    static func iptcDates(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return "missing" }
        let iptc = p[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "photoshop:DateCreated" as CFString) as String? }
        return "DateCreated=\(iptc?["DateCreated"] ?? "nil") TimeCreated=\(iptc?["TimeCreated"] ?? "nil") xmp=\(xmp ?? "nil")"
    }

    static func meta(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return "\(url.lastPathComponent)=missing" }
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return String(format: "%@=%dx%d orient=%d exifDim=%@x%@ profile=%@ type=%@", url.lastPathComponent, p["PixelWidth"] as? Int ?? 0, p["PixelHeight"] as? Int ?? 0,
                      p[kCGImagePropertyOrientation as String] as? Int ?? 1,
                      "\(exif?[kCGImagePropertyExifPixelXDimension as String] ?? "-")", "\(exif?[kCGImagePropertyExifPixelYDimension as String] ?? "-")",
                      p[kCGImagePropertyProfileName as String] as? String ?? "-", (CGImageSourceGetType(src) as String?) ?? "-")
    }
}

extension ViewerViewController {
    /// --croptest <输出文件夹> <照片文件夹>：照片文件夹里放 img208.jpg、exif.jpg、sony.heic、cam.ARW（有哪个测哪个，会被改动），
    /// 色块测试图（grid.jpg、over.jpg、orient6.jpg、grid.heic）测试自己生成。
    /// 鼠标用合成的事件直接交给裁剪框，按键交给看图视图，保存走底部那条和询问对话框。
    /// 截图和日志带界面语言，换语言用 -AppleLanguages 启动。测完恢复原来的设置
    func runCropTest(outDir: String, folder path: String) {
        let savedTarget = Straighten.saveTarget, savedRemind = Straighten.remindUnsaved
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path)
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        guard let grid = CropSelfTest.makeGrid() else { NSLog("CROP FAIL no grid"); NSApp.terminate(nil); return }
        CropSelfTest.write(grid, to: dir.appendingPathComponent("grid.jpg"), type: .jpeg)
        CropSelfTest.write(grid, to: dir.appendingPathComponent("over.jpg"), type: .jpeg)
        CropSelfTest.write(grid, to: dir.appendingPathComponent("orient6.jpg"), type: .jpeg, orientation: 6)
        CropSelfTest.write(grid, to: dir.appendingPathComponent("grid.heic"), type: .heic)
        // 评分和标记：覆盖保存以后还在不在
        Rating.write(4, to: dir.appendingPathComponent("over.jpg"))
        Marks.set(true, for: dir.appendingPathComponent("over.jpg"))

        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            NSLog("CROP %@ [%@] %@", ok ? "ok" : "FAIL", lang, what)
        }
        func log(_ s: String) { NSLog("CROP    [%@] %@", lang, s) }
        func shot(_ name: String) { captureWindow(to: "\(outDir)/\(lang)-\(name).png", raw: true) }

        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        /// 等保存完（最多 60 秒）再接着走
        func idle(_ f: @escaping () -> Void) { steps.append((-1, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            if dt >= 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }
                return
            }
            var waited = 0.0
            func poll() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    waited += 0.25
                    if (self.isProcessing || waited < 0.5), waited < 60 { poll(); return }
                    // 存完以后界面还要重新载入 / 列目录
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { f(); runNext() }
                }
            }
            poll()
        }

        func go(_ name: String) {
            if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == name }) { goTo(i) } else { expect(false, "no \(name) in folder") }
        }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        var overlay: CropOverlayView? { imageView.debugCropOverlay }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) {
            guard let o = overlay, let w = view.window,
                  let e = NSEvent.mouseEvent(with: type, location: o.convert(p, to: nil), modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: o.mouseDown(with: e)
            case .leftMouseDragged: o.mouseDragged(with: e)
            default: o.mouseUp(with: e)
            }
        }
        /// 按住某个手柄拖 (dx, dy) 点；release = false 时停在半路不松手
        func drag(_ h: CropGeometry.Handle?, dx: CGFloat, dy: CGFloat, mods: NSEvent.ModifierFlags = [], release: Bool = true) {
            guard let o = overlay else { expect(false, "drag without overlay"); return }
            let f = o.cropFrame
            let p = h.map { o.debugHandlePoint($0) } ?? CGPoint(x: f.midX, y: f.midY)
            mouse(.leftMouseDown, p)
            for i in 1...6 { mouse(.leftMouseDragged, CGPoint(x: p.x + dx * CGFloat(i) / 6, y: p.y + dy * CGFloat(i) / 6), mods: mods) }
            if release { mouse(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y + dy)) }
        }
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            imageView.keyDown(with: e)
        }
        func px() -> CGSize { imageView.pixelSize }
        func sizeText(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }
        func fileSize(_ name: String) -> CGSize {
            guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return .zero }
            return CGSize(width: p["PixelWidth"] as? Int ?? 0, height: p["PixelHeight"] as? Int ?? 0)
        }
        func listing() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") } }
        /// 点底部的「保存…」；弹出询问对话框就按 overwrite 选第一个或第二个按钮
        func save(overwrite: Bool) {
            Straighten.saveTarget = .ask
            rotationBar.onSave?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let sheet = self.view.window?.attachedSheet {
                    self.view.window?.endSheet(sheet, returnCode: overwrite ? .alertFirstButtonReturn : .alertSecondButtonReturn)
                }
            }
        }
        let cropSuffix = L10n.t("rot.cropSuffix", "-裁剪")
        let inside = { CropSelfTest.cornersInside(self.imageView.debugCropNow, image: self.imageView.debugTurnedSize, degrees: self.imageView.fineDegrees) }

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 820, width: 1180, height: 800), display: true)
        }
        Straighten.saveTarget = .ask
        Straighten.remindUnsaved = true
        open(url: dir)

        // ---- 1. 各个比例：选比例 → 拖手柄 → 回车 → 另存一份，查文件的像素尺寸和比例
        struct RatioCase { let aspect: CropGeometry.Aspect; let name: String; let ratio: CGFloat?; let before: CGSize? }
        let cases = [
            RatioCase(aspect: .original, name: "original", ratio: 1.5, before: CGSize(width: 3000, height: 2000)),
            RatioCase(aspect: .free, name: "free", ratio: nil, before: CGSize(width: 3000, height: 2000)),
            RatioCase(aspect: .square, name: "1x1", ratio: 1, before: CGSize(width: 2000, height: 2000)),
            RatioCase(aspect: .r4x5, name: "4x5", ratio: 0.8, before: CGSize(width: 1600, height: 2000)),
            RatioCase(aspect: .r3x2, name: "3x2", ratio: 1.5, before: CGSize(width: 3000, height: 2000)),
            RatioCase(aspect: .r16x9, name: "16x9", ratio: 16.0 / 9.0, before: CGSize(width: 3000, height: 1687)),
        ]
        at(1.5) {
            log("files=\(self.folder.count) window=\(NSStringFromSize(self.view.window?.frame.size ?? .zero)) scale=\(self.view.window?.backingScaleFactor ?? 0)")
            go("grid.jpg")
        }
        var before = Set<String>()
        var want = CGSize.zero
        var wantCrop: CropGeometry.Crop?
        for c in cases {
            at(1.0) {
                self.straighten(nil)
                expect(self.isStraightening && self.rotationBar.debugRow == "straighten", "\(c.name): mode entered, bar=\(self.rotationBar.debugRow) \(overlay?.debugLayers ?? "-") barWidth=\(Int(self.rotationBar.fittingSize.width)) viewWidth=\(Int(self.view.bounds.width))")
                self.rotationBar.debugSelectAspect(c.aspect)
            }
            at(0.4) {
                if let b = c.before { expect(px() == b, "\(c.name): fitted size \(sizeText(px())) want \(sizeText(b)) | \(self.rotationBar.debugCrop)") }
                shot("ratio-\(c.name)")
                // 自由：右边往里 150 点、下边往上 60 点；其余：左上角往里拖，比例保持
                if c.aspect == .free {
                    drag(.right, dx: -150, dy: 0)
                    drag(.bottom, dx: 0, dy: -60)
                } else {
                    drag(.topLeft, dx: 70, dy: 55)
                }
                expect(inside(), "\(c.name): rect inside image after drag")
                want = px()
                key(36, "\r")
            }
            at(0.6) {
                wantCrop = self.imageView.crop
                expect(!self.isStraightening && self.imageView.hasPendingRotation && self.rotationBar.debugRow == "pending",
                       "\(c.name): applied, pending bar=\(self.rotationBar.debugRow) shown=\(sizeText(px())) readout=\(sizeText(want))")
                if c.aspect == .original { shot("pending-bar") }
                before = listing()
                save(overwrite: false)
            }
            idle {
                let new = listing().subtracting(before)
                let name = new.first ?? "-"
                let s = fileSize(name)
                var ok = new.count == 1 && name.hasPrefix("grid\(cropSuffix)") && s == want
                if let r = c.ratio { ok = ok && (abs(s.width - s.height * r) <= 1 || abs(s.width / r - s.height) <= 1) }
                if c.aspect == .free { ok = ok && abs(s.width / s.height - 1.5) > 0.05 }
                expect(ok, "\(c.name): saved \(name) \(sizeText(s)) ratio=\(String(format: "%.4f", s.width / max(s.height, 1))) want \(sizeText(want))")
                let g = CropSelfTest.checkGrid(dir.appendingPathComponent(name), turns: 0, degrees: 0, crop: wantCrop)
                expect(g.contains("corners=ok") && !g.contains("miss"), "\(c.name): content \(g)")
                expect(!self.imageView.hasPendingRotation && fileSize("grid.jpg") == CGSize(width: 3000, height: 2000), "\(c.name): original untouched, nothing pending")
                go("grid.jpg")
            }
        }

        // ---- 2. 横竖互换、⇧ 保持比例、Esc 取消、还原
        at(1.0) {
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r4x5)
            self.rotationBar.onSwap?()
            expect(px() == CGSize(width: 2500, height: 2000), "swap 4:5 → 5:4: \(sizeText(px())) | \(self.rotationBar.debugCrop)")
            self.rotationBar.debugSelectAspect(.original)
            self.rotationBar.onSwap?()
            expect(px() == CGSize(width: 1333, height: 2000), "swap original → rotated original ratio: \(sizeText(px())) | \(self.rotationBar.debugCrop)")
            shot("swap-original")
            self.rotationBar.debugSelectAspect(.square)
            expect(self.rotationBar.debugCrop.contains("swap=0"), "swap disabled for 1:1 | \(self.rotationBar.debugCrop)")
            self.rotationBar.debugSelectAspect(.free)
            expect(self.rotationBar.debugCrop.contains("swap=0") && px() == CGSize(width: 2000, height: 2000), "free keeps the rect, swap disabled | \(self.rotationBar.debugCrop)")
            drag(.bottomRight, dx: -120, dy: -30, mods: .shift)
            expect(abs(px().width - px().height) <= 1, "free + shift keeps the ratio: \(sizeText(px()))")
            drag(.bottomRight, dx: -80, dy: 0)
            expect(px().width < px().height - 20, "free without shift changes it: \(sizeText(px()))")
            key(53, "\u{1B}")
        }
        at(0.5) {
            expect(!self.isStraightening && !self.imageView.hasPendingRotation && px() == CGSize(width: 3000, height: 2000) && self.rotationBar.debugRow == "hidden",
                   "Esc: back to entry state \(sizeText(px())) bar=\(self.rotationBar.debugRow)")
            // 拖到照片外面很远：框贴边停住
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.free)
            drag(.topLeft, dx: 200, dy: 150)
            drag(.topLeft, dx: -900, dy: -900)
            expect(px() == CGSize(width: 3000, height: 2000) && inside(), "drag far outside clamps to the photo: \(sizeText(px()))")
            drag(.left, dx: 300, dy: 0)
            drag(nil, dx: -2000, dy: 500)
            expect(inside() && abs(self.imageView.debugCropNow.rect.minX + 1500) < 0.01, "move clamps at the left edge: \(self.imageView.debugCropNow.rect)")
            key(53, "\u{1B}")
        }

        // ---- 3. 裁剪 + 拉直 7.3° + 4:5，双击完成，再按 R；再进去接着调；另存一份
        var comboCrop: CropGeometry.Crop?
        at(0.6) {
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r4x5)
            self.rotationBar.onDegrees?(7.3)
            expect(abs(self.imageView.fineDegrees - 7.3) < 1e-9 && inside(), "angle 7.3 with 4:5: rect inside, size \(sizeText(px()))")
            let grown = px()
            self.rotationBar.onDegrees?(20)
            let at20 = px()
            self.rotationBar.onDegrees?(7.3)
            expect(at20.width < grown.width && px() == grown, "angle 20 shrinks (\(sizeText(at20))), back to 7.3 restores (\(sizeText(px())))")
            drag(.bottomRight, dx: -60, dy: -75)
            drag(nil, dx: 45, dy: -30)
            expect(inside() && abs(px().width - px().height * 0.8) <= 2, "angle + crop: inside, ratio kept \(sizeText(px()))")
        }
        at(0.3) {
            // ← → 微调：先多转 1°（⇧→），再转回来
            key(124, "", .shift)
            let a = self.imageView.fineDegrees
            key(123, "", .shift)
            key(124, "")
            key(123, "")
            expect(abs(a - 8.3) < 1e-9 && abs(self.imageView.fineDegrees - 7.3) < 1e-9 && inside(), "arrow keys nudge: \(a) → \(self.imageView.fineDegrees)")
            // 手动拖过的框：角度拧大会缩，拧回来回到原来的大小
            let mine = self.imageView.debugCropNow
            self.rotationBar.onDegrees?(35)
            let small = self.imageView.debugCropNow
            expect(inside() && small.size.width < mine.size.width, "manual rect shrinks at 35°: \(small.size)")
            self.rotationBar.onDegrees?(7.3)
            expect(self.imageView.debugCropNow == mine, "manual rect restored at 7.3°")
        }
        at(1.5) { shot("angle-crop") }
        at(0.2) {
            drag(.top, dx: 0, dy: 40, release: false)
            shot("mid-drag")
            mouse(.leftMouseUp, .zero)
            want = px()
            comboCrop = self.imageView.debugCropNow
            // 在框里双击 = 完成
            let f = overlay?.cropFrame ?? .zero
            mouse(.leftMouseDown, CGPoint(x: f.midX, y: f.midY), clicks: 2)
        }
        at(0.6) {
            expect(!self.isStraightening && self.imageView.crop == comboCrop && px() == want && self.rotationBar.debugRow == "pending",
                   "double-click applies: \(sizeText(px())) bar=\(self.rotationBar.debugRow)")
            shot("pending-angle-crop")
            self.rotateCW(nil)
        }
        at(0.6) {
            let turned = comboCrop.map { CropGeometry.turned($0, clockwise: 1) }
            expect(self.imageView.crop == turned && px() == CGSize(width: want.height, height: want.width), "R keeps the crop on the same content: \(sizeText(px()))")
            shot("pending-after-R")
            // 再进去：框、角度、比例都还在
            self.straighten(nil)
            expect(self.imageView.debugCropNow == turned && abs(self.imageView.fineDegrees - 7.3) < 1e-9 && self.rotationBar.debugCrop.contains("aspect=5:4"),
                   "re-enter restores rect, angle and ratio | \(self.rotationBar.debugCrop)")
            shot("reenter")
            // 模式里转 90°（工具条按钮）：框跟着转，转回来还是它
            self.rotateCW(nil)
            let inMode = self.imageView.debugCropNow
            self.rotateCCW(nil)
            expect(inMode == turned.map { CropGeometry.turned($0, clockwise: 1) } && self.imageView.debugCropNow == turned && inside(), "R / L inside the mode turns the rect with the photo")
            key(53, "\u{1B}")
            expect(self.imageView.crop == turned && self.imageView.rotationTurns == 1, "Esc after re-enter keeps the pending edit")
            wantCrop = self.imageView.crop
            want = px()
            before = listing()
            save(overwrite: false)
        }
        idle {
            let name = listing().subtracting(before).first ?? "-"
            let s = fileSize(name)
            expect(s == want, "combo saved \(name) \(sizeText(s)) want \(sizeText(want)) | \(CropSelfTest.meta(dir.appendingPathComponent(name)))")
            let g = CropSelfTest.checkGrid(dir.appendingPathComponent(name), turns: 1, degrees: 7.3, crop: wantCrop)
            expect(g.contains("corners=ok") && !g.contains("miss") && !g.contains("cells=0/"), "combo content \(g)")
            try? fm.copyItem(at: dir.appendingPathComponent(name), to: URL(fileURLWithPath: "\(outDir)/\(lang)-combo-7.3deg-R.jpg"))
        }

        // ---- 4. 还原：裁剪 + 角度 + 90° 一起清掉
        at(0.6) {
            go("grid.jpg")
        }
        at(1.0) {
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.square)
            self.rotationBar.onDegrees?(-4)
            key(36, "\r")
            self.rotateCCW(nil)
            expect(self.imageView.hasPendingRotation && self.imageView.crop != nil, "pending crop + angle + L")
            self.rotationBar.onRevert?()
        }
        at(0.5) {
            expect(!self.imageView.hasPendingRotation && self.imageView.crop == nil && self.imageView.fineDegrees == 0 && self.imageView.rotationTurns == 0
                   && px() == CGSize(width: 3000, height: 2000) && self.rotationBar.debugRow == "hidden", "Revert clears crop, angle and quarter turns")
            // 只拉直、不动框：走原来的路径（没有手动裁剪框），和 1.0.30 一样
            self.straighten(nil)
            self.rotationBar.onDegrees?(5)
            let k = Straighten.cropScale(width: 3000, height: 2000, degrees: 5)
            let old = CGSize(width: (3000 * k).rounded(.down), height: (2000 * k).rounded(.down))
            expect(px() == old, "straighten only, live size \(sizeText(px())) equals the old formula \(sizeText(old))")
            key(36, "\r")
            expect(self.imageView.crop == nil && px() == old && self.imageView.hasPendingRotation, "straighten only: no manual crop stored")
            before = listing()
            want = old
            save(overwrite: false)
        }
        idle {
            let name = listing().subtracting(before).first ?? "-"
            expect(name.hasPrefix("grid\(L10n.t("rot.copySuffix", "-旋转"))") && fileSize(name) == want, "straighten-only copy keeps the rotate suffix: \(name) \(sizeText(fileSize(name)))")
            let px = CropSelfTest.pixels(of: dir.appendingPathComponent(name))
            let corners = [(0, 0), ((px?.width ?? 1) - 1, 0), (0, (px?.height ?? 1) - 1), ((px?.width ?? 1) - 1, (px?.height ?? 1) - 1)].map { px?.at($0.0, $0.1) }
            let g = CropSelfTest.checkGrid(dir.appendingPathComponent(name), turns: 0, degrees: 5, crop: CropGeometry.Crop(center: .zero, size: want))
            expect(corners.allSatisfy { ($0?.a ?? 0) == 255 } && g.contains("corners=ok") && !g.contains("miss"), "straighten-only content \(g)")
        }

        // ---- 5. 翻到别的照片时提醒；覆盖原图（评分、标记还在）
        at(0.6) { go("over.jpg") }
        at(1.0) {
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r16x9)
            drag(.bottomRight, dx: -90, dy: -90)
            key(36, "\r")
            want = px()
            wantCrop = self.imageView.crop
            self.navigate(1)
        }
        at(0.7) {
            let sheet = self.view.window?.attachedSheet
            expect(sheet != nil && self.folder.current?.url.lastPathComponent == "over.jpg", "leaving with a pending crop asks first")
            if let sheet {
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(lang)-unsaved-prompt.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                }
                self.view.window?.endSheet(sheet, returnCode: .alertThirdButtonReturn)
            }
        }
        at(0.5) {
            expect(self.imageView.crop == wantCrop && self.folder.current?.url.lastPathComponent == "over.jpg", "cancel keeps the photo and the crop")
            Straighten.saveTarget = .ask
            self.rotationBar.onSave?()
        }
        at(0.6) {
            let sheet = self.view.window?.attachedSheet
            expect(sheet != nil, "ask dialog shown")
            if let sheet {
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(lang)-ask-dialog.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                }
                before = listing()
                self.view.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            }
        }
        idle {
            let u = dir.appendingPathComponent("over.jpg")
            let s = fileSize("over.jpg")
            expect(s == want && abs(s.width - s.height * 16 / 9) <= 2.8 && listing() == before, "overwrite: over.jpg is now \(sizeText(s)), no extra file | \(CropSelfTest.meta(u))")
            let g = CropSelfTest.checkGrid(u, turns: 0, degrees: 0, crop: wantCrop)
            expect(g.contains("corners=ok") && !g.contains("miss"), "overwrite content \(g)")
            expect(!self.imageView.hasPendingRotation && px() == want && self.rotationBar.debugRow == "hidden", "overwrite: view reloaded \(sizeText(px())), nothing pending")
            log("after overwrite: rating=\(Rating.read(u)) (was 4) marked=\(Marks.isMarked(URL(fileURLWithPath: u.path)) ? 1 : 0) (was 1)")
            shot("after-overwrite")
        }

        // ---- 6. 方向标记 6 的 JPEG（显示出来是竖的 2000×3000）
        at(0.6) { go("orient6.jpg") }
        at(1.0) {
            expect(px() == CGSize(width: 2000, height: 3000), "orient6 shown as \(sizeText(px()))")
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.square)
            expect(px() == CGSize(width: 2000, height: 2000), "orient6 1:1 \(sizeText(px()))")
            drag(.topRight, dx: -50, dy: 50)
            drag(nil, dx: 0, dy: 120)
        }
        at(0.5) {
            shot("orient6-portrait")
            key(36, "\r")
            want = px()
            wantCrop = self.imageView.crop
            before = listing()
            save(overwrite: false)
        }
        idle {
            let name = listing().subtracting(before).first ?? "-"
            let m = CropSelfTest.meta(dir.appendingPathComponent(name))
            expect(fileSize(name) == want && abs(want.width - want.height) <= 1 && m.contains("orient=1"), "orient6 saved \(m)")
            let g = CropSelfTest.checkGrid(dir.appendingPathComponent(name), turns: 1, degrees: 0, crop: wantCrop)
            expect(g.contains("corners=ok") && !g.contains("miss") && !g.contains("cells=0/"), "orient6 content \(g)")
            expect(CropSelfTest.meta(dir.appendingPathComponent("orient6.jpg")).contains("3000x2000 orient=6"), "orient6 original untouched")
        }

        // ---- 7. HEIC
        at(0.6) { go("grid.heic") }
        at(1.5) {
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.r3x2)
            self.rotationBar.onDegrees?(-3.5)
            drag(.bottomLeft, dx: 80, dy: -40)
            key(36, "\r")
            want = px()
            wantCrop = self.imageView.crop
            before = listing()
            save(overwrite: false)
        }
        idle {
            let name = listing().subtracting(before).first ?? "-"
            let m = CropSelfTest.meta(dir.appendingPathComponent(name))
            expect(name.hasSuffix(".heic") && fileSize(name) == want && abs(want.width - want.height * 1.5) <= 2.5 && m.contains("public.heic"), "heic saved \(m)")
            let g = CropSelfTest.checkGrid(dir.appendingPathComponent(name), turns: 0, degrees: -3.5, crop: wantCrop)
            expect(g.contains("corners=ok") && !g.contains("miss") && !g.contains("cells=0/"), "heic content \(g)")
        }

        // ---- 8. 带拍摄信息的真实照片：裁一下另存，拍摄信息由外面的脚本比
        for name in ["img208.jpg", "exif.jpg", "sony.heic"] where has(name) {
            at(0.6) { go(name) }
            at(1.2) {
                self.straighten(nil)
                self.rotationBar.debugSelectAspect(.r4x5)
                drag(.top, dx: 0, dy: 30)
                key(36, "\r")
                want = px()
                before = listing()
                save(overwrite: false)
            }
            idle {
                let out = listing().subtracting(before).first ?? "-"
                expect(fileSize(out) == want && abs(want.width - want.height * 0.8) <= 1.8, "\(name) → \(CropSelfTest.meta(dir.appendingPathComponent(out)))")
                if name == "img208.jpg" {
                    // 老式 IPTC 的创建日期：重新编码以后还在（源文件 XMP 里写的是 28 Jan 2016，系统自己换算不了）
                    let d = CropSelfTest.iptcDates(dir.appendingPathComponent(out))
                    expect(d.contains("DateCreated=20160128"), "img208 crop keeps the IPTC creation date: \(d) | source as ImageIO reads it: \(CropSelfTest.iptcDates(dir.appendingPathComponent(name)))")
                }
            }
        }

        // ---- 9. RAW：原文件不动，另存成 JPEG（不弹询问）
        if has("cam.ARW") {
            var rawBefore: (size: Any?, date: Any?) = (nil, nil)
            at(0.6) { go("cam.ARW") }
            at(3.0) {
                let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent("cam.ARW").path)
                rawBefore = (a?[.size], a?[.modificationDate])
                self.straighten(nil)
                self.rotationBar.debugSelectAspect(.square)
                self.rotationBar.onDegrees?(2)
                key(36, "\r")
                want = px()
                before = listing()
                Straighten.saveTarget = .ask
                self.rotationBar.onSave?()
            }
            at(0.3) { expect(self.view.window?.attachedSheet == nil, "RAW: no overwrite question") }
            idle {
                let name = listing().subtracting(before).first ?? "-"
                let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent("cam.ARW").path)
                expect(name == "cam\(cropSuffix).jpg" && fileSize(name) == want && abs(want.width - want.height) <= 1,
                       "RAW saved as \(CropSelfTest.meta(dir.appendingPathComponent(name)))")
                expect("\(a?[.size] ?? 0)" == "\(rawBefore.size ?? 1)" && "\(a?[.modificationDate] ?? 0)" == "\(rawBefore.date ?? 1)", "RAW original untouched (size \(a?[.size] ?? 0))")
            }
        } else {
            at(0.1) { log("no cam.ARW in the folder: RAW case skipped") }
        }

        // ---- 11. 导出（⌘S 用的那条路）：导出的是看到的样子，拉直角度和裁剪框都算上
        let exportDir = URL(fileURLWithPath: outDir).appendingPathComponent("export-\(lang)")
        try? fm.removeItem(at: exportDir)
        try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        func sizeOf(_ u: URL) -> CGSize {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return .zero }
            return CGSize(width: p["PixelWidth"] as? Int ?? 0, height: p["PixelHeight"] as? Int ?? 0)
        }
        for (label, turns, degrees) in [("crop+angle", 0, 4.0), ("turn+crop+angle", 1, -2.5), ("angle-only", 0, 3.0)] {
            let dest = exportDir.appendingPathComponent("export-\(label).jpg")
            at(0.6) { Straighten.saveTarget = .ask; go("grid.jpg") }
            at(1.0) {
                self.imageView.resetRotation()
                if turns != 0 { self.imageView.rotate(clockwise: turns) }
                self.straighten(nil)
                if label != "angle-only" { self.rotationBar.debugSelectAspect(.r16x9) }
                self.rotationBar.onDegrees?(degrees)
                if label != "angle-only" { drag(.topLeft, dx: 60, dy: 40) }
                key(36, "\r")
                want = px()
                wantCrop = self.imageView.crop
                before = listing()
                self.runExport(sourceURL: dir.appendingPathComponent("grid.jpg"), turns: self.imageView.rotationTurns, degrees: self.imageView.fineDegrees,
                               crop: self.imageView.cropSpec, destURL: dest, uti: UTType.jpeg.identifier, quality: 0.92, currentBytes: 0) { _ in }
            }
            idle {
                let s = sizeOf(dest)
                let g = CropSelfTest.checkGrid(dest, turns: turns, degrees: degrees, crop: wantCrop ?? CropGeometry.Crop(center: .zero, size: want))
                expect(s == want && s != CGSize(width: 3000, height: 2000) && s != CGSize(width: 2000, height: 3000),
                       "export \(label): file is \(sizeText(s)), the view shows \(sizeText(want)) (turns \(turns), \(degrees)°, crop \(wantCrop == nil ? "none" : "yes"))")
                expect(g.contains("corners=ok") && !g.contains("miss") && !g.contains("cells=0/"), "export \(label) content \(g)")
                expect(listing() == before && CropSelfTest.meta(dir.appendingPathComponent("grid.jpg")).contains("3000x2000 orient=1"), "export \(label): source folder untouched")
                self.imageView.resetRotation()
            }
        }

        // ---- 12. 记住了「覆盖原图」：只转 90° 的照旧自动保存；裁剪过的不自动覆盖，点「保存…」时照样问
        var bytesBefore: Any?
        at(0.6) { go("grid.heic") }
        at(1.2) {
            Straighten.saveTarget = .overwrite
            bytesBefore = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("grid.heic").path))?[.modificationDate]
            self.straighten(nil)
            self.rotationBar.debugSelectAspect(.square)
            key(36, "\r")
            want = px()
            before = listing()
        }
        // 自动保存是转完 0.8 秒后做：等够 2.5 秒
        at(2.5) {
            let now = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent("grid.heic").path))?[.modificationDate]
            expect("\(now ?? 0)" == "\(bytesBefore ?? 1)" && fileSize("grid.heic") == CGSize(width: 3000, height: 2000) && listing() == before,
                   "overwrite remembered + crop: nothing written after 2.5 s (file still \(sizeText(fileSize("grid.heic"))))")
            expect(self.view.window?.attachedSheet == nil && self.imageView.hasPendingRotation && self.rotationBar.debugRow == "pending",
                   "overwrite remembered + crop: stays pending with the Save… bar (bar \(self.rotationBar.debugRow))")
            shot("crop-overwrite-pending")
            self.rotationBar.onSave?()
        }
        at(0.7) {
            let sheet = self.view.window?.attachedSheet
            expect(sheet != nil, "overwrite remembered + crop: Save… shows the dialog instead of overwriting")
            if let sheet {
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(lang)-crop-overwrite-asks.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                }
                func checkbox(_ v: NSView) -> Bool { ((v as? NSButton)?.title == L10n.t("rot.ask.remember", "以后都这样保存，不再询问") && !v.isHidden) || v.subviews.contains(where: checkbox) }
                expect(!(sheet.contentView.map(checkbox) ?? false), "that dialog has no remember checkbox")
                self.view.window?.endSheet(sheet, returnCode: .alertThirdButtonReturn)
            }
        }
        at(0.8) {
            expect(fileSize("grid.heic") == CGSize(width: 3000, height: 2000) && listing() == before && self.imageView.hasPendingRotation && Straighten.saveTarget == .overwrite,
                   "cancel: original untouched, crop still pending, preference still overwrite")
            // 记住的是「另存一份」：不动原图，裁剪也照记住的办，不问
            Straighten.saveTarget = .copy
            self.rotationBar.onSave?()
        }
        at(0.3) { expect(self.view.window?.attachedSheet == nil, "copy remembered + crop: no dialog") }
        idle {
            let name = listing().subtracting(before).first ?? "-"
            expect(name.contains(cropSuffix) && fileSize(name) == want && fileSize("grid.heic") == CGSize(width: 3000, height: 2000),
                   "copy remembered + crop: saved \(name) \(sizeText(fileSize(name))), original untouched")
        }
        at(0.6) { go("orient6.jpg") }
        at(1.2) {
            Straighten.saveTarget = .overwrite
            before = listing()
            self.rotateCW(nil)
        }
        at(2.5) {}
        idle {
            let m = CropSelfTest.meta(dir.appendingPathComponent("orient6.jpg"))
            expect(self.view.window?.attachedSheet == nil && m.contains("orient=3") && listing() == before && !self.imageView.hasPendingRotation,
                   "overwrite remembered + rotation only: saved by itself, no dialog | \(m)")
            Straighten.saveTarget = .ask
        }

        // ---- 10. 视频 / 清理模式下菜单不可用（和拉直原来一样的条件）
        at(0.6) {
            go("grid.jpg")
            let item = NSMenuItem(title: "", action: #selector(ViewerViewController.straighten(_:)), keyEquivalent: "")
            expect(self.validateMenuItem(item), "menu item enabled on a photo")
        }
        at(0.5) {
            Straighten.saveTarget = savedTarget
            Straighten.remindUnsaved = savedRemind
            NSLog("CROP end [%@] failures=%d", lang, failures)
            NSApp.terminate(nil)
        }
        runNext()
    }
}

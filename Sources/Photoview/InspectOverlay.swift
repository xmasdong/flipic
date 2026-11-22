import AppKit
import CoreGraphics
import ImageIO

// MARK: - 直方图（单图窗口右下角实时 RGB + 亮度 + 过曝/死黑占比）

struct PhotoHistogram: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luma: [Float]
    /// 过曝像素占比（0–100）
    var highlightPercent: Double
    /// 死黑像素占比（0–100）
    var shadowPercent: Double

    /// 缩到最长边 256 再数，1–2 毫秒；按 sRGB 统计，和屏幕显示一致
    static func compute(_ img: CGImage) -> PhotoHistogram? {
        let long = max(img.width, img.height)
        guard long > 0 else { return nil }
        let k = min(1, 256 / CGFloat(long))
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let total = w * h
        let px = data.bindMemory(to: UInt8.self, capacity: total * 4)
        var r = [Int](repeating: 0, count: 256), g = r, b = r, l = r
        var hiCount = 0, shCount = 0
        for i in 0..<total {
            let R = Int(px[i * 4]), G = Int(px[i * 4 + 1]), B = Int(px[i * 4 + 2])
            let Y = min(255, (R * 54 + G * 183 + B * 19) >> 8)
            r[R] += 1; g[G] += 1; b[B] += 1; l[Y] += 1
            if (R >= 253 && G >= 253 && B >= 253) || (max(R, max(G, B)) == 255 && Y >= 235) { hiCount += 1 }
            else if R <= 3 && G <= 3 && B <= 3 { shCount += 1 }
        }
        let peak = max(1, [r, g, b, l].map { $0[1...254].max() ?? 1 }.max() ?? 1)
        func norm(_ a: [Int]) -> [Float] { a.map { min(1, Float($0) / Float(peak)) } }
        return PhotoHistogram(red: norm(r), green: norm(g), blue: norm(b), luma: norm(l),
                              highlightPercent: Double(hiCount) * 100 / Double(total),
                              shadowPercent: Double(shCount) * 100 / Double(total))
    }
}

/// 单图看图器右下角悬浮直方图（按 H 开关）：RGB 叠加 + 亮度白线 + 底部死黑/过曝占比
final class ViewerHistogramView: NSVisualEffectView {
    var histogram: PhotoHistogram? { didSet { graph.histogram = histogram; updateStats() } }
    private let graph = HistogramCanvas()
    private let shadowLabel = NSTextField(labelWithString: "")
    private let highlightLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        toolTip = L10n.t("inspect.histogram", "直方图")

        graph.translatesAutoresizingMaskIntoConstraints = false
        for (l, col) in [(shadowLabel, NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 0.95)),
                         (highlightLabel, NSColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 0.95))] {
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            l.textColor = col
            l.translatesAutoresizingMaskIntoConstraints = false
        }
        highlightLabel.alignment = .right
        addSubview(graph)
        addSubview(shadowLabel)
        addSubview(highlightLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 204),
            heightAnchor.constraint(equalToConstant: 96),
            graph.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            graph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            graph.bottomAnchor.constraint(equalTo: shadowLabel.topAnchor, constant: -2),
            shadowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            shadowLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            highlightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            highlightLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateStats() {
        guard let h = histogram else { shadowLabel.stringValue = ""; highlightLabel.stringValue = ""; return }
        shadowLabel.stringValue = String(format: "S %.1f%%", h.shadowPercent)
        highlightLabel.stringValue = String(format: "H %.1f%%", h.highlightPercent)
        shadowLabel.alphaValue = h.shadowPercent >= 0.1 ? 1.0 : 0.45
        highlightLabel.alphaValue = h.highlightPercent >= 0.1 ? 1.0 : 0.45
    }

    var debugStats: String { "\(shadowLabel.stringValue) | \(highlightLabel.stringValue)" }
}

private final class HistogramCanvas: NSView {
    var histogram: PhotoHistogram? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let h = histogram, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 4, dy: 2)
        guard r.width > 4, r.height > 4 else { return }
        func path(_ v: [Float]) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            for (i, y) in v.enumerated() {
                p.addLine(to: CGPoint(x: r.minX + r.width * CGFloat(i) / 255, y: r.minY + r.height * CGFloat(y)))
            }
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.closeSubpath()
            return p
        }
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        for (v, c) in [(h.red, NSColor(srgbRed: 0.90, green: 0.22, blue: 0.22, alpha: 0.78)),
                       (h.green, NSColor(srgbRed: 0.22, green: 0.80, blue: 0.34, alpha: 0.78)),
                       (h.blue, NSColor(srgbRed: 0.28, green: 0.48, blue: 0.98, alpha: 0.78))] {
            ctx.addPath(path(v))
            ctx.setFillColor(c.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
        let line = CGMutablePath()
        for (i, y) in h.luma.enumerated() {
            let p = CGPoint(x: r.minX + r.width * CGFloat(i) / 255, y: r.minY + r.height * CGFloat(y))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.addPath(line)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.82).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

// MARK: - 过曝/死黑斑马纹警示（J）与 焦点峰值（K）叠加遮罩

enum InspectMask {
    /// 生成透明 RGBA 叠加遮罩（缩到最长边 ≤ 1024 算，4–8 ms，缩放拖动旋转全程与照片 1:1 贴合）
    static func render(_ img: CGImage, clipping: Bool, peaking: Bool) -> CGImage? {
        guard clipping || peaking else { return nil }
        let long = max(img.width, img.height)
        guard long > 0 else { return nil }
        let k = min(1, 1024 / CGFloat(long))
        let w = max(2, Int((CGFloat(img.width) * k).rounded()))
        let h = max(2, Int((CGFloat(img.height) * k).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srcCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let dstCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        srcCtx.interpolationQuality = .medium
        srcCtx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srcData = srcCtx.data, let dstData = dstCtx.data else { return nil }
        let n = w * h
        let src = srcData.bindMemory(to: UInt8.self, capacity: n * 4)
        let dst = dstData.bindMemory(to: UInt8.self, capacity: n * 4)
        memset(dst, 0, n * 4)

        // 1. 过曝（红）与 死黑（蓝）：斜向斑马条纹，既醒目又不彻底遮住纹理细节
        if clipping {
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    let p = (row + x) * 4
                    let R = Int(src[p]), G = Int(src[p + 1]), B = Int(src[p + 2])
                    let Y = (R * 54 + G * 183 + B * 19) >> 8
                    let stripe = ((x + y) / 3) & 1 == 0
                    if (R >= 253 && G >= 253 && B >= 253) || (max(R, max(G, B)) == 255 && Y >= 235) {
                        let a: UInt8 = stripe ? 215 : 120
                        dst[p] = a; dst[p + 1] = UInt8(Int(a) * 42 / 255); dst[p + 2] = UInt8(Int(a) * 42 / 255); dst[p + 3] = a
                    } else if R <= 3 && G <= 3 && B <= 3 {
                        let a: UInt8 = stripe ? 215 : 120
                        dst[p] = UInt8(Int(a) * 32 / 255); dst[p + 1] = UInt8(Int(a) * 128 / 255); dst[p + 2] = a; dst[p + 3] = a
                    }
                }
            }
        }

        // 2. 焦点峰值：计算 3×3 拉普拉斯锐度响应，按自适应高分位阈值标亮荧光青绿
        if peaking, w >= 4, h >= 4 {
            var luma = [Int32](repeating: 0, count: n)
            for i in 0..<n {
                let p = i * 4
                luma[i] = (Int32(src[p]) * 54 + Int32(src[p + 1]) * 183 + Int32(src[p + 2]) * 19) >> 8
            }
            var resp = [Int32](repeating: 0, count: n)
            var hist = [Int](repeating: 0, count: 256)
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let i = row + x
                    let c = luma[i]
                    let lap = abs(4 * c - luma[i - 1] - luma[i + 1] - luma[i - w] - luma[i + w])
                    let diag = abs(4 * c - luma[i - w - 1] - luma[i - w + 1] - luma[i + w - 1] - luma[i + w + 1])
                    let mag = min(255, (lap * 2 + diag) / 4)
                    resp[i] = mag
                    hist[Int(mag)] += 1
                }
            }
            // 取最锐利前 4% 为自适应阈值，同时保底 >= 42 避免平滑散景/低对比噪点误亮
            let target = max(1, (w - 2) * (h - 2) / 25)
            var acc = 0, thresh = 42
            for v in stride(from: 255, through: 42, by: -1) {
                acc += hist[v]
                if acc >= target { thresh = v; break }
            }
            let th = Int32(max(42, thresh))
            for i in 0..<n where resp[i] >= th {
                let p = i * 4
                let strength = min(230, 145 + Int(resp[i] - th) * 2)
                let a = UInt8(strength)
                // 亮青绿 (0, 238, 178) 预乘 alpha
                dst[p] = 0
                dst[p + 1] = UInt8(Int(a) * 238 / 255)
                dst[p + 2] = UInt8(Int(a) * 178 / 255)
                dst[p + 3] = a
            }
        }
        return dstCtx.makeImage()
    }
}

// MARK: - 相机对焦框解析（EXIF SubjectArea / XMP MWG-RS / Sony 0x2027 / Fujifilm 0x1023）

enum AFPointReader {
    /// 读取照片的对焦区域（归一化坐标 [0, 1]，左上原点，已按文件自身的 EXIF 方向转正）。没有记录时返回空数组
    static func read(url: URL) -> [CGRect] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        let rawW = CGFloat(props[kCGImagePropertyPixelWidth as String] as? Int ?? 0)
        let rawH = CGFloat(props[kCGImagePropertyPixelHeight as String] as? Int ?? 0)
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        var rawBoxes: [CGRect] = []

        // 1. 标准 EXIF SubjectArea (0x9214)：iPhone、徕卡、松下、部分相机
        if rawW > 0, rawH > 0,
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let area = (exif[kCGImagePropertyExifSubjectArea as String] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }),
           area.count >= 2 {
            let cx = CGFloat(area[0]) / rawW, cy = CGFloat(area[1]) / rawH
            let bw: CGFloat, bh: CGFloat
            if area.count >= 4 {
                bw = CGFloat(area[2]) / rawW; bh = CGFloat(area[3]) / rawH
            } else if area.count == 3 {
                bw = CGFloat(area[2]) / rawW; bh = CGFloat(area[2]) / rawH
            } else {
                bw = 0.055; bh = 0.055 * (rawW / rawH)
            }
            if let r = clampedBox(cx: cx, cy: cy, w: bw, h: bh) { rawBoxes.append(r) }
        }

        // 2. XMP MWG-RS Regions（Lightroom / 尼康 NX / 富士 / 索尼写出的 Focus / Face 区域）
        if rawBoxes.isEmpty, let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            let xmpBoxes = readMWGRegions(meta)
            if !xmpBoxes.isEmpty { return xmpBoxes }   // XMP 区域已是转正后坐标
        }

        // 3. 相机 MakerNotes：从文件头 TIFF IFD 提取 Sony FocusLocation (0x2027) / Fujifilm FocusPixel (0x1023)
        if rawBoxes.isEmpty, let mn = readMakerNoteAF(url: url, rawW: rawW, rawH: rawH) {
            rawBoxes.append(mn)
        }

        return rawBoxes.map { orient($0, exifOrientation: orientation) }
    }

    /// 把归一化对焦框按当前视图的 90° 顺时针旋转次数转到显示坐标（左上原点）
    static func rotated(_ rect: CGRect, quarterTurns: Int) -> CGRect {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 2: return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 3: return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default: return rect
        }
    }

    private static func orient(_ r: CGRect, exifOrientation o: Int) -> CGRect {
        switch o {
        case 2: return CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
        case 3: return rotated(r, quarterTurns: 2)
        case 4: return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        case 5: return CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
        case 6: return rotated(r, quarterTurns: 1)
        case 7: return CGRect(x: 1 - r.maxY, y: 1 - r.maxX, width: r.height, height: r.width)
        case 8: return rotated(r, quarterTurns: 3)
        default: return r
        }
    }

    private static func clampedBox(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGRect? {
        guard cx >= 0, cx <= 1, cy >= 0, cy <= 1 else { return nil }
        let bw = max(0.03, min(0.6, w)), bh = max(0.03, min(0.6, h))
        let x = max(0, min(1 - bw, cx - bw / 2))
        let y = max(0, min(1 - bh, cy - bh / 2))
        return CGRect(x: x, y: y, width: bw, height: bh)
    }

    private static func readMWGRegions(_ meta: CGImageMetadata) -> [CGRect] {
        var out: [CGRect] = []
        // Apple ImageIO 的 XMP 路径用点分隔、数组下标从 0 开始：mwg-rs:Regions.RegionList[0].Area.x
        for idx in 0..<8 {
            let base = "mwg-rs:Regions.RegionList[\(idx)]"
            guard CGImageMetadataCopyTagWithPath(meta, nil, "\(base).Area" as CFString) != nil else { break }
            let typeStr = (CGImageMetadataCopyStringValueWithPath(meta, nil, "\(base).Type" as CFString) as String?)?.lowercased()
            if let typeStr, typeStr != "focus" && typeStr != "face" { continue }
            func num(_ k: String) -> CGFloat? {
                guard let s = CGImageMetadataCopyStringValueWithPath(meta, nil, "\(base).Area.\(k)" as CFString) as String?,
                      let d = Double(s) else { return nil }
                return CGFloat(d)
            }
            if let x = num("x"), let y = num("y") {
                if let r = clampedBox(cx: x, cy: y, w: num("w") ?? 0.055, h: num("h") ?? 0.055) { out.append(r) }
            }
        }
        return out
    }

    /// 轻量边界安全的 MakerNote 解析（只读文件前 256 KB）：支持 Sony 0x2027 (FocusLocation) 与 Fujifilm 0x1023 (FocusPixel)
    private static func readMakerNoteAF(url: URL, rawW: CGFloat, rawH: CGFloat) -> CGRect? {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let data = try? fh.read(upToCount: 256 << 10) else { return nil }
        try? fh.close()
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n > 16 else { return nil }

        // 定位 TIFF 头（RAW 直接在 0，JPEG 在 APP1 "Exif\0\0" 后，Fujifilm RAF 在偏移 84 的内嵌 JPEG 内）
        var jpegStart = -1
        var tiffBase = -1
        if (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D) {
            tiffBase = 0
        } else if bytes[0] == 0xFF && bytes[1] == 0xD8 {
            jpegStart = 0
        } else if n > 92, bytes[0] == 0x46, bytes[1] == 0x55, bytes[2] == 0x4A, bytes[3] == 0x49 {
            let off = (Int(bytes[84]) << 24) | (Int(bytes[85]) << 16) | (Int(bytes[86]) << 8) | Int(bytes[87])
            if off > 0, off + 16 < n, bytes[off] == 0xFF, bytes[off + 1] == 0xD8 { jpegStart = off }
        }
        if jpegStart >= 0 {
            var pos = jpegStart + 2
            while pos + 4 < n, bytes[pos] == 0xFF {
                let marker = bytes[pos + 1]
                let len = Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
                if marker == 0xE1, pos + 10 < n,
                   bytes[pos + 4] == 0x45, bytes[pos + 5] == 0x78, bytes[pos + 6] == 0x69, bytes[pos + 7] == 0x66 {
                    tiffBase = pos + 10
                    break
                }
                if len < 2 { break }
                pos += 2 + len
            }
        }
        guard tiffBase >= 0, tiffBase + 8 <= n else { return nil }
        let le = bytes[tiffBase] == 0x49 && bytes[tiffBase + 1] == 0x49
        guard le || (bytes[tiffBase] == 0x4D && bytes[tiffBase + 1] == 0x4D) else { return nil }

        func u16(_ at: Int, _ little: Bool = le) -> Int? {
            guard at >= 0, at + 2 <= n else { return nil }
            return little ? (Int(bytes[at]) | Int(bytes[at + 1]) << 8) : (Int(bytes[at]) << 8 | Int(bytes[at + 1]))
        }
        func u32(_ at: Int, _ little: Bool = le) -> Int? {
            guard at >= 0, at + 4 <= n else { return nil }
            return little
                ? (Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24)
                : (Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]))
        }
        func findTag(ifdOffset: Int, base: Int, little: Bool, target: Int) -> (count: Int, valOffset: Int, rawValField: Int)? {
            guard let count = u16(base + ifdOffset, little), count > 0, count < 512 else { return nil }
            for i in 0..<count {
                let e = base + ifdOffset + 2 + i * 12
                guard e + 12 <= n, let tag = u16(e, little) else { break }
                if tag == target {
                    guard let cnt = u32(e + 4, little), let val = u32(e + 8, little) else { return nil }
                    return (cnt, base + val, e + 8)
                }
            }
            return nil
        }

        guard let ifd0 = u32(tiffBase + 4),
              let exifPtr = findTag(ifdOffset: ifd0, base: tiffBase, little: le, target: 0x8769),
              let exifIFD = u32(exifPtr.rawValField),
              let mnEntry = findTag(ifdOffset: exifIFD, base: tiffBase, little: le, target: 0x927C) else { return nil }
        let mnStart = mnEntry.valOffset
        guard mnStart >= 0, mnStart + 14 < n else { return nil }

        // Fujifilm MakerNote: "FUJIFILM" (8 bytes) + little-endian IFD offset at +8
        if bytes[mnStart] == 0x46, bytes[mnStart + 1] == 0x55, bytes[mnStart + 2] == 0x4A, bytes[mnStart + 3] == 0x49 {
            guard let fIfd = u32(mnStart + 8, true),
                  let fp = findTag(ifdOffset: fIfd, base: mnStart, little: true, target: 0x1023),
                  fp.count >= 2,
                  let fx = u16(fp.rawValField, true), let fy = u16(fp.rawValField + 2, true),
                  rawW > 0, rawH > 0 else { return nil }
            return clampedBox(cx: CGFloat(fx) / rawW, cy: CGFloat(fy) / rawH, w: 0.055, h: 0.055 * (rawW / rawH))
        }

        // Sony MakerNote: either "SONY DSC \0\0\0" (+12) or raw IFD at mnStart (offsets relative to tiffBase)
        let sonyIFD = (bytes[mnStart] == 0x53 && bytes[mnStart + 1] == 0x4F && bytes[mnStart + 2] == 0x4E && bytes[mnStart + 3] == 0x59)
            ? (mnStart + 12 - tiffBase) : (mnStart - tiffBase)
        if sonyIFD > 0, let fl = findTag(ifdOffset: sonyIFD, base: tiffBase, little: le, target: 0x2027), fl.count >= 4 {
            let p = fl.valOffset
            if let fw = u16(p), let fh = u16(p + 2), let fx = u16(p + 4), let fy = u16(p + 6), fw > 0, fh > 0 {
                return clampedBox(cx: CGFloat(fx) / CGFloat(fw), cy: CGFloat(fy) / CGFloat(fh), w: 0.055, h: 0.055 * CGFloat(fw) / CGFloat(fh))
            }
        }
        return nil
    }
}

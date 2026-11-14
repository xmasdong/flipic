import AppKit

/// 直方图：R、G、B 和亮度各 256 档，每档是像素个数。照片信息面板里看曝光用
struct Histogram {
    var red: [Int]
    var green: [Int]
    var blue: [Int]
    var luma: [Int]
    /// 数进去的像素个数
    var total: Int

    /// 解码时的最长边：512 像素够看出形状，JPEG 十几毫秒解完
    static let maxPixel: CGFloat = 512
    /// 最暗或最亮那一档的像素超过总数的这个比例（0.5%）才算溢出：几个高光点、一条黑边不算
    static let clipFraction = 0.005

    /// 哪几个通道在这一头溢出了：bin 是 0（暗部）或 255（高光）
    func clipped(at bin: Int) -> (red: Bool, green: Bool, blue: Bool) {
        let limit = Double(total) * Self.clipFraction
        return (Double(red[bin]) > limit, Double(green[bin]) > limit, Double(blue[bin]) > limit)
    }

    var shadowsClipped: Bool { let c = clipped(at: 0); return c.red || c.green || c.blue }
    var highlightsClipped: Bool { let c = clipped(at: 255); return c.red || c.green || c.blue }

    /// 按看图界面显示这张图的同一条路解一张小图再数：RAW 先用相机内嵌的预览，没有或太小才解 RAW，
    /// 其余格式由 ImageIO 降采样（带方向）。视频没有直方图
    static func compute(url: URL) -> Histogram? {
        guard !Video.isVideo(url),
              let img = ImageLoader.rawEmbeddedPreview(url: url, maxPixel: maxPixel)
                ?? ImageLoader.renderThumbnail(url: url, maxPixel: maxPixel) else { return nil }
        return count(img)
    }

    /// 在图自己的色彩空间里数（sRGB 的图数出来就是文件里的值，广色域的图不会因为换算到 sRGB 被算成溢出）；
    /// 灰度、CMYK、HDR 编码这些画不进 8 位 RGB 的，换到看图界面用的 Display P3 再数。
    /// 有透明度的图只数不透明的像素
    static func count(_ img: CGImage) -> Histogram? {
        let long = max(img.width, img.height)
        guard long > 0 else { return nil }
        let k = min(1, maxPixel / CGFloat(long))
        let w = max(1, Int((CGFloat(img.width) * k).rounded())), h = max(1, Int((CGFloat(img.height) * k).rounded()))
        var spaces: [CGColorSpace] = []
        if let cs = img.colorSpace, cs.model == .rgb, cs.supportsOutput, !CGColorSpaceUsesExtendedRange(cs), !CGColorSpaceUsesITUR_2100TF(cs) {
            spaces.append(cs)
        }
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3) { spaces.append(p3) }
        var context: CGContext?
        for space in spaces where context == nil {
            context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = context else { return nil }
        ctx.interpolationQuality = k < 1 ? .low : .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = [Int](repeating: 0, count: 256), g = r, b = r, l = r
        var total = 0
        for i in 0..<(w * h) where px[i * 4 + 3] == 255 {
            let R = Int(px[i * 4]), G = Int(px[i * 4 + 1]), B = Int(px[i * 4 + 2])
            r[R] += 1; g[G] += 1; b[B] += 1
            // Rec. 709 亮度
            l[min(255, (R * 54 + G * 183 + B * 19) >> 8)] += 1
            total += 1
        }
        guard total > 0 else { return nil }
        return Histogram(red: r, green: g, blue: b, luma: l, total: total)
    }

    /// 自测用：档数不多时逐档列出，否则只列两头和总数
    var debugSummary: String {
        func one(_ name: String, _ a: [Int]) -> String {
            let hit = a.enumerated().filter { $0.element > 0 }
            if hit.count <= 6 { return name + "{" + hit.map { "\($0.offset):\($0.element)" }.joined(separator: " ") + "}" }
            return String(format: "%@{0:%.2f%% 255:%.2f%% bins=%d}", name, Double(a[0]) * 100 / Double(total), Double(a[255]) * 100 / Double(total), hit.count)
        }
        return "total=\(total) " + [one("R", red), one("G", green), one("B", blue), one("L", luma)].joined(separator: " ")
            + " clip(shadows=\(shadowsClipped ? 1 : 0) highlights=\(highlightsClipped ? 1 : 0))"
    }
}

/// 后台算直方图，按文件缓存。缓存记着文件的修改时间：裁剪、旋转存盘后文件变了就重算
enum HistogramLoader {
    /// 一次请求；翻走了就 cancel，还没轮到的不再解码，算完的也不回调
    final class Ticket {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private struct Entry { let histogram: Histogram?; let modified: Date? }
    /// 最近用过的排在后面，超过 capacity 从前面丢
    private static var entries: [URL: Entry] = [:]
    private static var order: [URL] = []
    private static let capacity = 64
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "flipic.histogram", qos: .userInitiated)

    /// 缓存里现成的（不查文件有没有变，主线程可以调）：翻回刚看过的照片时先显示出来，随后 load 会核对
    static func peek(_ url: URL) -> Histogram? {
        lock.lock(); defer { lock.unlock() }
        return entries[url]?.histogram
    }

    /// 后台算（或取缓存），在主线程回调；算不出来（视频、解不了的文件）回调 nil
    @discardableResult
    static func load(_ url: URL, completion: @escaping (Histogram?) -> Void) -> Ticket {
        let ticket = Ticket()
        queue.async {
            guard !ticket.isCancelled else { return }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lock.lock()
            var hit = entries[url]
            if let h = hit, h.modified != modified { hit = nil }
            lock.unlock()
            let entry = hit ?? Entry(histogram: Histogram.compute(url: url), modified: modified)
            store(entry, for: url)
            DispatchQueue.main.async {
                if !ticket.isCancelled { completion(entry.histogram) }
            }
        }
        return ticket
    }

    private static func store(_ entry: Entry, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        entries[url] = entry
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }
}

/// 照片信息面板里的直方图：三色平涂叠在一起（叠到的地方变亮），亮度是一条细线，底下一条基线。
/// 左上角、右上角各一个小三角：暗部、高光溢出时亮起，颜色是溢出的那几个通道合起来的颜色
final class HistogramView: NSView {
    static let height: CGFloat = 84

    var histogram: Histogram? {
        didSet {
            normalize()
            var tips = [L10n.t("info.histogram", "直方图")]
            if histogram?.shadowsClipped == true { tips.append(L10n.t("info.clipShadows", "暗部溢出")) }
            if histogram?.highlightsClipped == true { tips.append(L10n.t("info.clipHighlights", "高光溢出")) }
            toolTip = tips.joined(separator: " · ")
            setAccessibilityLabel(toolTip)
            needsDisplay = true
        }
    }

    /// 每档 0–1 的高度，顺序 R、G、B、亮度
    private var curves: [[CGFloat]] = []

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.t("info.histogram", "直方图"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func normalize() {
        guard let h = histogram else { curves = []; return }
        let all = [h.red, h.green, h.blue, h.luma]
        // 两头（死黑、过曝）常常一档冲很高，归一时不算它们，免得中间的形状被压扁；冲出去的截在顶上
        let peak = CGFloat(max(1, all.map { $0[1...254].max() ?? 1 }.max() ?? 1))
        curves = all.map { $0.map { min(1, CGFloat($0) / peak) } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 自带一块深色底：三色叠加要在深色上才对，面板的磨砂底随背后的照片变
        let back = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(back)
        ctx.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45).cgColor)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(back)
        ctx.clip()
        let r = NSRect(x: bounds.minX + 6, y: bounds.minY + 6, width: bounds.width - 12, height: bounds.height - 12 - 6)
        func x(_ i: Int) -> CGFloat { r.minX + r.width * CGFloat(i) / 255 }
        if curves.count == 4 {
            ctx.saveGState()
            ctx.setBlendMode(.screen)
            let fills = [NSColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 0.75),
                         NSColor(srgbRed: 0.2, green: 0.75, blue: 0.3, alpha: 0.75),
                         NSColor(srgbRed: 0.25, green: 0.4, blue: 0.95, alpha: 0.75)]
            for (v, c) in zip(curves, fills) {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                for (i, y) in v.enumerated() { p.addLine(to: CGPoint(x: x(i), y: r.minY + r.height * y)) }
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.closeSubpath()
                ctx.addPath(p)
                ctx.setFillColor(c.cgColor)
                ctx.fillPath()
            }
            ctx.restoreGState()
            // 亮度只描轮廓
            let line = CGMutablePath()
            for (i, y) in curves[3].enumerated() {
                let p = CGPoint(x: x(i), y: r.minY + r.height * y)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.addPath(line)
            ctx.setStrokeColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        // 基线
        ctx.setFillColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28).cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY - 1, width: r.width, height: 1))
        // 溢出标记：左上暗部、右上高光
        let side: CGFloat = 7, top = bounds.maxY - 5
        func marker(_ points: [CGPoint], _ clip: (red: Bool, green: Bool, blue: Bool)?) {
            let lit = clip.map { $0.red || $0.green || $0.blue } ?? false
            let color = lit
                ? NSColor(srgbRed: clip!.red ? 1 : 0.15, green: clip!.green ? 0.95 : 0.15, blue: clip!.blue ? 1 : 0.2, alpha: 1)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16)
            ctx.beginPath()
            ctx.addLines(between: points)
            ctx.closePath()
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }
        marker([CGPoint(x: 5, y: top), CGPoint(x: 5 + side, y: top), CGPoint(x: 5, y: top - side)], histogram?.clipped(at: 0))
        marker([CGPoint(x: bounds.maxX - 5, y: top), CGPoint(x: bounds.maxX - 5 - side, y: top), CGPoint(x: bounds.maxX - 5, y: top - side)],
               histogram?.clipped(at: 255))
        ctx.restoreGState()
    }
}

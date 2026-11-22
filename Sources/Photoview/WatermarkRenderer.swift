import AppKit
import CoreGraphics
import CoreText

/// 把水印画到一张图上。纯函数：图 + 样式 + 文字 + 文件名 → 新图，不读不写任何文件（logo 由调用方给，或从 WatermarkStore 取）。
/// 在图自己的色彩空间里画（P3、Adobe RGB 都保持），位深不低于原图（8 位的图出 8 位，高位深的出 16 位）；
/// 字号、水印宽度、边距都按长边的比例算，所以 1000 像素和 6000 像素的图上看起来一样大。同样的输入出同样的结果，没有随机
enum WatermarkRenderer {
    /// 自测用：各阶段的耗时（毫秒）。平时是 nil，什么都不做
    static var profile: ((String, Double) -> Void)?
    private static func lap(_ name: String, _ t0: inout CFAbsoluteTime) {
        guard let profile else { return }
        let now = CFAbsoluteTimeGetCurrent()
        profile(name, (now - t0) * 1000)
        t0 = now
    }

    /// 角度的约定同屏幕：-30 = 文字向右上方倾斜（水印最常见的样子）；正数是向右下方
    static func render(_ image: CGImage, job: WatermarkJob, fileName: String?, date: Date = Date(),
                       store: WatermarkStore = .shared, index: Int? = nil) -> CGImage? {
        let logo = job.style.kind == .image ? store.logoImage(job.style.imageFile) : nil
        return render(image, style: job.style, text: job.effectiveText, fileName: fileName, date: date, logo: logo, index: index)
    }

    /// 返回 nil：画不出来（文字是空的、图片水印的 logo 找不到、建不出画布）。不透明度 0 原样返回传进来的图。
    /// text 给了就用它，没给用样式里的文字
    static func render(_ image: CGImage, style: WatermarkStyle, text: String? = nil, fileName: String?, date: Date = Date(),
                       logo: CGImage? = nil, index: Int? = nil) -> CGImage? {
        guard style.opacity > 0.0005 else { return image }
        var clock = CFAbsoluteTimeGetCurrent()
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let long = CGFloat(max(w, h))

        var block: Block?
        var sprite: CGImage?
        var spriteSize = CGSize.zero
        let unit: CGFloat
        switch style.kind {
        case .text:
            let raw = WatermarkTokens.expand(text ?? style.resolvedText, fileName: fileName, date: date, index: index)
            guard raw.contains(where: { !$0.isWhitespace && !$0.isNewline }) else { return nil }
            let fs = max(4, CGFloat(style.size) * long)
            unit = fs
            let align: Align = style.layout == .tiled ? .center : style.anchor.align
            block = Block(text: raw, fontSize: fs, bold: style.bold, align: align)
        case .image:
            guard let logo else { return nil }
            let tw = max(4, (CGFloat(style.size) * long).rounded())
            let th = max(2, (tw * CGFloat(logo.height) / CGFloat(logo.width)).rounded())
            spriteSize = CGSize(width: tw, height: th)
            sprite = scaledSprite(logo, to: spriteSize)
            guard sprite != nil else { return nil }
            unit = max(th, tw * 0.25)
        }
        let contentSize = block.map { CGSize(width: $0.width, height: $0.height) } ?? spriteSize

        guard let (ctx, cs) = makeContext(for: image) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: full)
        lap("base", &clock)

        // 每一块的位置（图像坐标，原点在左下）和旋转
        var spots: [CGPoint] = []
        var rotation: CGFloat = 0
        let pad = unit * 0.25 + 2
        var region = full
        if style.layout == .tiled {
            rotation = -CGFloat(style.angle) * .pi / 180
            let gapU = CGFloat(style.spacing) * unit * 2
            let gapV = CGFloat(style.spacing) * unit
            spots = tiledSpots(width: CGFloat(w), height: CGFloat(h), block: contentSize, gapU: gapU, gapV: gapV, rotation: rotation)
        } else {
            let m = CGFloat(style.margin) * long
            let cw = contentSize.width, ch = contentSize.height
            let x: CGFloat, y: CGFloat
            switch style.anchor.column {
            case 0: x = m + cw / 2
            case 2: x = CGFloat(w) - m - cw / 2
            default: x = CGFloat(w) / 2
            }
            switch style.anchor.row {
            case 0: y = CGFloat(h) - m - ch / 2
            case 2: y = m + ch / 2
            default: y = CGFloat(h) / 2
            }
            spots = [CGPoint(x: x, y: y)]
            region = CGRect(x: x - cw / 2 - pad, y: y - ch / 2 - pad, width: cw + 2 * pad, height: ch + 2 * pad).integral.intersection(full)
            if region.isNull || region.isEmpty { return ctx.makeImage() }
        }

        lap("layout", &clock)
        if let block {
            drawText(block, style: style, spots: spots, rotation: rotation, region: region, ctx: ctx, colorSpace: cs)
            lap("text", &clock)
        } else if let sprite {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(style.opacity))
            ctx.interpolationQuality = .high
            for p in spots {
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: rotation)
                ctx.draw(sprite, in: CGRect(x: -spriteSize.width / 2, y: -spriteSize.height / 2, width: spriteSize.width, height: spriteSize.height))
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
        let out = ctx.makeImage()
        lap("makeImage", &clock)
        return out
    }

    // MARK: - 画布

    /// 和原图同一个色彩空间、同样或更高的位深。灰度等非 RGB 的图改用 sRGB
    private static func makeContext(for image: CGImage) -> (CGContext, CGColorSpace)? {
        let cs: CGColorSpace = {
            if let s = image.colorSpace, s.model == .rgb { return s }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let deep = image.bitsPerComponent > 8
        let float = deep && image.bitmapInfo.contains(.floatComponents)
        var tries: [(Int, UInt32)] = []
        if float {
            tries.append((16, CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        }
        if deep {
            tries.append((16, hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
            tries.append((16, CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        tries.append((8, hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
        for (bpc, info) in tries {
            if let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bpc, bytesPerRow: 0, space: cs, bitmapInfo: info) {
                return (ctx, cs)
            }
        }
        return nil
    }

    /// logo 缩到最终的像素尺寸（缩小时用高质量插值）；要放大就原样用，画的时候再放
    private static func scaledSprite(_ logo: CGImage, to size: CGSize) -> CGImage? {
        let tw = Int(size.width), th = Int(size.height)
        guard tw < logo.width else { return logo }
        let cs = logo.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(logo, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    // MARK: - 平铺的位置

    /// 在旋转后的坐标里一行一行排，奇数行错开半块；转回图像坐标，只留下和图有重叠的
    static func tiledSpots(width: CGFloat, height: CGFloat, block: CGSize, gapU: CGFloat, gapV: CGFloat, rotation: CGFloat) -> [CGPoint] {
        let stepU = max(block.width + gapU, 4), stepV = max(block.height + gapV, 4)
        let radius = hypot(block.width, block.height) / 2
        let reach = hypot(width, height) / 2 + radius
        let rows = Int((reach / stepV).rounded(.up)) + 1
        let cols = Int((reach / stepU).rounded(.up)) + 1
        let cx = width / 2, cy = height / 2
        let c = cos(rotation), s = sin(rotation)
        var out: [CGPoint] = []
        for r in -rows...rows {
            let shift: CGFloat = (r & 1 == 0) ? 0 : stepU / 2
            for k in -cols...cols {
                let u = CGFloat(k) * stepU + shift, v = CGFloat(r) * stepV
                let x = cx + u * c - v * s, y = cy + u * s + v * c
                // 离图太远的块不画：中心到图的距离超过块的半径
                let dx = max(0, abs(x - cx) - width / 2), dy = max(0, abs(y - cy) - height / 2)
                if hypot(dx, dy) > radius { continue }
                out.append(CGPoint(x: x, y: y))
                if out.count > 12_000 { return out }
            }
        }
        return out
    }

    // MARK: - 文字

    enum Align { case left, center, right }

    private struct Block {
        struct Line { let line: CTLine; let width: CGFloat; let asc: CGFloat; let desc: CGFloat; var x: CGFloat = 0; var baseline: CGFloat = 0 }
        var lines: [Line] = []
        var lineHeight: CGFloat = 0
        /// 字形真正画到的范围（块自己的坐标，原点是排版的中心）。边距、平铺的间隔都按它算，所以离边的距离看上去就是设定的那么多
        var ink = CGRect.zero
        var width: CGFloat { ink.width }
        var height: CGFloat { ink.height }

        init(text: String, fontSize: CGFloat, bold: Bool, align: Align) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
            let rows = text.components(separatedBy: .newlines)
            for r in rows {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: r.isEmpty ? " " : r, attributes: attrs))
                var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
                let wd = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
                lines.append(Line(line: line, width: wd, asc: a, desc: d))
            }
            lineHeight = fontSize * 1.25
            let blockW = lines.map(\.width).max() ?? 0
            var union = CGRect.null
            for i in lines.indices {
                let centerY = (CGFloat(lines.count - 1) / 2 - CGFloat(i)) * lineHeight
                lines[i].baseline = centerY - (lines[i].asc - lines[i].desc) / 2
                switch align {
                case .left: lines[i].x = -blockW / 2
                case .right: lines[i].x = blockW / 2 - lines[i].width
                case .center: lines[i].x = -lines[i].width / 2
                }
                let b = CTLineGetBoundsWithOptions(lines[i].line, .useGlyphPathBounds)
                // 全是空格的行没有墨迹，不参与
                if b.width > 0, b.height > 0 { union = union.union(b.offsetBy(dx: lines[i].x, dy: lines[i].baseline)) }
            }
            ink = union.isNull ? CGRect(x: -blockW / 2, y: -lineHeight / 2, width: blockW, height: lineHeight) : union
        }
    }

    /// 文字走「遮罩」：在一张只有透明度的画布上画出字形，再用它裁剪、按不透明度填色。
    /// 好处是字和描边、阴影的颜色各填一次，不会叠在一起变脏，而且整张图只合成一遍，快
    private static func drawText(_ block: Block, style: WatermarkStyle, spots: [CGPoint], rotation: CGFloat, region: CGRect,
                                 ctx: CGContext, colorSpace: CGColorSpace) {
        let rw = Int(region.width), rh = Int(region.height)
        guard rw > 0, rh > 0 else { return }
        let fontSize = block.lineHeight / 1.25

        func maskContext() -> CGContext? {
            let m = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            m?.setAllowsFontSmoothing(false)
            m?.setShouldAntialias(true)
            m?.translateBy(x: -region.minX, y: -region.minY)
            return m
        }

        func lay(_ m: CGContext, at p: CGPoint, dx: CGFloat = 0, dy: CGFloat = 0, mode: CGTextDrawingMode, lineWidth: CGFloat = 0, clear: Bool = false) {
            m.saveGState()
            if clear { m.setBlendMode(.clear) }
            m.setFillColor(gray: 1, alpha: 1)
            m.setStrokeColor(gray: 1, alpha: 1)
            m.setLineWidth(lineWidth)
            m.setLineJoin(.round)
            m.setTextDrawingMode(mode)
            m.translateBy(x: p.x + dx, y: p.y + dy)
            m.rotate(by: rotation)
            m.translateBy(x: -block.ink.midX, y: -block.ink.midY)
            for l in block.lines {
                m.textMatrix = .identity
                m.textPosition = CGPoint(x: l.x, y: l.baseline)
                CTLineDraw(l.line, m)
            }
            m.restoreGState()
        }

        func paint(_ mask: CGContext, color: (r: Double, g: Double, b: Double), alpha: CGFloat) {
            guard let img = mask.makeImage() else { return }
            ctx.saveGState()
            ctx.clip(to: region, mask: img)
            ctx.setAlpha(alpha)
            ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [CGFloat(color.r), CGFloat(color.g), CGFloat(color.b), 1])!)
            ctx.fill(region)
            ctx.restoreGState()
        }

        let opacity = CGFloat(style.opacity)
        var clock = CFAbsoluteTimeGetCurrent()
        // 描边和阴影：画在字的外面（字形里面挖掉），颜色和字相反
        if style.edge != .none, let edge = maskContext() {
            // 描一圈的字形太慢（24 MP 上几十毫秒）：阴影是错开的两份字形，描边是八个方向错开的字形，都是填充，快得多
            let d = fontSize * 0.045
            let offsets: [(CGFloat, CGFloat)]
            if style.edge == .outline {
                offsets = (0..<8).map { i in (d * cos(CGFloat(i) * .pi / 4), d * sin(CGFloat(i) * .pi / 4)) }
            } else {
                offsets = [(d, -d), (d * 1.8, -d * 1.8)]
            }
            for off in offsets { for p in spots { lay(edge, at: p, dx: off.0, dy: off.1, mode: .fill) } }
            lap("edgeGlyphs", &clock)
            for p in spots { lay(edge, at: p, mode: .fill, clear: true) }
            lap("edgeClear", &clock)
            paint(edge, color: style.edgeRGB, alpha: opacity * (style.edge == .shadow ? 0.75 : 0.9))
            lap("edgePaint", &clock)
        }
        if let fill = maskContext() {
            for p in spots { lay(fill, at: p, mode: .fill) }
            lap("fillGlyphs", &clock)
            paint(fill, color: style.rgb, alpha: opacity)
            lap("fillPaint", &clock)
        }
    }
}

extension WatermarkStyle.Anchor {
    /// 0 左 1 中 2 右
    var column: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: return 0
        case .top, .center, .bottom: return 1
        case .topRight, .right, .bottomRight: return 2
        }
    }

    /// 0 上 1 中 2 下
    var row: Int {
        switch self {
        case .topLeft, .top, .topRight: return 0
        case .left, .center, .right: return 1
        case .bottomLeft, .bottom, .bottomRight: return 2
        }
    }

    fileprivate var align: WatermarkRenderer.Align {
        switch column {
        case 0: return .left
        case 2: return .right
        default: return .center
        }
    }
}

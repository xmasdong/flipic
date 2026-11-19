import AppKit
import CoreImage

/// 加边框：照片原样放到一块更大的画布上，不裁掉任何地方。原比例 = 四边等宽；其余比例 = 照片完整放进那个比例的画布、居中，
/// 短的那个方向留得多。看图里的「照片 › 加边框…」、导出和批量转换、导出预设共用这一份设置和同一个渲染
struct BorderSpec: Codable, Equatable {
    enum Fill: Int, Codable { case white, black, blur, custom }
    /// 画布的宽:高；0:0 = 原比例。pixels = 宽高是画布的像素尺寸（自定义里填了大于 100 的数）
    var w = 0, h = 0
    var pixels = false
    var fill = Fill.white
    /// 自选的颜色，0xRRGGBB（sRGB）
    var rgb = 0xFFFFFF
    /// 照片离画布最近的边至少留多少（画布短边的百分比，0–20）。原比例和固定比例各记一份：原比例默认 5%，固定比例默认 0%（照片贴满一个方向）
    var equalPercent = 5.0, fitPercent = 0.0
    /// 看图里另存的长边，0 = 原尺寸（照片保持全部像素）
    var edge = 0, customEdge = false

    var percent: Double {
        get { w == 0 ? equalPercent : fitPercent }
        set { if w == 0 { equalPercent = newValue } else { fitPercent = newValue } }
    }

    var size: SaveSize.Choice {
        get { edge <= 0 ? .original : customEdge ? .custom(edge) : .preset(edge) }
        set {
            edge = newValue.longEdge ?? 0
            if case .custom = newValue { customEdge = true } else { customEdge = false }
        }
    }

    var isPixels: Bool { pixels && w > 0 && h > 0 }

    static let ratios = [(0, 0), (1, 1), (4, 5), (3, 4), (9, 16), (16, 9)]

    /// 测试用：换成临时的偏好设置
    static var defaults: UserDefaults = .standard

    /// 上次的设置（连着给一组照片加同样的边框）
    static var saved: BorderSpec {
        get { defaults.data(forKey: "border.spec").flatMap { try? JSONDecoder().decode(BorderSpec.self, from: $0) } ?? BorderSpec() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "border.spec") }
    }

    static var fillTitles: [String] {
        [L10n.t("border.white", "白"), L10n.t("border.black", "黑"), L10n.t("border.blur", "模糊背景"), L10n.t("border.pick", "自选")]
    }

    var ratioTitle: String { w <= 0 || h <= 0 ? L10n.t("crop.original", "原比例") : isPixels ? "\(w) × \(h)" : "\(w):\(h)" }
    /// 比如「4:5 · 白 · 5%」
    var summary: String { "\(ratioTitle) · \(Self.fillTitles[fill.rawValue]) · \(Int(percent))%" }

    var color: CGColor {
        switch fill {
        case .black: return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .custom: return CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        default: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    /// 自定义画布：宽高 1–20000 的整数。都不超过 100 是比例，否则是像素尺寸（两边都至少 64）
    static func parseCustom(_ a: String, _ b: String) -> (w: Int, h: Int)? {
        let t = { (s: String) in Int(s.trimmingCharacters(in: .whitespaces)) }
        guard let w = t(a), let h = t(b), (1...20000).contains(w), (1...20000).contains(h),
              max(w, h) <= 100 || min(w, h) >= SaveSize.minEdge else { return nil }
        return (w, h)
    }

    /// 原尺寸时的画布和照片在上面的位置（左上原点、像素）。照片保持 p 的像素；像素画布时照片缩放到放得下
    func layout(_ p: CGSize) -> (canvas: CGSize, photo: CGRect) {
        guard p.width > 0, p.height > 0 else { return (.zero, .zero) }
        let t = CGFloat(max(0, min(20, percent))) / 100
        var c: CGSize
        if w <= 0 || h <= 0 {
            // 边宽 g = t × 画布短边 = t × (照片短边 + 2g)
            let g = (t * min(p.width, p.height) / (1 - 2 * t)).rounded()
            c = CGSize(width: p.width + 2 * g, height: p.height + 2 * g)
        } else if isPixels {
            c = CGSize(width: w, height: h)
        } else {
            // 画布 = (a, b) × u，短边 u；照片两个方向都要放得下（各留 2g = 2tu）
            let r = CGFloat(w) / CGFloat(h), a = max(r, 1), b = max(1 / r, 1)
            let u = max(p.width / (a - 2 * t), p.height / (b - 2 * t))
            c = CGSize(width: max(p.width, (a * u).rounded()), height: max(p.height, (b * u).rounded()))
        }
        let g = t * min(c.width, c.height)
        let s = isPixels ? min((c.width - 2 * g) / p.width, (c.height - 2 * g) / p.height) : 1
        return (c, Self.centered(CGSize(width: p.width * s, height: p.height * s), in: c))
    }

    static func centered(_ s: CGSize, in c: CGSize) -> CGRect {
        let w = max(1, s.width.rounded()), h = max(1, s.height.rounded())
        return CGRect(x: ((c.width - w) / 2).rounded(.down), y: ((c.height - h) / 2).rounded(.down), width: w, height: h)
    }

    /// 存出来的画布尺寸：像素画布就是那么大，否则按 choice 缩（不放大，取整和 SaveSize 一样）
    func output(_ p: CGSize, choice: SaveSize.Choice) -> CGSize {
        let c = layout(p).canvas
        return isPixels ? c : SaveSize.output(native: c, choice: choice)
    }

    /// 出图：画布（底色或模糊背景）+ 照片（缩小用 Lanczos）。照片的色彩空间保持，8 位
    func render(_ img: CGImage, choice: SaveSize.Choice) -> CGImage? {
        let p = CGSize(width: img.width, height: img.height)
        let (c, r0) = layout(p)
        let o = output(p, choice: choice)
        guard c.width > 0, o.width >= 1, o.height >= 1 else { return nil }
        let k = o.width / c.width
        let r = Self.centered(CGSize(width: r0.width * k, height: r0.height * k), in: o)
        func context(_ cs: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: Int(o.width), height: Int(o.height), bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let ctx = context(Self.rgb(img)) ?? context(CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        ctx.interpolationQuality = .high
        let all = CGRect(origin: .zero, size: o)
        if fill == .blur, let b = Self.backdrop(img, aspect: o) { ctx.draw(b, in: all) } else { ctx.setFillColor(color); ctx.fill(all) }
        let long = Int(max(r.width, r.height))
        let photo = long < max(img.width, img.height) ? ImageExporter.scaled(img, longEdge: long) ?? img : img
        ctx.draw(photo, in: CGRect(x: r.minX, y: o.height - r.maxY, width: r.width, height: r.height))
        return ctx.makeImage()
    }

    static func rgb(_ img: CGImage) -> CGColorSpace {
        img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// 模糊背景：照片铺满画布（多出来的不要）、高斯模糊、稍微压暗。只做 256 像素的小图，画的时候放大（反正是糊的）
    static func backdrop(_ img: CGImage, aspect o: CGSize) -> CGImage? {
        guard o.width > 0, o.height > 0 else { return nil }
        let k = 256 / max(o.width, o.height)
        let w = max(1, (o.width * k).rounded()), h = max(1, (o.height * k).rounded())
        let ci = CIImage(cgImage: img)
        let s = max(w / ci.extent.width, h / ci.extent.height)
        let out = ci.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: (w - ci.extent.width * s) / 2, y: (h - ci.extent.height * s) / 2)))
            .clampedToExtent().applyingGaussianBlur(sigma: 10)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.5])
        return ImageExporter.ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: rgb(img))
    }
}

/// 加边框时盖在看图视图上的预览：灰底上一块画布，照片按比例放在上面。图层直接摆，拖滑块不卡
final class BorderPreview: NSView {
    private let canvas = CALayer(), photo = CALayer()
    /// 底部那条占掉的高度
    var inset: CGFloat = 0 { didSet { if inset != oldValue { needsLayout = true } } }
    private var spec = BorderSpec(), native = CGSize.zero, blurKey = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0.16, alpha: 1)
        canvas.contentsGravity = .resize
        photo.contentsGravity = .resize
        canvas.addSublayer(photo)
        layer?.addSublayer(canvas)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage?, native n: CGSize, spec s: BorderSpec) {
        spec = s
        native = n.width > 0 ? n : image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.contents = image
        canvas.backgroundColor = s.color
        let c = s.layout(native).canvas
        let key = image.map { "\(ObjectIdentifier($0).hashValue) \(Int(c.width)) \(Int(c.height))" } ?? ""
        if s.fill != .blur { canvas.contents = nil; blurKey = "" }
        else if key != blurKey, let image { canvas.contents = BorderSpec.backdrop(image, aspect: c); blurKey = key }
        CATransaction.commit()
        layoutLayers()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        let (c, r) = spec.layout(native)
        let area = CGRect(x: 24, y: 24, width: bounds.width - 48, height: bounds.height - 48 - inset)
        guard c.width > 0, area.width > 0, area.height > 0 else { return }
        let s = min(area.width / c.width, area.height / c.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = CGRect(x: area.midX - c.width * s / 2, y: area.midY - c.height * s / 2, width: c.width * s, height: c.height * s)
        photo.frame = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
        CATransaction.commit()
    }

    // 预览开着时不拖、不缩放照片
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}

    var debugFrames: (canvas: CGRect, photo: CGRect) { (canvas.frame, photo.frame) }
}

/// 加边框时底部那条（借裁剪条的外观）：比例、颜色、边宽、尺寸（就是保存对话框里那一组），取消 / 另存一份
final class BorderSession: NSObject {
    private(set) var spec: BorderSpec
    let preview = BorderPreview()
    let row = NSStackView()
    let size: SaveSizeRow
    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    private(set) weak var customAlert: NSAlert?
    private var native: CGSize
    private let ratioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fillControl = NSSegmentedControl(labels: BorderSpec.fillTitles, trackingMode: .selectOne, target: nil, action: nil)
    private let well = NSColorWell()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let pctLabel = NSTextField(labelWithString: "")

    init(native n: CGSize) {
        native = n
        let saved = BorderSpec.saved
        spec = saved
        size = SaveSizeRow(native: saved.layout(n).canvas, initial: saved.size)
        super.init()
        let L = { (s: String) in RotationBar.label(s, bold: true) }
        for (w, h) in BorderSpec.ratios { ratioPopup.addItem(withTitle: w == 0 ? L10n.t("border.equal", "原比例（等宽边框）") : "\(w):\(h)") }
        ratioPopup.menu?.addItem(.separator())
        ratioPopup.addItem(withTitle: L10n.t("crop.custom", "自定义…"))
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioPicked)
        fillControl.target = self
        fillControl.action = #selector(fillPicked)
        well.target = self
        well.action = #selector(colorPicked)
        well.colorWellStyle = .minimal
        slider.target = self
        slider.action = #selector(slid)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pctLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let cancel = RotationBar.button(L10n.t("rot.bar.cancel", "取消"), #selector(cancelClicked), self)
        let save = RotationBar.button(L10n.t("rot.copy", "另存一份"), #selector(saveClicked), self)
        save.bezelColor = .controlAccentColor
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [L(L10n.t("rot.bar.aspect", "比例")), ratioPopup, L(L10n.t("border.color", "颜色")), fillControl, well])
        top.setCustomSpacing(16, after: ratioPopup)
        let bottom = NSStackView(views: [L(L10n.t("border.width", "边宽")), slider, pctLabel, L(L10n.t("border.size", "尺寸")),
                                         size.popup, size.field, size.pxLabel, size.result, gap, cancel, save])
        bottom.setCustomSpacing(16, after: pctLabel)
        for r in [top, bottom] {
            r.orientation = .horizontal
            r.alignment = .centerY
            r.spacing = 8
            row.addArrangedSubview(r)
        }
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 8
        size.onChange = { [weak self] in self?.sizeChanged() }
        sync()
    }

    /// 换了照片（翻页、草图换清晰图、旋转）
    func setNative(_ n: CGSize) {
        native = n
        sync()
    }

    /// 测试用：直接换一套设置（和在条上点选走同一条路）
    func debugSet(_ s: BorderSpec) {
        spec = s
        size.select(s.size)
        sync()
    }

    func end() {
        if well.isActive { well.deactivate(); NSColorPanel.shared.orderOut(nil) }
        if let a = customAlert, let w = row.window { w.endSheet(a.window) }
    }

    private func sync() {
        if let i = BorderSpec.ratios.firstIndex(where: { $0 == (spec.w, spec.h) && !spec.isPixels }) {
            ratioPopup.lastItem?.title = L10n.t("crop.custom", "自定义…")
            ratioPopup.selectItem(at: i)
        } else {
            ratioPopup.lastItem?.title = spec.ratioTitle
            ratioPopup.select(ratioPopup.lastItem)
        }
        fillControl.selectedSegment = spec.fill.rawValue
        well.color = NSColor(cgColor: BorderSpec(fill: .custom, rgb: spec.rgb).color) ?? .white
        slider.doubleValue = spec.percent
        pctLabel.stringValue = "\(Int(spec.percent))%"
        size.popup.isEnabled = !spec.isPixels
        size.native = spec.layout(native).canvas
        sizeChanged()
        onChange?()
    }

    private func sizeChanged() {
        spec.size = size.choice
        if spec.isPixels { size.result.stringValue = L10n.f("rot.size.result", "导出 %@", SaveSize.text(CGSize(width: spec.w, height: spec.h))) }
        BorderSpec.saved = spec
    }

    @objc private func ratioPicked() {
        let i = ratioPopup.indexOfSelectedItem
        guard i < BorderSpec.ratios.count else { askCustom(); return }
        (spec.w, spec.h) = BorderSpec.ratios[i]
        spec.pixels = false
        sync()
    }

    private func askCustom() {
        sync()
        let alert = NSAlert()
        alert.messageText = L10n.t("border.custom.title", "自定义画布")
        alert.informativeText = L10n.t("border.custom.info", "填 1 到 100 是比例（如 4 : 5），填更大的数是像素尺寸（如 1920 : 1080）")
        let apply = alert.addButton(withTitle: L10n.t("crop.custom.apply", "应用"))
        alert.addButton(withTitle: L10n.t("rot.bar.cancel", "取消")).keyEquivalent = "\u{1b}"
        let fields = CustomRatioFields(width: spec.w > 0 ? spec.w : 4, height: spec.h > 0 ? spec.h : 5, parse: BorderSpec.parseCustom) { ok in apply.isEnabled = ok }
        alert.accessoryView = fields
        alert.window.initialFirstResponder = fields.widthField
        customAlert = alert
        let done = { [weak self, weak fields] (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn, let self, let v = fields?.value else { return }
            (self.spec.w, self.spec.h) = (v.w, v.h)
            self.spec.pixels = max(v.w, v.h) > 100
            self.sync()
        }
        if let w = row.window { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }

    @objc private func fillPicked() {
        spec.fill = BorderSpec.Fill(rawValue: fillControl.selectedSegment) ?? .white
        if spec.fill == .custom, !well.isActive { well.activate(true) }
        sync()
    }

    @objc private func colorPicked() {
        guard let c = well.color.usingColorSpace(.sRGB) else { return }
        let v = { (x: CGFloat) in Int((max(0, min(1, x)) * 255).rounded()) }
        spec.rgb = v(c.redComponent) << 16 | v(c.greenComponent) << 8 | v(c.blueComponent)
        spec.fill = .custom
        sync()
    }

    @objc private func slid() {
        spec.percent = slider.doubleValue.rounded()
        sync()
    }

    @objc private func cancelClicked() { onCancel?() }
    @objc private func saveClicked() { onSave?() }
}

extension ViewerViewController {
    /// 照片 › 加边框…（⇧B）：底部出现加边框的条，看图区换成加好边框的样子；回车另存一份，Esc 取消。再按一次收起
    @objc func addBorder(_ sender: Any?) {
        if border != nil { closeBorder(); return }
        guard folder.current != nil, cleanup == nil, !isStraightening, !isProcessing else { return }
        guard !currentIsVideo, imageView.canStraighten else {
            flash(L10n.t("border.unavailable", "视频和动图不能加边框"))
            return
        }
        let s = BorderSession(native: imageView.pixelSize)
        border = s
        s.onChange = { [weak self] in self?.refreshBorder() }
        s.onCancel = { [weak self] in self?.closeBorder() }
        s.onSave = { [weak self] in self?.saveBorder() }
        s.preview.frame = imageView.bounds
        imageView.addSubview(s.preview)
        rotationBar.showExtra(s.row)
        imageView.onImageSet = { [weak self] in DispatchQueue.main.async { self?.borderImageChanged() } }
        refreshBorder()
        updateCropInset()
    }

    func refreshBorder() {
        guard let b = border else { return }
        b.preview.show(imageView.currentImage, native: imageView.pixelSize, spec: b.spec)
    }

    /// 换了照片：视频、动图收起，照片换成这一张的预览
    func borderImageChanged() {
        guard let b = border else { return }
        guard folder.current != nil, cleanup == nil, !currentIsVideo, imageView.canStraighten else { closeBorder(); return }
        b.setNative(imageView.pixelSize)
    }

    func closeBorder() {
        guard let b = border else { return }
        border = nil
        b.end()
        b.preview.removeFromSuperview()
        imageView.onImageSet = nil
        rotationBar.showExtra(nil)
        updateRotationBar()
    }

    /// 另存一份：屏幕上看到的样子（转过、裁过的照片 + 边框），拍摄信息保留，原图不动
    func saveBorder() {
        guard let b = border, let url = folder.current?.url, !isProcessing else { return }
        let spec = b.spec, turns = imageView.rotationTurns, degrees = imageView.fineDegrees, crop = imageView.cropSpec
        closeBorder()
        isProcessing = true
        flash(L10n.t("msg.rotSaving", "保存中…"), seconds: 3600)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = Straighten.save(url: url, quarterTurns: turns, degrees: degrees, crop: crop, overwrite: false, border: spec)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                if let saved = out.url {
                    self.flash(L10n.f("msg.rotSavedAs", "已另存为 %@", saved.lastPathComponent), seconds: 3)
                    self.folderDidChange()
                } else {
                    self.flash(L10n.f("msg.rotFailed", "保存失败： %@", " "), seconds: 3)
                }
            }
        }
    }

    /// 加边框时：回车另存、Esc 取消；别的键照常（翻页、空格都不变）
    func handleBorderKey(_ event: NSEvent) -> Bool {
        guard border != nil, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 53: closeBorder()
        case 36, 76: saveBorder()
        default: return false
        }
        return true
    }
}

import AppKit
import QuartzCore
import CoreImage

/// 以 CALayer 承载 CGImage 的可缩放平移视图。
/// scale 是「每个原图像素对应多少屏幕点」，origin 是图像左上角在视图（翻转坐标系）里的位置。
/// 坐标按原图逻辑尺寸计算，图层里放的可以是降采样预览：换成全分辨率图时画面不跳、比例不变。
final class ZoomableImageView: NSView {

    var onZoomChange: ((CGFloat) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onFirst: (() -> Void)?
    var onLast: (() -> Void)?
    var onToggleInfo: (() -> Void)?
    var onToggleFilmstrip: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onTrash: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSlideshow: (() -> Void)?
    var onRename: (() -> Void)?
    /// 其余自定义快捷键交给看图界面处理
    var onCommand: ((ShortcutAction) -> Void)?
    var onActivity: (() -> Void)?
    var onFirstFrame: ((CGSize) -> Void)?
    /// 放大到当前图层图片分辨率不够用时触发一次（每张图最多一次），由上层去解码全分辨率图
    var onNeedsDetail: (() -> Void)?
    /// 空格开 / 关「窗口贴合图片」预览（同访达空格预览）；onPeekBegin 返回 false 表示当前不能进入（如全屏）
    var onPeekBegin: (() -> Bool)?
    var onPeekEnd: (() -> Void)?
    /// 并排对比：鼠标按下（用来切换当前格）、缩放或位置变了（同步给其他格）
    var onMouseDown: (() -> Void)?
    var onViewChange: ((ViewState, Bool) -> Void)?
    /// 照片在视图里的位置变了（缩放、平移、换图、视图变大小）：叠在照片上的实况文本跟着对齐
    var onImageFrameChange: (() -> Void)?
    /// 旋转了视图：显示的图换了，之前识别出的文字位置作废
    var onRotate: (() -> Void)?

    private enum Mode { case fit, free }

    private let imageLayer = CALayer()
    /// 照片没铺满时露出来的底：这张照片缩成几十像素再模糊、压暗后铺满整个视图
    private let backdropLayer = CALayer()
    private var backdropGeneration = 0
    /// 只有主看图界面用磨砂底；并排对比、修图前后对比要比颜色，保持纯黑
    var allowsBackdrop = false { didSet { refreshBackdrop() } }
    /// 全屏时的「磨砂玻璃」：窗口后面没东西可透，改用照片的明暗（去掉颜色）模糊出来当底
    var monoBackdrop = false { didSet { if oldValue != monoBackdrop { refreshBackdrop() } } }
    /// 固定的底图（全屏时模糊过的桌面壁纸），设了就不再按照片生成
    var backdropOverride: CGImage? { didSet { refreshBackdrop() } }
    private var image: CGImage?          // 当前显示（已应用旋转）的图
    private var baseImage: CGImage?      // 未旋转原图
    private var quarterTurns = 0
    /// 拉直的角度（顺时针为正，±45°），在 90° 旋转之后再转；转完居中裁成同比例的正矩形
    private(set) var fineDegrees: Double = 0
    /// 拉直时拖滑块用的小图（已转好 90°），每动一下只在它上面重算，松手再用原图算一遍
    private var straightenSource: CGImage?
    /// 拉直时叠在照片上的网格，方便对齐地平线
    private let gridLayer = CAShapeLayer()
    private var logicalSize: CGSize = .zero   // 原图（已校正方向、未旋转）像素尺寸
    private var detailRequested = false
    /// 正在显示快速连翻时的低清草图：清晰预览马上就来，这时不按草图的分辨率去要原图
    private var showingDraft = false
    private var spacePeeking = false
    private var animationActive = false
    private var animationStopped = false
    private var mode: Mode = .fit
    private var scale: CGFloat = 1
    private var origin: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.magnificationFilter = .linear
        backdropLayer.isHidden = true
        layer?.addSublayer(backdropLayer)
        layer?.addSublayer(imageLayer)
        imageLayer.isHidden = true
        gridLayer.fillColor = nil
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        gridLayer.lineWidth = 0.5
        gridLayer.isHidden = true
        thirdsLayer.fillColor = nil
        thirdsLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        thirdsLayer.lineWidth = 1
        thirdsLayer.shadowColor = NSColor.black.cgColor
        thirdsLayer.shadowOpacity = 0.5
        thirdsLayer.shadowRadius = 1
        thirdsLayer.shadowOffset = .zero
        gridLayer.addSublayer(thirdsLayer)
        layer?.addSublayer(gridLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)),
                                               name: SettingsWindowController.didChange, object: nil)
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(doubleClick)
    }

    /// 单击（不是双击、不是拖动）：幻灯片放映时用来暂停 / 继续。
    /// 松开鼠标后等过系统的双击间隔还没有第二下才算，免得双击缩放时先暂停了
    var onSingleClick: (() -> Void)?
    private var pendingSingleClick: DispatchWorkItem?
    private var mouseMovedSinceDown = false

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 当前显示内容的原图像素尺寸（含视图旋转）
    var pixelSize: CGSize { image == nil ? .zero : contentSize }

    private var contentSize: CGSize {
        let q = quarterTurns % 2 == 0 ? logicalSize : CGSize(width: logicalSize.height, height: logicalSize.width)
        guard fineDegrees != 0 else { return q }
        let k = Straighten.cropScale(width: q.width, height: q.height, degrees: fineDegrees)
        return CGSize(width: (q.width * k).rounded(.down), height: (q.height * k).rounded(.down))
    }

    /// 有没有转过还没保存（90° 旋转或拉直）
    var hasPendingRotation: Bool { quarterTurns != 0 || fineDegrees != 0 }

    /// 原图按当前的 90° 旋转和拉直角度变成要显示的图
    private func displayed(from src: CGImage) -> CGImage {
        guard fineDegrees != 0 else { return ImageLoader.rotated(src, quarterTurns: quarterTurns) }
        return Straighten.render(src, quarterTurns: quarterTurns, degrees: fineDegrees) ?? ImageLoader.rotated(src, quarterTurns: quarterTurns)
    }

    /// 当前显示图的旋转状态（导出时保持所见即所得）
    var rotationTurns: Int { quarterTurns }

    var displayedScale: CGFloat { scale }
    /// 测试用：图像当前位置
    var debugOrigin: CGPoint { origin }

    /// 诊断用：当前缩放是否等于适应窗口、图片中心偏离视图中心多少点
    var fitDiagnostics: String {
        let c = contentSize
        let center = CGPoint(x: origin.x + c.width * scale / 2, y: origin.y + c.height * scale / 2)
        return String(format: "scale=%.4f fit=%.4f centerOffset=(%.1f,%.1f)", scale, min(fitScale, 4),
                      center.x - bounds.midX, center.y - bounds.midY)
    }

    /// resetToFit 时重置为适应窗口；isNew 标记换了新图（重置旋转角度）。
    /// logicalSize 是原图尺寸，newSrc 可以是它的降采样版本；不传则按 newSrc 本身尺寸。
    /// draft：低清草图，随后会被同一张的清晰图（isNew = false）原位替换
    func set(image newSrc: CGImage?, logicalSize size: CGSize? = nil, resetToFit: Bool, isNew: Bool, draft: Bool = false) {
        stopAnimation()
        showingDraft = draft
        if isNew {
            quarterTurns = 0
            fineDegrees = 0
            straightenSource = nil
            showsStraightenGrid = false
            detailRequested = false
        }
        let displayed = newSrc.flatMap { self.displayed(from: $0) }
        if let newSrc {
            logicalSize = size ?? CGSize(width: newSrc.width, height: newSrc.height)
        }
        baseImage = newSrc
        image = displayed
        // 草图换清晰图时草图没有标记，保留上一次的判断，免得棋盘格闪一下
        if isNew || ImageLoader.isTransparent(newSrc) || newSrc == nil {
            imageIsTransparent = ImageLoader.isTransparent(newSrc)
            updateTransparencyGrid()
        }
        // 换图默认直接切换；打开「翻页渐变」或幻灯片放映时淡入淡出
        let fade: TimeInterval? = isNew ? (pendingFadeDuration ?? (Self.fadeTransition ? 0.25 : nil)) : nil
        if isNew { pendingFadeDuration = nil }
        // 草图换清晰图是同一张照片原位替换：翻页渐变还没走完就让它接着走
        if isNew || newSrc == nil { endFade() }
        let oldContents = imageLayer.contents
        let oldFrame = imageLayer.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = ImageLoader.surface(for: displayed) ?? displayed
        setEDR(imageLayer, ImageLoader.isHDR(displayed))
        CATransaction.commit()
        if let fade, let oldContents, !imageLayer.isHidden {
            crossfade(from: oldContents, frame: oldFrame, duration: fade)
        }
        imageLayer.isHidden = (displayed == nil)
        if isNew || displayed == nil { refreshBackdrop(fade: fade) }
        // 换了新图一律适应窗口并居中；只有预览换原图（isNew = false）时保持当前缩放
        if resetToFit || isNew || mode == .fit || displayed == nil {
            fit()
        } else {
            apply()
        }
    }

    // MARK: - 磨砂底

    /// 照片没铺满窗口时周围露出来的底：纯黑、磨砂玻璃（透出窗口后面的桌面再模糊，系统材质）、照片色磨砂
    enum BackdropStyle: Int { case black, glass, photo }

    /// 设置 › 通用 › 背景：带透明的图（PNG、GIF 等）透明的地方垫棋盘格，看得出哪里是空的。默认开
    static var showsTransparencyGrid: Bool {
        get { UserDefaults.standard.object(forKey: "transparencyGrid") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "transparencyGrid") }
    }

    /// 8 点一格的浅灰棋盘格，按屏幕点固定大小，放大缩小格子都不变（和 Photoshop 一样）
    private static let checkerColor: CGColor = {
        let cell: CGFloat = 8
        let img = NSImage(size: NSSize(width: cell * 2, height: cell * 2), flipped: false) { r in
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).setFill(); r.fill()
            NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
            NSRect(x: cell, y: cell, width: cell, height: cell).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }()

    /// 缩略图用的小一号棋盘格（4 点一格）：格子小，几十点的缩略图里也看得出是透明
    private static let thumbCheckerColor: CGColor = {
        let cell: CGFloat = 4
        let img = NSImage(size: NSSize(width: cell * 2, height: cell * 2), flipped: false) { r in
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).setFill(); r.fill()
            NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
            NSRect(x: cell, y: cell, width: cell, height: cell).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }()

    /// 缩略图垫在下面的底：带透明的图（ImageIO 解出来带 alpha 通道）垫棋盘格，跟大图一样受设置开关管；其余不垫
    static func thumbBackground(for img: CGImage?) -> CGColor? {
        guard showsTransparencyGrid, let img, ImageLoader.hasAlphaChannel(img) else { return nil }
        return thumbCheckerColor
    }

    /// 当前这张是不是带透明（动图的帧单独判断）
    private var imageIsTransparent = false

    private func updateTransparencyGrid() {
        let on = Self.showsTransparencyGrid && imageIsTransparent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.backgroundColor = on ? Self.checkerColor : nil
        CATransaction.commit()
    }

    /// 测试用：现在是否垫着棋盘格
    var debugTransparencyGrid: Bool { imageLayer.backgroundColor != nil }

    @objc private func settingsDidChange(_ n: Notification) {
        if n.userInfo?["what"] as? String == "transparencyGrid" { updateTransparencyGrid() }
    }

    /// 设置 › 通用 › 背景，默认照片色磨砂
    static var backdropStyle: BackdropStyle {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "backdropStyle") != nil, let s = BackdropStyle(rawValue: d.integer(forKey: "backdropStyle")) { return s }
            return .photo
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "backdropStyle") }
    }

    private static let backdropQueue = DispatchQueue(label: "flipic.backdrop", qos: .utility)
    /// 在 sRGB（非线性）里算：压暗的系数就是看起来的亮度比例，不会像线性空间那样一压就灰
    private static let ciContext = CIContext(options: [.cacheIntermediates: false,
                                                       .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// 换图、旋转、改设置时重做底图。只处理一张几十像素的小图，在后台做，不影响翻页
    func refreshBackdrop(fade: TimeInterval? = nil) {
        backdropGeneration += 1
        let gen = backdropGeneration
        if allowsBackdrop, let fixed = backdropOverride {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.contents = fixed
            backdropLayer.isHidden = false
            CATransaction.commit()
            return
        }
        guard allowsBackdrop, Self.backdropStyle == .photo || monoBackdrop, let src = image else {
            backdropLayer.isHidden = true
            backdropLayer.contents = nil
            return
        }
        let mono = monoBackdrop
        Self.backdropQueue.async { [weak self] in
            let blurred = Self.makeBackdrop(src, mono: mono)
            DispatchQueue.main.async {
                guard let self, self.backdropGeneration == gen else { return }
                if let fade, fade > 0, !self.backdropLayer.isHidden {
                    let t = CATransition()
                    t.type = .fade
                    t.duration = fade
                    self.backdropLayer.add(t, forKey: "fade")
                }
                CATransaction.begin()
                CATransaction.setDisableActions(fade == nil)
                self.backdropLayer.contents = blurred
                self.backdropLayer.isHidden = blurred == nil
                CATransaction.commit()
            }
        }
    }

    /// 缩到 64 像素宽，高斯模糊，保留六成五亮度、略加饱和（和 iPhone 上照片模糊做背景的感觉接近）；
    /// mono 时去掉颜色、压暗到两成
    static func makeBackdrop(_ src: CGImage, mono: Bool = false) -> CGImage? {
        let w = 64, h = max(1, Int((CGFloat(src.height) / CGFloat(max(src.width, 1)) * 64).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: small)
        let out = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 2.6)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0, kCIInputSaturationKey: mono ? 0 : 1.1])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: mono ? 0.22 : 0.65, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: mono ? 0.22 : 0.65, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: mono ? 0.22 : 0.65, w: 0),
            ])
            .cropped(to: input.extent)
        return ciContext.createCGImage(out, from: input.extent)
    }

    var debugBackdropVisible: Bool { !backdropLayer.isHidden && backdropLayer.contents != nil }

    // MARK: - 渐变

    /// 旧图单独放一层，按它原来的位置和尺寸淡出，新图按自己的比例淡入。
    /// 不能在同一个图层上换内容做渐变：竖图换横图时旧图会被塞进变宽的框里，人脸被横向拉宽
    private var fadeGhost: CALayer?

    private func crossfade(from oldContents: Any, frame: CGRect, duration: TimeInterval) {
        guard let host = imageLayer.superlayer else { return }
        let ghost = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame = frame
        ghost.contents = oldContents
        ghost.contentsScale = imageLayer.contentsScale
        ghost.magnificationFilter = imageLayer.magnificationFilter
        ghost.minificationFilter = imageLayer.minificationFilter
        if #available(macOS 14, *) { ghost.wantsExtendedDynamicRangeContent = imageLayer.wantsExtendedDynamicRangeContent }
        ghost.opacity = 0
        host.insertSublayer(ghost, above: imageLayer)
        CATransaction.commit()
        fadeGhost = ghost

        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = duration
        out.timingFunction = timing
        ghost.add(out, forKey: "fade")
        let inn = CABasicAnimation(keyPath: "opacity")
        inn.fromValue = 0
        inn.toValue = 1
        inn.duration = duration
        inn.timingFunction = timing
        imageLayer.add(inn, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak ghost] in
            guard let ghost, self?.fadeGhost === ghost else { return }
            self?.endFade()
        }
    }

    /// HDR 照片要让图层申请高光余量，屏幕才会把亮部推到普通白以上
    private func setEDR(_ layer: CALayer, _ on: Bool) {
        if #available(macOS 14, *) { layer.wantsExtendedDynamicRangeContent = on }
    }

    var debugImage: CGImage? { image }
    var debugEDR: Bool {
        if #available(macOS 14, *) { return imageLayer.wantsExtendedDynamicRangeContent }
        return false
    }

    /// 渐变途中又换图（比如幻灯片放映时手动翻页）：直接收掉，不接着淡
    private func endFade() {
        imageLayer.removeAnimation(forKey: "fade")
        fadeGhost?.removeFromSuperlayer()
        fadeGhost = nil
    }

    /// 播放动图：ImageIO 在主队列按每帧时长驱动回调，我们只把帧放到当前图层上
    /// （支持 GIF / APNG；缩放、平移、旋转在播放期间全部可用）。
    /// 注意：调用本身可能阻塞直至动画停止，必须放在后台队列，帧回调仍走主队列
    func startAnimatedPlayback(url: URL) {
        animationActive = true
        animationStopped = false
        var gotFirst = false
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil as CFDictionary?) { [weak self] _, frame, stop in
                guard let self, self.animationActive, !self.animationStopped else {
                    stop.pointee = true
                    return
                }
                let display = self.quarterTurns != 0
                    ? ImageLoader.rotated(frame, quarterTurns: self.quarterTurns)
                    : frame
                self.image = display
                self.imageLayer.contents = display
                let clear = ImageLoader.hasAlphaChannel(frame)
                if clear != self.imageIsTransparent { self.imageIsTransparent = clear; self.updateTransparencyGrid() }
                if !gotFirst {
                    gotFirst = true
                    self.logicalSize = CGSize(width: frame.width, height: frame.height)
                    if self.mode == .fit { self.fit() } else { self.apply() }
                    self.onFirstFrame?(CGSize(width: frame.width, height: frame.height))
                } else {
                    self.apply()
                }
            }
            if status != noErr, self?.animationActive == true {
                DispatchQueue.main.async { [weak self] in
                    self?.animationActive = false
                }
            }
        }
    }

    var isAnimated: Bool { animationActive }

    private func stopAnimation() {
        animationStopped = true
        animationActive = false
    }

    /// 顺时针旋转 turns 个 90°（turns 为负即逆时针），旋转后回到适应窗口
    func rotate(clockwise turns: Int) {
        if animationActive {
            // 播放中的动图：记下角度，下一帧起按新角度渲染
            quarterTurns = ((quarterTurns + turns) % 4 + 4) % 4
            return
        }
        guard baseImage != nil else { return }
        quarterTurns = ((quarterTurns + turns) % 4 + 4) % 4
        if straightenSource != nil, let baseImage { straightenSource = Self.straightenPreview(baseImage, quarterTurns: quarterTurns) }
        image = baseImage.flatMap { displayed(from: $0) }
        imageLayer.contents = image
        refreshBackdrop()
        fit(animate: true)
        onRotate?()
    }

    /// 撤掉没保存的旋转和拉直，回到原图
    func resetRotation() {
        guard hasPendingRotation, !animationActive, let baseImage else { return }
        quarterTurns = 0
        fineDegrees = 0
        straightenSource = nil
        image = displayed(from: baseImage)
        imageLayer.contents = image
        refreshBackdrop()
        fit(animate: true)
        onRotate?()
    }

    // MARK: - 拉直

    var canStraighten: Bool { baseImage != nil && !animationActive }

    /// 进入拉直：显示网格，准备拖滑块用的小图
    func beginStraighten() {
        guard let baseImage, !animationActive else { return }
        straightenSource = Self.straightenPreview(baseImage, quarterTurns: quarterTurns)
        showsStraightenGrid = true
        fit(animate: true)
    }

    /// 拖滑块时：在小图上转 + 裁，画面框保持同样的比例，网格跟着
    func setStraighten(degrees: Double) {
        guard let straightenSource else { return }
        fineDegrees = max(-Straighten.maxDegrees, min(Straighten.maxDegrees, degrees))
        let preview = Straighten.render(straightenSource, degrees: fineDegrees) ?? straightenSource
        image = preview
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = preview
        CATransaction.commit()
        fit()
    }

    /// 结束拉直：degrees 是最终角度（取消就传进来之前的角度），用原图重算一遍
    func endStraighten(degrees: Double) {
        straightenSource = nil
        showsStraightenGrid = false
        fineDegrees = max(-Straighten.maxDegrees, min(Straighten.maxDegrees, degrees))
        guard let baseImage else { return }
        image = displayed(from: baseImage)
        imageLayer.contents = ImageLoader.surface(for: image) ?? image
        refreshBackdrop()
        fit()
        onRotate?()
    }

    private static func straightenPreview(_ src: CGImage, quarterTurns: Int) -> CGImage {
        let rotated = ImageLoader.rotated(src, quarterTurns: quarterTurns)
        let longSide = CGFloat(max(rotated.width, rotated.height))
        let target: CGFloat = 1800
        guard longSide > target else { return rotated }
        let k = target / longSide
        let w = max(1, Int(CGFloat(rotated.width) * k)), h = max(1, Int(CGFloat(rotated.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return rotated }
        ctx.interpolationQuality = .high
        ctx.draw(rotated, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? rotated
    }

    private(set) var showsStraightenGrid = false {
        didSet {
            gridLayer.isHidden = !showsStraightenGrid
            if showsStraightenGrid { layoutGrid() }
        }
    }

    /// 网格：三等分线亮一点，再细分成 9×9 的淡线
    private func layoutGrid() {
        guard showsStraightenGrid else { return }
        let f = imageLayer.frame
        let path = CGMutablePath()
        for i in 1..<9 where i % 3 != 0 {
            let x = f.minX + f.width * CGFloat(i) / 9, y = f.minY + f.height * CGFloat(i) / 9
            path.move(to: CGPoint(x: x, y: f.minY)); path.addLine(to: CGPoint(x: x, y: f.maxY))
            path.move(to: CGPoint(x: f.minX, y: y)); path.addLine(to: CGPoint(x: f.maxX, y: y))
        }
        let thirds = CGMutablePath()
        for i in 1...2 {
            let x = f.minX + f.width * CGFloat(i) / 3, y = f.minY + f.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: f.minY)); thirds.addLine(to: CGPoint(x: x, y: f.maxY))
            thirds.move(to: CGPoint(x: f.minX, y: y)); thirds.addLine(to: CGPoint(x: f.maxX, y: y))
        }
        thirds.addRect(f)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.frame = bounds
        gridLayer.path = path
        thirdsLayer.path = thirds
        CATransaction.commit()
    }
    private let thirdsLayer = CAShapeLayer()

    // MARK: - 缩放

    private var fitScale: CGFloat {
        let c = contentSize
        guard image != nil, c.width > 0, c.height > 0, bounds.width > 1 else { return 1 }
        return min(bounds.width / c.width, bounds.height / c.height)
    }

    func fit(animate: Bool = false) {
        mode = .fit
        scale = min(fitScale, 4)
        centerOrigin()
        apply(animated: animate)
    }

    private func centerOrigin() {
        let c = contentSize
        guard image != nil, c.width > 0 else { return }
        origin = CGPoint(x: (bounds.width - c.width * scale) / 2,
                         y: (bounds.height - c.height * scale) / 2)
    }

    func actualSize() {
        guard image != nil else { return }
        zoom(to: 1, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
    }

    func zoomIn() {
        guard image != nil else { return }
        zoom(to: scale * 1.3, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
    }

    func zoomOut() {
        guard image != nil else { return }
        zoom(to: scale / 1.3, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
    }

    /// 翻页时新旧两张图淡入淡出，默认关
    static var fadeTransition: Bool {
        get { UserDefaults.standard.bool(forKey: "fadeTransition") }
        set { UserDefaults.standard.set(newValue, forKey: "fadeTransition") }
    }

    /// 下一次换图用的渐变时长（幻灯片自己设，和手动翻页的渐变开关分开）；用一次就清掉
    var pendingFadeDuration: TimeInterval?
    var debugFadeDuration: CFTimeInterval { imageLayer.animation(forKey: "fade")?.duration ?? 0 }
    /// 渐变时旧图那一层的尺寸（测试用：应保持旧图自己的比例）
    var debugGhostFrame: CGRect? { fadeGhost?.frame }
    var debugImageFrame: CGRect { imageLayer.frame }
    /// 照片在视图里的位置（翻转坐标，左上原点）
    var imageFrame: CGRect { imageLayer.frame }
    var debugGhostPresentation: Float { fadeGhost?.presentation()?.opacity ?? -1 }
    var debugImagePresentationOpacity: Float { imageLayer.presentation()?.opacity ?? imageLayer.opacity }

    /// 适应窗口 ⇄ 100%，以 point 为中心放大；小图本来就不到窗口大小时放大到 200%
    /// 翻到头时照片朝按键方向挪一点再弹回来（只动照片，背景不动）
    func bounce(direction: Int) {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, CGFloat(-direction) * 26, 0]
        a.keyTimes = [0, 0.35, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        a.duration = 0.28
        a.isAdditive = true
        imageLayer.add(a, forKey: "endBounce")
    }

    /// 当前显示的图（已应用旋转），给人脸检测这类需要读画面的功能用
    var currentImage: CGImage? { image }

    /// 以照片上的某一点（归一化，左上原点）为中心放大到 100%（照片本身比窗口小时放到 200%）
    func zoomActual(centeredOn p: CGPoint, animated: Bool = true) {
        guard image != nil, contentSize.width > 0 else { return }
        let c = contentSize
        mode = .free
        scale = fitScale >= 0.999 ? 2 : 1
        origin = CGPoint(x: bounds.midX - p.x * c.width * scale, y: bounds.midY - p.y * c.height * scale)
        apply(animated: animated)
    }

    func toggleFitActual(at point: CGPoint?) {
        guard image != nil else { return }
        if mode == .fit {
            let target: CGFloat = fitScale >= 0.999 ? 2 : 1
            zoom(to: target, anchor: point ?? CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
        } else {
            fit(animate: true)
        }
    }

    /// 鼠标在图片区域里就返回它的位置，否则 nil（按窗口中心）
    private var mouseInView: CGPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    private var maxScale: CGFloat { 12 }
    private var minScale: CGFloat { min(fitScale, 1) / 8 }

    private func zoom(to target: CGFloat, anchor p: CGPoint, animated: Bool = false, clamping: Bool = true) {
        guard image != nil, contentSize.width > 0 else { return }
        // 捏合过程中放开钳制（回弹手感），其余路径钳制在 [适应窗口/8, 12倍]
        let s = clamping ? min(max(target, minScale), maxScale) : target
        let imgPoint = CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
        mode = .free
        scale = s
        origin = CGPoint(x: p.x - imgPoint.x * s, y: p.y - imgPoint.y * s)
        apply(animated: animated)
    }

    private func apply(animated: Bool = false) {
        let c = contentSize
        guard let image, c.width > 0 else { return }
        let w = c.width * scale
        let h = c.height * scale
        // 拖到照片边缘就停：比窗口大的方向不留黑边，比窗口小的方向居中；捏合过程中放开，松手后再归位
        if mode != .fit && !isPinching {
            origin.x = w <= bounds.width ? (bounds.width - w) / 2 : min(0, max(bounds.width - w, origin.x))
            origin.y = h <= bounds.height ? (bounds.height - h) / 2 : min(0, max(bounds.height - h, origin.y))
        }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        imageLayer.frame = CGRect(origin: origin, size: CGSize(width: w, height: h))
        CATransaction.commit()
        layoutGrid()
        onImageFrameChange?()
        onZoomChange?(scale)
        if !applyingViewState { onViewChange?(viewState, animated) }

        // 图层图片的像素少于屏幕实际要显示的像素、且原图还有更多细节时，请求全分辨率
        if !detailRequested, !animationActive, !showingDraft, CGFloat(image.width) < c.width - 1 {
            let devicePixels = w * (window?.backingScaleFactor ?? 2)
            if CGFloat(image.width) < devicePixels * 0.95 {
                detailRequested = true
                onNeedsDetail?()
            }
        }
    }

    /// 上次布局时的尺寸：放大状态下窗口或格子变大变小，保持画面中心看的还是同一处
    private var lastLayoutSize: CGSize = .zero

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        CATransaction.commit()
        if mode == .fit {
            scale = min(fitScale, 4)
            centerOrigin()
        } else if lastLayoutSize.width > 0 {
            origin.x += (bounds.width - lastLayoutSize.width) / 2
            origin.y += (bounds.height - lastLayoutSize.height) / 2
        }
        lastLayoutSize = bounds.size
        apply()
    }

    // MARK: - 手势

    private var gestureAnchor = CGPoint.zero
    private var isPinching = false
    private var pinchEndTime = Date.distantPast
    private var dragStartOrigin: CGPoint?
    private var dragStartPoint: CGPoint?
    /// 照片适应窗口时按住拖动是移动窗口（不用非得拖顶栏）；放大后才是平移照片。全屏时窗口不能动，照旧平移
    private var windowDragStart: (frame: CGPoint, mouse: CGPoint)?
    /// 测试用：合成的鼠标事件没法让系统拖窗口，测试时还是自己挪
    static var debugManualWindowDrag = false
    /// 适应窗口时拖动照片是否移动窗口；嵌在别的窗口里（工作台）时关掉，适应窗口时拖动什么都不动，放大后照旧平移
    var dragsWindowWhenFit = true

    /// 触控板捏合：magnification 是相对上一事件的增量，(1 + delta) 乘当前缩放即严格跟手
    override func magnify(with event: NSEvent) {
        let phase = event.phase
        if phase == .ended || phase == .cancelled {
            isPinching = false
            pinchEndTime = Date()
            // 松手回弹：把超出限位的缩放平滑拉回
            if scale < minScale {
                zoom(to: minScale, anchor: gestureAnchor, animated: true)
            } else if scale > maxScale {
                zoom(to: maxScale, anchor: gestureAnchor, animated: true)
            } else {
                apply(animated: true)   // 捏合时拖出边缘的部分平滑归位
            }
            return
        }
        if !isPinching {
            isPinching = true
            gestureAnchor = convert(event.locationInWindow, from: nil)
        }
        guard event.magnification != 0 else { return }
        zoom(to: scale * (1 + event.magnification), anchor: gestureAnchor, clamping: false)
    }

    /// 触控板双击轻拍
    override func smartMagnify(with event: NSEvent) {
        toggleFitActual(at: convert(event.locationInWindow, from: nil))
    }

    /// 滚轮翻页（显示菜单里可切换，默认滚轮缩放）
    static var wheelNavigates: Bool {
        get { UserDefaults.standard.bool(forKey: "wheelNavigates") }
        set { UserDefaults.standard.set(newValue, forKey: "wheelNavigates") }
    }
    /// 滚轮缩放方向反转（用 Mos 之类工具改过滚轮方向的用户需要）
    static var wheelZoomInverted: Bool {
        get { UserDefaults.standard.bool(forKey: "wheelZoomInverted") }
        set { UserDefaults.standard.set(newValue, forKey: "wheelZoomInverted") }
    }
    /// 滚轮 / 触控板翻页方向反转：默认手指往下 = 下一张；反转后像刷手机，照片跟着手指走，往下滑回到上一张
    static var wheelNavInverted: Bool {
        get { UserDefaults.standard.bool(forKey: "wheelNavInverted") }
        set { UserDefaults.standard.set(newValue, forKey: "wheelNavInverted") }
    }
    private var wheelAccum: CGFloat = 0
    private var wheelFlippedInGesture = false
    private var lastWheelFlip = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        onActivity?()
        // 捏合进行中忽略夹带的滚动事件；捏合刚结束的短暂惯性也忽略，避免跳变
        if isPinching { return }
        if !event.momentumPhase.isEmpty, Date().timeIntervalSince(pinchEndTime) < 0.35 { return }
        let cmd = event.modifierFlags.contains(.command)
        if !cmd, handleHorizontalSwipe(event) { return }
        if Self.wheelNavigates {
            if cmd {
                zoomByWheel(event)
            } else if mode == .fit {
                flipByWheel(event)
            } else {
                panByWheel(event)   // 放大后滚动用来看图片别处，回到适应窗口再翻页
            }
            return
        }
        // 对齐 Windows 看图器习惯：滚动即缩放（以光标为锚点）；⌘+滚动 = 平移
        if cmd { panByWheel(event) } else { zoomByWheel(event) }
    }

    // MARK: - 触控板左右滑翻页

    /// 一次手势只认一个方向：开头几个点的位移看是横向还是纵向，横向就整次手势都当翻页
    private enum SwipeAxis { case undecided, horizontal, vertical }
    private var swipeAxis = SwipeAxis.vertical
    private var swipeStart = CGSize.zero
    /// 方向还没定时内容往哪边走（scrollingDeltaX 累计，和平移同号）
    private var swipeStartDX: CGFloat = 0
    private var swipeAccum: CGFloat = 0
    private var swipeFlipped = false

    /// 放大着的照片还能不能往这边拖：contentDX 是内容要移动的方向（和平移同号）。
    /// 只剩不到 24 点也算拖到头了：稍微放大一点时左右只多出一小条，不用先拖一下才能翻
    private func canPanHorizontally(_ contentDX: CGFloat) -> Bool {
        let w = contentSize.width * scale
        guard w > bounds.width + 0.5 else { return false }
        let room = contentDX < 0 ? origin.x - (bounds.width - w) : -origin.x
        return room >= 24
    }

    /// 触控板双指左右滑一次翻一张：往左滑下一张、往右滑上一张（跟着手指走）。
    /// 滚动设成缩放（默认）时，横向滑动放大后也没别的用处，照样翻页；
    /// 滚动设成翻页时放大后横向滑动是平移，已经拖到这一边的边上（或左右没超出窗口）再滑一次才翻页，
    /// 只看手势开头，拖着拖着到边不会顺势翻走。鼠标滚轮没有横向，不受影响。处理了就返回 true
    private func handleHorizontalSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began {
            swipeAxis = .undecided
            swipeStart = .zero
            swipeStartDX = 0
            swipeAccum = 0
            swipeFlipped = false
        }
        // 手指离开后的惯性：横向手势的惯性整段吞掉，避免顺带缩放或平移
        if !event.momentumPhase.isEmpty { return swipeAxis == .horizontal }
        switch swipeAxis {
        case .vertical:
            return false
        case .undecided:
            swipeStart.width += abs(event.scrollingDeltaX)
            swipeStart.height += abs(event.scrollingDeltaY)
            swipeStartDX += event.scrollingDeltaX
            // 还没看出方向：「开始」事件照常往下传（上下翻页靠它重置计数），之后的先不动；
            // 放大后滚动是平移的，照常平移，到了边上平移本来就不动
            let pans = mode != .fit && Self.wheelNavigates
            guard max(swipeStart.width, swipeStart.height) >= 6 else { return pans ? false : event.phase != .began }
            swipeAxis = swipeStart.width > swipeStart.height * 1.5 ? .horizontal : .vertical
            if swipeAxis == .horizontal, pans, canPanHorizontally(swipeStartDX) { swipeAxis = .vertical }
            if swipeAxis == .vertical { return false }
            fallthrough
        case .horizontal:
            // 换算成手指方向：自然滚动时 delta 跟着内容走，反过来就是手指方向
            var dx = event.scrollingDeltaX
            if event.isDirectionInvertedFromDevice { dx = -dx }
            guard !swipeFlipped else { return true }
            swipeAccum += dx
            if abs(swipeAccum) >= 40 {
                swipeFlipped = true
                onNavigate?(swipeAccum > 0 ? 1 : -1)
            }
            return true
        }
    }

    /// 和系统滚动视图同向（跟「预览」一样）：开着自然滚动时照片跟着手指走，关掉时反过来；
    /// scrollingDeltaY 为正是内容往下移，视图是翻转坐标，origin.y 加上它就是往下
    private func panByWheel(_ event: NSEvent) {
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        origin.x += event.scrollingDeltaX * k
        origin.y += event.scrollingDeltaY * k
        mode = .free
        apply()
    }

    private func zoomByWheel(_ event: NSEvent) {
        if event.momentumPhase.isEmpty {
            gestureAnchor = convert(event.locationInWindow, from: nil)
        }
        var dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        if Self.wheelZoomInverted { dy = -dy }
        let step: Double = event.hasPreciseScrollingDeltas ? 1.004 : 1.25
        let factor = CGFloat(pow(step, -Double(dy)))
        zoom(to: scale * factor, anchor: gestureAnchor)
    }

    /// 滚轮往下（手指方向，不受「自然滚动」设置影响）= 下一张；触控板一次滑动只翻一张
    private func flipByWheel(_ event: NSEvent) {
        if !event.momentumPhase.isEmpty { return }          // 惯性滚动不翻页
        if event.phase == .began { wheelAccum = 0; wheelFlippedInGesture = false }
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        if Self.wheelNavInverted { dy = -dy }
        guard dy != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            // 触控板 / 妙控鼠标：同一次滑动累计够距离翻一张，手指抬起前不再翻
            guard !wheelFlippedInGesture else { return }
            wheelAccum += dy
            guard abs(wheelAccum) >= 30 else { return }
            dy = wheelAccum
            wheelFlippedInGesture = true
        } else {
            // 滚轮一格一张；无极滚轮甩快了也限速，避免一下飞过几十张
            guard Date().timeIntervalSince(lastWheelFlip) > 0.06 else { return }
        }
        lastWheelFlip = Date()
        onNavigate?(dy < 0 ? 1 : -1)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        mouseMovedSinceDown = false
        if event.clickCount >= 2 { pendingSingleClick?.cancel(); pendingSingleClick = nil }
        dragStartOrigin = origin
        dragStartPoint = convert(event.locationInWindow, from: nil)
        if dragsWindowWhenFit, mode == .fit, let w = window, !w.styleMask.contains(.fullScreen) {
            windowDragStart = (w.frame.origin, w.convertPoint(toScreen: event.locationInWindow))
        } else {
            windowDragStart = nil
            if !dragsWindowWhenFit, mode == .fit { dragStartOrigin = nil }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = windowDragStart, let w = window {
            let m = w.convertPoint(toScreen: event.locationInWindow)
            if hypot(m.x - start.mouse.x, m.y - start.mouse.y) > 3 { mouseMovedSinceDown = true }
            guard mouseMovedSinceDown else { return }
            // 动过 3 点以后交给系统拖窗口，和拖标题栏一样顺，也能拖到屏幕边上分屏。
            // 原来每次自己 setFrameOrigin：事件里的窗口内坐标按事件发生时的窗口位置算，窗口已经挪过了再换算到屏幕会来回偏，窗口跟着抖
            if Self.debugManualWindowDrag {
                w.setFrameOrigin(CGPoint(x: start.frame.x + m.x - start.mouse.x, y: start.frame.y + m.y - start.mouse.y))
                return
            }
            windowDragStart = nil
            dragStartOrigin = nil
            w.performDrag(with: event)
            return
        }
        guard let o = dragStartOrigin, let s = dragStartPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - s.x, p.y - s.y) > 3 { mouseMovedSinceDown = true }
        origin = CGPoint(x: o.x + (p.x - s.x), y: o.y + (p.y - s.y))
        mode = .free
        onActivity?()
        apply()
    }

    override func mouseUp(with event: NSEvent) {
        windowDragStart = nil
        dragStartOrigin = nil
        dragStartPoint = nil
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
        if event.clickCount == 1, !mouseMovedSinceDown, onSingleClick != nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingSingleClick = nil
                self?.onSingleClick?()
            }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    /// 双击处是不是留给别的用途（实况文本里双击文字是选中词），是就不缩放
    var ignoresDoubleClick: ((CGPoint) -> Bool)?

    @objc private func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
        let p = recognizer.location(in: self)
        if ignoresDoubleClick?(p) == true { return }
        toggleFitActual(at: p)
    }

    // MARK: - 并排对比同步

    /// 缩放用「相对适应窗口的倍数」，位置用照片上归一化的中心点，分辨率不同的连拍也能对到同一处
    struct ViewState: Equatable {
        var fit: Bool
        var zoom: CGFloat
        var center: CGPoint
    }

    private var applyingViewState = false

    var viewState: ViewState {
        let c = contentSize
        guard image != nil, c.width > 0, scale > 0 else { return ViewState(fit: true, zoom: 1, center: CGPoint(x: 0.5, y: 0.5)) }
        return ViewState(fit: mode == .fit, zoom: scale / fitScale,
                         center: CGPoint(x: (bounds.midX - origin.x) / (c.width * scale),
                                         y: (bounds.midY - origin.y) / (c.height * scale)))
    }

    /// 测试用：模拟拖动
    func debugPan(dx: CGFloat, dy: CGFloat) {
        origin.x += dx
        origin.y += dy
        mode = .free
        apply()
    }

    /// 照搬别的格子的缩放和位置，不再回传
    func applyViewState(_ s: ViewState, animated: Bool = false) {
        guard image != nil, contentSize.width > 0 else { return }
        applyingViewState = true
        defer { applyingViewState = false }
        if s.fit {
            fit(animate: animated)
            return
        }
        let c = contentSize
        mode = .free
        scale = min(max(fitScale * s.zoom, minScale), maxScale)
        origin = CGPoint(x: bounds.midX - s.center.x * c.width * scale,
                         y: bounds.midY - s.center.y * c.height * scale)
        apply(animated: animated)
    }

    // MARK: - 视频画面

    private var overlayLayer: CALayer?

    /// 视频画面放进照片图层里，跟着照片一起缩放、平移；传 nil 拿掉
    func setOverlayLayer(_ l: CALayer?) {
        overlayLayer?.removeFromSuperlayer()
        overlayLayer = l
        guard let l else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.frame = imageLayer.bounds
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.addSublayer(l)
        CATransaction.commit()
    }

    /// 键盘事件先给上层看一眼（看视频时回车播放、⇧← ⇧→ 快退快进），处理了就不再往下走
    var onKeyIntercept: ((NSEvent) -> Bool)?

    // MARK: - 键盘

    var isPeeking: Bool { spacePeeking }
    var isFit: Bool { mode == .fit }
    var debugHasImage: Bool { image != nil }
    var debugContentsAnimating: Bool { imageLayer.animation(forKey: "fade") != nil }
    func debugToggle(at p: CGPoint) { toggleFitActual(at: p) }
    func debugImagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }

    /// 打开照片时直接进入贴合预览（和按空格一样，再按空格或 Esc 退出）
    func enterPeek() {
        guard !spacePeeking else { return }
        spacePeeking = onPeekBegin?() ?? false
    }

    /// Esc、进入全屏等需要先退出预览时由上层调用
    func endPeek() {
        if spacePeeking {
            spacePeeking = false
            onPeekEnd?()
        }
    }

    /// 按住放大键：按下时从适应窗口放大的那次，记下键码和时间
    private var heldZoomKey: (code: UInt16, at: CFTimeInterval)?
    /// 按住超过这么久才算「按住看一眼」，松手还原；短按照旧是切换
    static let springHoldSeconds: CFTimeInterval = 0.3

    override func keyUp(with event: NSEvent) {
        if let held = heldZoomKey, held.code == event.keyCode {
            heldZoomKey = nil
            if CACurrentMediaTime() - held.at >= Self.springHoldSeconds, mode != .fit {
                // 按住时可以拖着看别处；拖到一半松开 0，这次拖动作废，不然鼠标再动会把还原后的整张图拖走
                dragStartOrigin = nil
                dragStartPoint = nil
                fit(animate: true)
            }
            return
        }
        super.keyUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onActivity?()
        if onKeyIntercept?(event) == true { return }
        if let action = Shortcuts.action(for: event) {
            perform(action, event)
            return
        }
        // 固定按键：= / - 同 ↑ / ↓ 缩放，Esc 逐级退出
        switch event.charactersIgnoringModifiers ?? "" {
        case "=", "+": zoomIn()
        case "-", "_": zoomOut()
        case "\u{1B}": onEscape?()
        default: super.keyDown(with: event)
        }
    }

    private func perform(_ action: ShortcutAction, _ event: NSEvent) {
        switch action {
        case .prev: onNavigate?(-1)
        case .next: onNavigate?(1)
        case .first: onFirst?()
        case .last: onLast?()
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .zoomAtPointer:
            // 同 Lyn：在鼠标处放大到 100%，再按恢复。按住不放时系统会连发，只认第一次按下；
            // 按住超过一会儿再松开算「看一眼」，松手就回到适应窗口（弹簧式，见 keyUp）
            guard !event.isARepeat else { return }
            let zoomingIn = mode == .fit
            toggleFitActual(at: mouseInView)
            heldZoomKey = zoomingIn ? (event.keyCode, CACurrentMediaTime()) : nil
        case .actualSize: actualSize()
        case .peek:
            // 按住不放时系统会连发重复事件，只认第一次按下
            guard !event.isARepeat else { return }
            if spacePeeking {
                endPeek()
            } else {
                spacePeeking = onPeekBegin?() ?? false
            }
        case .fullscreen: onToggleFullscreen?()
        case .info: onToggleInfo?()
        case .filmstrip: onToggleFilmstrip?()
        case .slideshow: onSlideshow?()
        case .rotateCW: rotate(clockwise: 1)
        case .rotateCCW: rotate(clockwise: -1)
        case .rename: onRename?()
        case .trash: onTrash?()
        default: onCommand?(action)
        }
    }
}

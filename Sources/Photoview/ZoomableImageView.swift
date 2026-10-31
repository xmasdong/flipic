import AppKit
import QuartzCore

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

    private enum Mode { case fit, free }

    private let imageLayer = CALayer()
    private var image: CGImage?          // 当前显示（已应用旋转）的图
    private var baseImage: CGImage?      // 未旋转原图
    private var quarterTurns = 0
    private var logicalSize: CGSize = .zero   // 原图（已校正方向、未旋转）像素尺寸
    private var detailRequested = false
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
        layer?.addSublayer(imageLayer)
        imageLayer.isHidden = true
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 当前显示内容的原图像素尺寸（含视图旋转）
    var pixelSize: CGSize { image == nil ? .zero : contentSize }

    private var contentSize: CGSize {
        quarterTurns % 2 == 0 ? logicalSize : CGSize(width: logicalSize.height, height: logicalSize.width)
    }

    /// 当前显示图的旋转状态（导出时保持所见即所得）
    var rotationTurns: Int { quarterTurns }

    var displayedScale: CGFloat { scale }

    /// 诊断用：当前缩放是否等于适应窗口、图片中心偏离视图中心多少点
    var fitDiagnostics: String {
        let c = contentSize
        let center = CGPoint(x: origin.x + c.width * scale / 2, y: origin.y + c.height * scale / 2)
        return String(format: "scale=%.4f fit=%.4f centerOffset=(%.1f,%.1f)", scale, min(fitScale, 4),
                      center.x - bounds.midX, center.y - bounds.midY)
    }

    /// resetToFit 时重置为适应窗口；isNew 标记换了新图（重置旋转角度）。
    /// logicalSize 是原图尺寸，newSrc 可以是它的降采样版本；不传则按 newSrc 本身尺寸
    func set(image newSrc: CGImage?, logicalSize size: CGSize? = nil, resetToFit: Bool, isNew: Bool) {
        stopAnimation()
        if isNew {
            quarterTurns = 0
            detailRequested = false
        }
        let displayed = newSrc.flatMap { ImageLoader.rotated($0, quarterTurns: quarterTurns) }
        if let newSrc {
            logicalSize = size ?? CGSize(width: newSrc.width, height: newSrc.height)
        }
        baseImage = newSrc
        image = displayed
        // 换图默认直接切换；只有在「显示 › 翻页渐变」打开时才保留图层自带的淡入淡出
        CATransaction.begin()
        CATransaction.setDisableActions(!(Self.fadeTransition && isNew))
        imageLayer.contents = ImageLoader.surface(for: displayed) ?? displayed
        CATransaction.commit()
        imageLayer.isHidden = (displayed == nil)
        // 换了新图一律适应窗口并居中；只有预览换原图（isNew = false）时保持当前缩放
        if resetToFit || isNew || mode == .fit || displayed == nil {
            fit()
        } else {
            apply()
        }
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
        image = baseImage.flatMap { ImageLoader.rotated($0, quarterTurns: quarterTurns) }
        imageLayer.contents = image
        fit(animate: true)
    }

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

    /// 适应窗口 ⇄ 100%，以 point 为中心放大；小图本来就不到窗口大小时放大到 200%
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
        // 自由拖动：不做边缘钳制，可把图片任意角落拖到窗口中央；Esc / 0 / 双击复位
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        imageLayer.frame = CGRect(origin: origin, size: CGSize(width: w, height: h))
        CATransaction.commit()
        onZoomChange?(scale)

        // 图层图片的像素少于屏幕实际要显示的像素、且原图还有更多细节时，请求全分辨率
        if !detailRequested, !animationActive, CGFloat(image.width) < c.width - 1 {
            let devicePixels = w * (window?.backingScaleFactor ?? 2)
            if CGFloat(image.width) < devicePixels * 0.95 {
                detailRequested = true
                onNeedsDetail?()
            }
        }
    }

    override func layout() {
        super.layout()
        if mode == .fit {
            scale = min(fitScale, 4)
            centerOrigin()
        }
        apply()
    }

    // MARK: - 手势

    private var gestureAnchor = CGPoint.zero
    private var isPinching = false
    private var pinchEndTime = Date.distantPast
    private var dragStartOrigin: CGPoint?
    private var dragStartPoint: CGPoint?

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
    private var wheelAccum: CGFloat = 0
    private var wheelFlippedInGesture = false
    private var lastWheelFlip = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        onActivity?()
        // 捏合进行中忽略夹带的滚动事件；捏合刚结束的短暂惯性也忽略，避免跳变
        if isPinching { return }
        if !event.momentumPhase.isEmpty, Date().timeIntervalSince(pinchEndTime) < 0.35 { return }
        let cmd = event.modifierFlags.contains(.command)
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

    private func panByWheel(_ event: NSEvent) {
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        origin.x -= event.scrollingDeltaX * k
        origin.y -= event.scrollingDeltaY * k
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
        dragStartOrigin = origin
        dragStartPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let o = dragStartOrigin, let s = dragStartPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        origin = CGPoint(x: o.x + (p.x - s.x), y: o.y + (p.y - s.y))
        mode = .free
        onActivity?()
        apply()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartOrigin = nil
        dragStartPoint = nil
    }

    @objc private func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
        toggleFitActual(at: recognizer.location(in: self))
    }

    // MARK: - 键盘

    var isPeeking: Bool { spacePeeking }
    var isFit: Bool { mode == .fit }
    var debugHasImage: Bool { image != nil }
    var debugContentsAnimating: Bool { imageLayer.animation(forKey: "contents") != nil }
    func debugToggle(at p: CGPoint) { toggleFitActual(at: p) }
    func debugImagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }

    /// Esc、进入全屏等需要先退出预览时由上层调用
    func endPeek() {
        if spacePeeking {
            spacePeeking = false
            onPeekEnd?()
        }
    }

    override func keyDown(with event: NSEvent) {
        onActivity?()
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
        case .zoomAtPointer: toggleFitActual(at: mouseInView)   // 同 Lyn：在鼠标处放大到 100%，再按恢复
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

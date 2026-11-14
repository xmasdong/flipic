import AppKit
import QuartzCore

/// 裁剪与拉直时盖在照片上的一层：框外压暗，框上画三分线和八个手柄，处理拖动和光标。
/// 只管画和拖，框能不能出照片交给 CropGeometry；框变了通过 onChange 告诉看图视图
final class CropOverlayView: NSView {
    /// 转好 90° 的照片尺寸（原图像素）和拉直角度
    var imageSize: CGSize = .zero
    var degrees: Double = 0
    /// 每个原图像素多少屏幕点，以及照片中心在这个视图里的位置
    var scale: CGFloat = 1
    var imageCenter: CGPoint = .zero
    /// 选了固定比例时拖手柄保持它；自由比例时为 nil（按住 ⇧ 保持当前比例）
    var lockedAspect: CGFloat?
    var crop = CropGeometry.Crop(center: .zero, size: .zero)
    /// 调角度时显示细网格，方便对齐地平线
    var showsFineGrid = false { didSet { fineLayer.isHidden = !showsFineGrid } }

    var onChange: ((CropGeometry.Crop) -> Void)?
    var onApply: (() -> Void)?

    private let dimLayer = CAShapeLayer()
    private let fineLayer = CAShapeLayer()
    private let thirdsLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.6).cgColor
        fineLayer.fillColor = nil
        fineLayer.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        fineLayer.lineWidth = 0.5
        fineLayer.isHidden = true
        thirdsLayer.fillColor = nil
        thirdsLayer.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        thirdsLayer.lineWidth = 1
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.lineWidth = 1
        handleLayer.fillColor = NSColor.white.cgColor
        for l in [thirdsLayer, borderLayer, handleLayer] {
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.5
            l.shadowRadius = 1
            l.shadowOffset = .zero
        }
        for l in [dimLayer, fineLayer, thirdsLayer, borderLayer, handleLayer] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 坐标

    /// 裁剪框在这个视图里的位置，对到整点上（1 点的线在普通屏和 Retina 屏上都不发虚）
    var cropFrame: CGRect {
        let r = crop.rect
        let x0 = (imageCenter.x + r.minX * scale).rounded(), y0 = (imageCenter.y + r.minY * scale).rounded()
        let x1 = (imageCenter.x + r.maxX * scale).rounded(), y1 = (imageCenter.y + r.maxY * scale).rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageCenter.x) / scale, y: (p.y - imageCenter.y) / scale)
    }

    /// 框最小拖到多大：屏幕上 30 点，免得手柄叠在一起抓不住
    private var minSide: CGFloat { max(8, 30 / max(scale, 0.0001)) }

    // MARK: - 画

    /// 框、角度或者视图大小变了以后重画
    func refresh() {
        let f = cropFrame
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(f)

        let fine = CGMutablePath(), thirds = CGMutablePath()
        for i in 1..<9 {
            let x = (f.minX + f.width * CGFloat(i) / 9).rounded() + 0.5, y = (f.minY + f.height * CGFloat(i) / 9).rounded() + 0.5
            let path = i % 3 == 0 ? thirds : fine
            path.move(to: CGPoint(x: x, y: f.minY)); path.addLine(to: CGPoint(x: x, y: f.maxY))
            path.move(to: CGPoint(x: f.minX, y: y)); path.addLine(to: CGPoint(x: f.maxX, y: y))
        }

        // 手柄：四角是 L 形，四边中间一小段，都压在框线外侧
        let handles = CGMutablePath()
        let t: CGFloat = 3, arm = min(20, max(8, min(f.width, f.height) / 3))
        let o = f.insetBy(dx: -t, dy: -t)
        for (cx, sx) in [(o.minX, CGFloat(1)), (o.maxX, CGFloat(-1))] {
            for (cy, sy) in [(o.minY, CGFloat(1)), (o.maxY, CGFloat(-1))] {
                handles.addRect(CGRect(x: min(cx, cx + sx * arm), y: min(cy, cy + sy * t), width: arm, height: t))
                handles.addRect(CGRect(x: min(cx, cx + sx * t), y: min(cy, cy + sy * arm), width: t, height: arm))
            }
        }
        if f.width >= arm * 4 {
            handles.addRect(CGRect(x: f.midX - arm / 2, y: o.minY, width: arm, height: t))
            handles.addRect(CGRect(x: f.midX - arm / 2, y: f.maxY, width: arm, height: t))
        }
        if f.height >= arm * 4 {
            handles.addRect(CGRect(x: o.minX, y: f.midY - arm / 2, width: t, height: arm))
            handles.addRect(CGRect(x: f.maxX, y: f.midY - arm / 2, width: t, height: arm))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [dimLayer, fineLayer, thirdsLayer, borderLayer, handleLayer] { l.frame = bounds }
        dimLayer.path = dim
        fineLayer.path = fine
        thirdsLayer.path = thirds
        borderLayer.path = CGPath(rect: f.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        handleLayer.path = handles
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    // MARK: - 拖动

    private enum Grab { case handle(CropGeometry.Handle), move }
    private var grab: Grab?
    private var startCrop = CropGeometry.Crop(center: .zero, size: .zero)
    private var startPoint = CGPoint.zero
    /// 按下的位置离手柄本身差多少：拖的时候手柄不跳到鼠标正下方
    private var grabOffset = CGSize.zero
    var isDragging: Bool { grab != nil }

    /// 手柄好抓的范围：角上 ±12 点，边上沿整条边 ±7 点
    private func handleRects() -> [(CropGeometry.Handle, CGRect)] {
        let f = cropFrame
        let c: CGFloat = min(12, max(6, min(f.width, f.height) / 4)), e: CGFloat = min(7, c)
        return [
            (.topLeft, CGRect(x: f.minX - c, y: f.minY - c, width: 2 * c, height: 2 * c)),
            (.topRight, CGRect(x: f.maxX - c, y: f.minY - c, width: 2 * c, height: 2 * c)),
            (.bottomLeft, CGRect(x: f.minX - c, y: f.maxY - c, width: 2 * c, height: 2 * c)),
            (.bottomRight, CGRect(x: f.maxX - c, y: f.maxY - c, width: 2 * c, height: 2 * c)),
            (.top, CGRect(x: f.minX + c, y: f.minY - e, width: max(0, f.width - 2 * c), height: 2 * e)),
            (.bottom, CGRect(x: f.minX + c, y: f.maxY - e, width: max(0, f.width - 2 * c), height: 2 * e)),
            (.left, CGRect(x: f.minX - e, y: f.minY + c, width: 2 * e, height: max(0, f.height - 2 * c))),
            (.right, CGRect(x: f.maxX - e, y: f.minY + c, width: 2 * e, height: max(0, f.height - 2 * c))),
        ]
    }

    private func hit(_ p: CGPoint) -> Grab? {
        for (h, r) in handleRects() where r.contains(p) { return .handle(h) }
        return cropFrame.contains(p) ? .move : nil
    }

    @discardableResult
    func beginDrag(at p: CGPoint) -> Bool {
        guard let g = hit(p) else { return false }
        grab = g
        startCrop = crop
        startPoint = p
        if case .handle(let h) = g {
            let hp = h.point(on: cropFrame)
            grabOffset = CGSize(width: p.x - hp.x, height: p.y - hp.y)
        }
        return true
    }

    func continueDrag(to p: CGPoint, keepAspect: Bool) {
        guard let grab else { return }
        let next: CropGeometry.Crop
        switch grab {
        case .move:
            let c = CGPoint(x: startCrop.center.x + (p.x - startPoint.x) / scale, y: startCrop.center.y + (p.y - startPoint.y) / scale)
            next = CropGeometry.moved(startCrop, to: c, image: imageSize, degrees: degrees)
        case .handle(let h):
            let target = imagePoint(CGPoint(x: p.x - grabOffset.width, y: p.y - grabOffset.height))
            next = CropGeometry.resized(startCrop, handle: h, to: target, aspect: lockedAspect ?? (keepAspect ? startCrop.aspect : nil),
                                        image: imageSize, degrees: degrees, minSide: min(minSide, startCrop.size.width, startCrop.size.height))
        }
        guard next != crop else { return }
        crop = next
        refresh()
        onChange?(next)
    }

    func endDrag() {
        grab = nil
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, cropFrame.contains(p) {
            grab = nil
            onApply?()
            return
        }
        if beginDrag(at: p), case .move? = grab { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(to: convert(event.locationInWindow, from: nil), keepAspect: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    /// 点在照片上不是为了拖窗口
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - 光标

    static func cursor(for h: CropGeometry.Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition
            switch h {
            case .topLeft: pos = .topLeft
            case .top: pos = .top
            case .topRight: pos = .topRight
            case .right: pos = .right
            case .bottomRight: pos = .bottomRight
            case .bottom: pos = .bottom
            case .bottomLeft: pos = .bottomLeft
            case .left: pos = .left
            }
            return NSCursor.frameResize(position: pos, directions: .all)
        }
        // 老系统没有公开的斜向光标：边上用左右 / 上下，角上用十字
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    override func resetCursorRects() {
        guard crop.size.width > 0 else { return }
        // 各块互不重叠：框里面（让开边上那一圈）是手形，边和角是各自方向的箭头
        let inner = cropFrame.insetBy(dx: 7, dy: 7)
        if inner.width > 0, inner.height > 0 { addCursorRect(inner, cursor: .openHand) }
        for (h, r) in handleRects() where !r.isEmpty { addCursorRect(r, cursor: Self.cursor(for: h)) }
    }

    /// 测试用：某个手柄在视图里的位置
    func debugHandlePoint(_ h: CropGeometry.Handle) -> CGPoint { h.point(on: cropFrame) }
    var debugLayers: String {
        "dim=\(dimLayer.path != nil ? 1 : 0) thirds=\(thirdsLayer.path != nil ? 1 : 0) handles=\(handleLayer.path != nil ? 1 : 0) fine=\(fineLayer.isHidden ? 0 : 1)"
    }
}

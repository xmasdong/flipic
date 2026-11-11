import AppKit

/// 底部横向缩略图胶片条
final class FilmstripView: NSScrollView {
    let collectionView = FilmstripCollectionView()
    /// 常驻的细滚动条：系统的浮动滚动条不动就藏起来，看不出这一张在文件夹里大概的位置
    private let scrollBar = FilmstripScrollBar()

    /// 缩略图大小（点），设置里可选；格子是正方形，缩略图栏高度 = 格子 + 上下各 6
    static let thumbSizes: [CGFloat] = [48, 64, 96, 128]
    static var thumbSize: CGFloat {
        get {
            let v = CGFloat(UserDefaults.standard.double(forKey: "thumbSize"))
            return thumbSizes.contains(v) ? v : 64
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "thumbSize") }
    }
    static var stripHeight: CGFloat { thumbSize + 12 }
    /// 解码缩略图用的像素尺寸：Retina 两倍，最少 128
    static var thumbPixel: CGFloat { max(128, thumbSize * 2) }

    func applyThumbSize() {
        (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize =
            NSSize(width: Self.thumbSize, height: Self.thumbSize)
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    init() {
        super.init(frame: .zero)

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: Self.thumbSize, height: Self.thumbSize)
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        // ⇧ / ⌘ 点击多选；点击和拖动都由 FilmstripCollectionView 自己处理
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]

        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        documentView = collectionView

        scrollBar.scrollView = self
        addSubview(scrollBar)
        contentView.postsBoundsChangedNotifications = true
        collectionView.postsFrameChangedNotifications = true
        for (name, obj) in [(NSView.boundsDidChangeNotification, contentView as NSView),
                            (NSView.frameDidChangeNotification, collectionView as NSView)] {
            NotificationCenter.default.addObserver(forName: name, object: obj, queue: .main) { [weak self] _ in
                self?.scrollBar.needsDisplay = true
            }
        }
    }

    /// 滚动条放在缩略图下面留的那 6 点里，不压在缩略图上
    override func tile() {
        super.tile()
        scrollBar.frame = NSRect(x: 10, y: isFlipped ? bounds.height - 6 : 0, width: max(bounds.width - 20, 0), height: 6)
        scrollBar.needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func scrollTo(index: Int) {
        // 空文件夹时没有任何格子，滚到 (0,0) 会抛异常崩溃
        guard index >= 0, index < collectionView.numberOfItems(inSection: 0) else { return }
        collectionView.scrollToItems(at: Set([IndexPath(item: index, section: 0)]),
                                     scrollPosition: .centeredHorizontally)
    }
}

/// 缩略图栏的点击由看图界面决定选哪几张（⇧ 选一段、⌘ 加减一张），不走系统的选择逻辑；
/// 按住选中的照片拖出去，就是把这几个文件拖到访达、修图软件或聊天窗口
final class FilmstripCollectionView: NSCollectionView {
    /// 点了第几张、按着哪些修饰键
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    /// 拖出去的文件：按下的那张在多选里就拖整组，否则只拖它
    var dragURLs: ((Int) -> [URL])?
    /// 点在空白处：多选收回到只选当前这一张
    var onBlankClick: (() -> Void)?

    private var downEvent: NSEvent?
    private var downIndex: Int?
    /// 按在已经多选的照片上：松手时没拖动才改成只选这一张，拖动就带走整组
    private var deferredClick = false
    private let dragSource = FileDragSource()

    override func mouseDown(with event: NSEvent) {
        downEvent = nil
        // 空白处不框选，只把多选收回来
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { onBlankClick?(); return }
        let mods = event.modifierFlags.intersection([.shift, .command, .control])
        downEvent = event
        downIndex = ip.item
        deferredClick = mods.isEmpty && selectionIndexPaths.count > 1 && selectionIndexPaths.contains(ip)
        if !deferredClick { onClick?(ip.item, mods) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let i = downIndex else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4, let urls = dragURLs?(i), !urls.isEmpty else { return }
        downEvent = nil
        deferredClick = false
        let origin = item(at: IndexPath(item: i, section: 0))?.view.frame ?? NSRect(origin: convert(a, from: nil), size: .zero)
        let items: [NSDraggingItem] = urls.enumerated().map { n, url in
            let d = NSDraggingItem(pasteboardWriter: url as NSURL)
            // 叠成一摞：按下的那张在最上面，其余稍微错开
            let frame = origin.offsetBy(dx: CGFloat(min(n, 3)) * 4, dy: CGFloat(min(n, 3)) * -4)
            let thumb = (item(at: IndexPath(item: i, section: 0)) as? FilmstripItem)?.thumbnailImage
            d.setDraggingFrame(frame, contents: n == 0 ? thumb : nil)
            return d
        }
        beginDraggingSession(with: items, event: down, source: dragSource)
    }

    override func mouseUp(with event: NSEvent) {
        if deferredClick, let i = downIndex { onClick?(i, []) }
        deferredClick = false
        downEvent = nil
    }
}

private final class FileDragSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

final class FilmstripItem: NSCollectionViewItem {
    private let holder = NSView()
    /// 选中框里面再描一圈细的深色边：白底照片上靠外圈的强调色，深色照片上靠这圈深色和外圈分开
    private let innerRing = NSView()
    /// SDK 未提供 NSCollectionViewItem.indexPath，手动记录
    var itemIndex: Int = -1

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor

        holder.frame = v.bounds
        holder.autoresizingMask = [.width, .height]
        holder.wantsLayer = true
        holder.layer?.contentsGravity = CALayerContentsGravity.resizeAspectFill
        holder.layer?.contentsScale = 2
        v.addSubview(holder)

        innerRing.frame = v.bounds.insetBy(dx: 3, dy: 3)
        innerRing.autoresizingMask = [.width, .height]
        innerRing.wantsLayer = true
        innerRing.layer?.cornerRadius = 3.5
        innerRing.layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        innerRing.isHidden = true
        v.addSubview(innerRing)

        view = v
    }

    func setThumbnail(_ image: CGImage?) {
        holder.layer?.contents = image
        holder.layer?.backgroundColor = ZoomableImageView.thumbBackground(for: image)
    }

    /// 测试用：这一格是否垫着棋盘格
    var debugChecker: Bool { holder.layer?.backgroundColor != nil }

    /// 拖动时跟着鼠标走的小图
    var thumbnailImage: NSImage? {
        guard let c = holder.layer?.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID else { return nil }
        return NSImage(cgImage: c as! CGImage, size: view.bounds.size)
    }

    /// 右上角的绿色勾：这张标记过
    private lazy var markIcon: NSImageView = {
        let iv = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold)) ?? NSImage())
        iv.contentTintColor = ViewerViewController.markColor
        iv.wantsLayer = true
        iv.layer?.shadowOpacity = 0.6
        iv.layer?.shadowRadius = 2
        iv.layer?.shadowOffset = .zero
        iv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            iv.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
        ])
        return iv
    }()

    /// 没标记过的格子不创建勾的视图
    private var hasMarkIcon = false

    /// 视频格子右下角的时长；照片的格子不创建
    private lazy var durationLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        l.textColor = .white
        l.wantsLayer = true
        l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        l.layer?.cornerRadius = 3
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),
            l.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
        ])
        return l
    }()
    private var hasDuration = false

    func setDuration(_ seconds: Double?) {
        guard seconds != nil || hasDuration else { return }
        hasDuration = true
        durationLabel.isHidden = seconds == nil
        if let seconds { durationLabel.stringValue = " " + Video.timeText(seconds) + " " }
    }

    func setMarked(_ on: Bool) {
        guard on || hasMarkIcon else { return }
        hasMarkIcon = true
        markIcon.isHidden = !on
    }

    override var isSelected: Bool {
        didSet {
            // 只用白框的话，白底照片（产品、证件照）上几乎看不见选中的是哪张
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            innerRing.layer?.borderWidth = 1
            innerRing.isHidden = !isSelected
            view.alphaValue = isSelected ? 1 : 0.62
        }
    }
}

/// 缩略图栏底部的滚动条：一直显示，拖动滑块或点在空处都能滚；照片少、一屏放得下时不画
final class FilmstripScrollBar: NSView {
    weak var scrollView: NSScrollView?
    private var dragStart: (mouse: CGFloat, offset: CGFloat)?
    private var hovering = false

    private struct Metrics {
        let knob: NSRect
        let maxOffset: CGFloat
        let travel: CGFloat
    }

    private var metrics: Metrics? {
        guard let sv = scrollView, let doc = sv.documentView, bounds.width > 0 else { return nil }
        let visible = sv.contentView.bounds.width
        let total = doc.frame.width
        guard total > visible + 1 else { return nil }
        let w = max(bounds.width * visible / total, 28)
        let maxOffset = total - visible
        let travel = bounds.width - w
        let x = travel * min(max(sv.contentView.bounds.minX / maxOffset, 0), 1)
        return Metrics(knob: NSRect(x: x, y: (bounds.height - 4) / 2, width: w, height: 4),
                       maxOffset: maxOffset, travel: travel)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = metrics else { return }
        let active = hovering || dragStart != nil
        NSColor.labelColor.withAlphaComponent(active ? 0.6 : 0.4).setFill()
        NSBezierPath(roundedRect: m.knob, xRadius: 2, yRadius: 2).fill()
    }

    private func scroll(to offset: CGFloat) {
        guard let sv = scrollView, let m = metrics else { return }
        let x = min(max(offset, 0), m.maxOffset)
        sv.contentView.scroll(to: NSPoint(x: x, y: sv.contentView.bounds.minY))
        sv.reflectScrolledClipView(sv.contentView)
    }

    override func mouseDown(with event: NSEvent) {
        guard let sv = scrollView, var m = metrics else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 点在空处：滑块中心移到点的位置，接着可以拖
        if !m.knob.insetBy(dx: 0, dy: -3).contains(p), m.travel > 0 {
            scroll(to: (p.x - m.knob.width / 2) / m.travel * m.maxOffset)
            guard let n = metrics else { return }
            m = n
        }
        dragStart = (p.x, sv.contentView.bounds.minX)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let m = metrics, m.travel > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        scroll(to: start.offset + (p.x - start.mouse) / m.travel * m.maxOffset)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}

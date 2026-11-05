import AppKit

/// 底部横向缩略图胶片条
final class FilmstripView: NSScrollView {
    let collectionView = FilmstripCollectionView()

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
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = collectionView
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

    private var downEvent: NSEvent?
    private var downIndex: Int?
    /// 按在已经多选的照片上：松手时没拖动才改成只选这一张，拖动就带走整组
    private var deferredClick = false
    private let dragSource = FileDragSource()

    override func mouseDown(with event: NSEvent) {
        downEvent = nil
        // 空白处不框选
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
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
    }

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

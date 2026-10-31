import AppKit

/// 底部横向缩略图胶片条
final class FilmstripView: NSScrollView {
    let collectionView = NSCollectionView()

    init() {
        super.init(frame: .zero)

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 64, height: 64)
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
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

final class FilmstripItem: NSCollectionViewItem {
    private let holder = NSView()
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

        view = v
    }

    func setThumbnail(_ image: CGImage?) {
        holder.layer?.contents = image
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.white.cgColor
            view.alphaValue = isSelected ? 1 : 0.75
        }
    }
}

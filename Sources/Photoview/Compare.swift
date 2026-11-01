import AppKit

/// 并排对比里的一格：照片 + 左下角的序号、文件名、星级、标记；当前格有白框
final class ComparePane: NSView {
    let imageView = ZoomableImageView()
    /// 这一格显示的是文件夹列表里的第几张
    var photoIndex = 0
    /// 正在显示的文件，换图后加载回来时用来核对
    var url: URL?
    /// 按住 ⌥ 单独调过：相对大家共用的缩放和位置差多少，之后一起动时保持这个差
    var zoomRatio: CGFloat = 1
    var centerDelta: CGPoint = .zero
    var isAdjusted: Bool { abs(zoomRatio - 1) > 0.001 || abs(centerDelta.x) > 0.0005 || abs(centerDelta.y) > 0.0005 }

    func resetAdjustment() {
        zoomRatio = 1
        centerDelta = .zero
    }

    /// 共用的状态加上这一格自己的偏差
    func placed(_ s: ZoomableImageView.ViewState) -> ZoomableImageView.ViewState {
        s.fit ? s : .init(fit: false, zoom: s.zoom * zoomRatio,
                          center: CGPoint(x: s.center.x + centerDelta.x, y: s.center.y + centerDelta.y))
    }
    private let footer = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let markIcon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage())
    private let stars = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    var isActive = false {
        didSet {
            layer?.borderWidth = isActive ? 2 : 0
            footer.alphaValue = isActive ? 1 : 0.8
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        footer.material = .hudWindow
        footer.blendingMode = .withinWindow
        footer.state = .active
        footer.wantsLayer = true
        footer.layer?.cornerRadius = 6
        footer.layer?.masksToBounds = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stars.font = .systemFont(ofSize: 11, weight: .medium)
        stars.textColor = ViewerViewController.starColor
        markIcon.contentTintColor = ViewerViewController.markColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [markIcon, label, stars, note])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stack)
        addSubview(footer)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -3),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setInfo(position: Int, total: Int, name: String, rating: Int, marked: Bool, status: String?) {
        note.stringValue = status ?? ""
        note.isHidden = status == nil
        label.stringValue = "\(position) / \(total)  \(name)"
        stars.stringValue = String(repeating: "★", count: rating)
        stars.isHidden = rating == 0
        markIcon.isHidden = !marked
    }

    var debugInfo: String {
        label.stringValue + (markIcon.isHidden ? "" : " [marked]") + (stars.isHidden ? "" : " " + stars.stringValue)
            + (note.isHidden ? "" : " {\(note.stringValue)}")
    }
}

/// 2 格左右排（窗口竖长时上下排），3–4 格排成 2×2
final class CompareView: NSView {
    private(set) var panes: [ComparePane] = []

    func setPaneCount(_ n: Int) {
        while panes.count > n { panes.removeLast().removeFromSuperview() }
        while panes.count < n {
            let p = ComparePane()
            addSubview(p)
            panes.append(p)
        }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gap: CGFloat = 2
        let b = bounds
        let n = panes.count
        guard n > 0 else { return }
        let cols: Int, rows: Int
        if n <= 2 {
            let sideBySide = b.width >= b.height
            cols = sideBySide ? n : 1
            rows = sideBySide ? 1 : n
        } else {
            cols = 2
            rows = 2
        }
        let w = (b.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let h = (b.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (i, p) in panes.enumerated() {
            let c = i % cols, r = i / cols
            p.frame = CGRect(x: CGFloat(c) * (w + gap), y: CGFloat(r) * (h + gap), width: w, height: h).integral
        }
    }
}

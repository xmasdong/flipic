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
    /// 悬停在右上角的移除按钮（仅工作台多图对比 > 2 格时启用）
    private let removeButton = NSButton()
    private var hovered = false { didSet { updateRemoveButton() } }
    private var hoverArea: NSTrackingArea?
    var onRemove: (() -> Void)? { didSet { updateRemoveButton() } }

    var isActive = false {
        didSet {
            layer?.borderWidth = isActive ? 2 : 0
            footer.alphaValue = isActive ? 1 : 0.8
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Theme.refresh(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateRemoveButton() {
        removeButton.isHidden = onRemove == nil || !hovered
    }

    @objc private func removeClicked(_ sender: Any?) { onRemove?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // 看图窗口一直是深色，这里取到的就是深色；工作台跟着外观
        Theme.paint(self, background: Theme.gray(dark: 0.055, light: 0.93), border: Theme.gray(dark: 0.92, light: 0.2))
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

        removeButton.isBordered = false
        removeButton.bezelStyle = .inline
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("wb.compareRemovePane", "移出对比"))?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .bold))
        removeButton.contentTintColor = .white
        removeButton.wantsLayer = true
        removeButton.layer?.cornerRadius = 11
        removeButton.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.58).cgColor
        removeButton.toolTip = L10n.t("wb.compareRemovePane", "移出对比")
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        removeButton.refusesFirstResponder = true
        removeButton.isHidden = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)

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
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22),
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

/// 自适应多格对比布局：2 格左右/上下，3 格横排或 2+1，4 格 2×2，5 格上 3 下 2，6 格 3×2，7 格上 4 下 3，8 格 4×2，9 格 3×3
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

    /// 移出指定那一格，其余格子保留已解码图像和各自缩放偏差
    func removePane(at index: Int) {
        guard panes.indices.contains(index) else { return }
        panes.remove(at: index).removeFromSuperview()
        needsLayout = true
    }

    static func rowDistribution(for n: Int, size: CGSize) -> [Int] {
        switch n {
        case ...0: return []
        case 1: return [1]
        case 2: return size.width >= size.height ? [2] : [1, 1]
        case 3: return size.width >= size.height * 1.15 ? [3] : [2, 1]
        case 4: return [2, 2]
        case 5: return [3, 2]
        case 6: return [3, 3]
        case 7: return [4, 3]
        case 8: return [4, 4]
        case 9: return [3, 3, 3]
        default:
            let cols = Int(ceil(sqrt(Double(n))))
            var rows: [Int] = []
            var rem = n
            while rem > 0 {
                let take = min(cols, rem)
                rows.append(take)
                rem -= take
            }
            return rows
        }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gap: CGFloat = 2
        let b = bounds
        let n = panes.count
        guard n > 0 else { return }
        let dist = Self.rowDistribution(for: n, size: b.size)
        let rows = dist.count
        let h = (b.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        var idx = 0
        for (r, cols) in dist.enumerated() {
            let y = CGFloat(r) * (h + gap)
            let rowH = r == rows - 1 ? b.height - y : h
            let w = (b.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            for c in 0..<cols where idx < n {
                let x = CGFloat(c) * (w + gap)
                let colW = c == cols - 1 ? b.width - x : w
                panes[idx].frame = CGRect(x: x, y: y, width: colW, height: rowH).integral
                idx += 1
            }
        }
    }
}

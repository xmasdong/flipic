import AppKit
import ImageIO
import UniformTypeIdentifiers

final class ViewerViewController: NSViewController {

    private let folder = FolderModel()
    private let loader = ImageLoader.shared

    private let imageView = ZoomableImageView()
    private let filmstrip = FilmstripView()
    private let hudView = NSVisualEffectView()
    private let hudStack = NSStackView()
    private let hudNameLabel = NSTextField(labelWithString: "")
    private let hudDimsLabel = NSTextField(labelWithString: "")
    private let hudExifLabel1 = NSTextField(labelWithString: "")
    private let hudExifLabel2 = NSTextField(labelWithString: "")
    private let exifPanel = NSVisualEffectView()
    private let exifStack = NSStackView()
    private let emptyState = NSStackView()
    private let emptyHint = NSTextField(labelWithString: "")
    private let toolbarView = NSVisualEffectView()
    private var slideshowButton: NSButton?
    private var prevArrowContainer: NSView!
    private var nextArrowContainer: NSView!
    private var prevArrowButton: ToolbarButton!
    private var nextArrowButton: ToolbarButton!
    private var controlsHideTimer: Timer?
    private var controlsVisible = true
    private var filmstripHeight: NSLayoutConstraint!
    /// 平时图片停在缩略图栏上方；幻灯片放映时图片铺到底，缩略图栏浮在上面，跟着控件一起自动隐藏
    private var imageAboveFilmstrip: NSLayoutConstraint!
    private var imageToBottom: NSLayoutConstraint!
    private var generation = 0
    private var slideshowTimer: Timer?
    private var isProcessing = false
    private var qualityLabel: NSTextField?
    private var flashItem: DispatchWorkItem?
    private var isFlashing = false
    private var exportEstimateWork: DispatchWorkItem?
    private var exportEstimateGeneration = 0
    private var exportEstimateCache: [String: Int64] = [:]
    private var exportFormatPopup: NSPopUpButton?
    private var exportQualitySlider: NSSlider?
    private var exportQualityLabel: NSTextField?
    private var exportEstimateLabel: NSTextField?
    private weak var exportSavePanel: NSSavePanel?
    private var batchQualitySlider: NSSlider?
    private var aboutWindowController: NSWindowController?

    private static let exportFormats: [(name: String, uti: UTType, ext: String)] = [
        ("JPEG", .jpeg, "jpg"), ("PNG", .png, "png"), ("HEIC", .heic, "heic"),
    ]
    private var warmupGeneration = 0
    private var prefetchedURLs = Set<URL>()
    private var lastNavDirection = 1
    private var fullRequested = false
    private var folderGeneration = 0
    /// 打开的是文件夹且用户还没翻页：拍摄时间读完重排后回到新的第一张
    private var showFirstAfterResort = false
    /// 按住空格预览：进入前的窗口与界面状态，退出时原样恢复；非 nil 即正在预览
    private var peekSaved: (frame: NSRect, minSize: NSSize, filmstripHidden: Bool, infoHidden: Bool)?
    /// 清理模式开着时盖在整个看图界面上
    private var cleanup: CleanupController?

    /// 当前图解码：最多 2 路并行（新图预览 + 旧图全分辨率不互相堵）；翻页即取消过期任务
    private let decodeQueue = ViewerViewController.makeQueue("decode", width: 2, qos: .userInitiated)
    /// 预取串行：后台一次只解一张，不与前台抢 CPU 和内存带宽
    private let prefetchQueue = ViewerViewController.makeQueue("prefetch", width: 1, qos: .utility)
    private let thumbQueue = ViewerViewController.makeQueue("thumb", width: 2, qos: .utility)

    private static func makeQueue(_ name: String, width: Int, qos: QualityOfService) -> OperationQueue {
        let q = OperationQueue()
        q.name = "flipic.\(name)"
        q.maxConcurrentOperationCount = width
        q.qualityOfService = qos
        return q
    }

    /// 缓存策略：缩略图预热限 100 张；预览窗口随浏览方向滑动；窗口外显式淘汰。
    /// 全分辨率图只在放大到预览不够清晰时才解码（ImageLoader 里只留 2 张）
    private enum CachePolicy {
        static let warmupLimit = 100
        static let previewAhead = 5      // 浏览方向前方多备几张
        static let previewBehind = 2     // 后方留少量，往回翻也快
        static let evictPreviewOutside = 8
    }

    private static let filmstripID = NSUserInterfaceItemIdentifier("thumb")

    // MARK: - 布局

    override func loadView() {
        let dropView = DropView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860))
        dropView.wantsLayer = true
        dropView.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        dropView.onDrop = { [weak self] urls in
            guard let url = urls.first else { return }
            self?.open(url: url)
        }
        dropView.onMouseMoved = { [weak self] in self?.pokeControls() }
        dropView.onMouseExited = { [weak self] in self?.scheduleControlsHide() }
        view = dropView

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onZoomChange = { [weak self] _ in self?.updateHUD() }
        imageView.onNeedsDetail = { [weak self] in self?.loadFullResolution() }
        imageView.onNavigate = { [weak self] delta in self?.navigate(delta) }
        imageView.onFirst = { [weak self] in self?.goTo(0) }
        imageView.onLast = { [weak self] in self?.goTo(max(self?.folder.count ?? 1, 1) - 1) }
        imageView.onToggleInfo = { [weak self] in self?.toggleInfoPanel(nil) }
        imageView.onToggleFilmstrip = { [weak self] in self?.toggleFilmstrip(nil) }
        imageView.onToggleFullscreen = { [weak self] in
            guard let window = self?.view.window else { return }
            self?.imageView.endPeek()
            window.toggleFullScreen(window)
        }
        imageView.onTrash = { [weak self] in self?.trashCurrent(nil) }
        imageView.onSlideshow = { [weak self] in self?.toggleSlideshow(nil) }
        imageView.onRename = { [weak self] in self?.renameCurrent(nil) }
        imageView.onCommand = { [weak self] action in self?.perform(action) }
        imageView.onSingleClick = { [weak self] in self?.toggleSlideshowPause() }
        imageView.onFirstFrame = { [weak self] size in
            self?.folder.setCurrentPixelSize(size)
            self?.updateHUD()
        }
        imageView.onActivity = { [weak self] in self?.pokeControls() }
        imageView.onPeekBegin = { [weak self] in self?.beginPeek() ?? false }
        imageView.onPeekEnd = { [weak self] in self?.endPeek() }
        imageView.onEscape = { [weak self] in
            guard let self, let window = self.view.window else { return }
            if self.imageView.isPeeking {
                if self.peekFromOpen && Self.escCloses {
                    window.performClose(nil)   // 当快速查看用：打开就是贴合预览，Esc 直接回访达
                    return
                }
                self.imageView.endPeek()
            } else if !self.exifPanel.isHidden {
                self.exifPanel.isHidden = true   // 右上角的照片信息面板开着时，Esc 先关它
            } else if Self.escCloses {
                // 像快速查看一样用：放大时先回到适应窗口，已经适应窗口再按就关掉回访达
                if self.imageView.isFit { window.performClose(nil) } else { self.imageView.fit(animate: true) }
            } else if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(window)
            } else {
                self.imageView.fit(animate: true)
            }
        }
        imageView.menu = buildContextMenu()
        view.addSubview(imageView)

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidExitFullScreen(_:)),
                                               name: NSWindow.didExitFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)),
                                               name: SettingsWindowController.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcutTips),
                                               name: Shortcuts.didChange, object: nil)

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.collectionView.dataSource = self
        filmstrip.collectionView.delegate = self
        filmstrip.collectionView.register(FilmstripItem.self, forItemWithIdentifier: Self.filmstripID)
        view.addSubview(filmstrip)

        buildHUD()
        buildExifPanel()
        buildEmptyState()
        buildToolbar()
        buildArrows()
        buildRatingBadge()
        ratingBadgeBottom = ratingBadge.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: ratingBadgeOffset(controls: false))
        refreshShortcutTips()

        filmstripHeight = filmstrip.heightAnchor.constraint(equalToConstant: FilmstripView.stripHeight)
        imageAboveFilmstrip = imageView.bottomAnchor.constraint(equalTo: filmstrip.topAnchor)
        imageToBottom = imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            filmstrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            filmstripHeight,

            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageAboveFilmstrip,

            hudView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            hudView.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),

            exifPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            exifPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            exifPanel.widthAnchor.constraint(equalToConstant: 300),

            ratingBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ratingBadgeBottom,

            toolbarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -8),

            prevArrowContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            prevArrowContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nextArrowContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            nextArrowContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
        ])
    }

    // 左右两侧的翻页大箭头
    private func buildArrows() {
        let defs: [(symbol: String, tip: String, action: Selector)] = [
            ("chevron.left", L10n.t("tip.prev", "上一张（←）"), #selector(navigateBackward(_:))),
            ("chevron.right", L10n.t("tip.next", "下一张（→）"), #selector(navigateForward(_:))),
        ]
        for (i, d) in defs.enumerated() {
            let (container, button) = iconButton(symbol: d.symbol, tip: d.tip, action: d.action,
                                                 size: NSSize(width: 44, height: 56), cornerRadius: 11,
                                                 symbolSize: 20, symbolWeight: .semibold)
            if let a = Self.shortcutAction(for: d.action) { shortcutTips.append((button, d.tip, a)) }
            if i == 0 {
                prevArrowContainer = container
                prevArrowButton = button
            } else {
                nextArrowContainer = container
                nextArrowButton = button
            }
            view.addSubview(container)
        }
    }

    // MARK: - 控件自动隐藏

    private func pokeControls() {
        guard peekSaved == nil, compareView == nil else { return }
        setControlsVisible(true)
        controlsHideTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.setControlsVisible(false)
        }
        RunLoop.main.add(timer, forMode: .common)
        controlsHideTimer = timer
    }

    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.setControlsVisible(false)
        }
        RunLoop.main.add(timer, forMode: .common)
        controlsHideTimer = timer
    }

    private func setControlsVisible(_ visible: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        var targets: [NSView] = [prevArrowContainer!, nextArrowContainer!]
        if Self.showToolbar { targets.append(toolbarView) }
        if filmstripFloating && filmstripHeight.constant > 0 { targets.append(filmstrip) }
        if visible {
            for t in targets where folder.current != nil { t.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = visible ? 0.15 : 0.4
            ctx.allowsImplicitAnimation = true
            for t in targets {
                t.animator().alphaValue = visible ? 1 : 0
            }
            ratingBadgeBottom?.animator().constant = ratingBadgeOffset(controls: visible)
        }, completionHandler: {
            for t in targets {
                t.isHidden = t.alphaValue < 0.01
            }
        })
    }

    private func updateControlsPresence() {
        let present = folder.current != nil
        for t in [toolbarView, prevArrowContainer!, nextArrowContainer!] { t.isHidden = !present }
        if !Self.showToolbar { toolbarView.isHidden = true }
        if present { pokeControls() }
    }

    // MARK: - 空格预览：窗口贴合图片比例（同访达空格预览）

    /// 返回是否进入了预览：全屏或没有图片时不进入
    private func beginPeek() -> Bool {
        guard let window = view.window, peekSaved == nil, folder.current != nil,
              !window.styleMask.contains(.fullScreen) else { return false }
        peekSaved = (window.frame, window.minSize, filmstrip.isHidden, exifPanel.isHidden)
        controlsHideTimer?.invalidate()
        setControlsVisible(false)
        hudView.isHidden = true
        exifPanel.isHidden = true
        filmstrip.isHidden = true
        ratingBadge.isHidden = true
        markBadge.isHidden = true
        filmstripHeight.constant = 0
        window.minSize = NSSize(width: 160, height: 120)
        imageView.fit()
        wrapWindowToImage()
        return true
    }

    private func endPeek() {
        guard let window = view.window, let saved = peekSaved else { return }
        peekFromOpen = false
        peekSaved = nil
        window.setFrame(saved.frame, display: true, animate: true)
        window.minSize = saved.minSize
        filmstrip.isHidden = saved.filmstripHidden
        filmstripHeight.constant = saved.filmstripHidden ? 0 : FilmstripView.stripHeight
        exifPanel.isHidden = saved.infoHidden
        if !saved.infoHidden { updateExifPanel() }
        updateHUD()
        updateRatingLabel()
        pokeControls()
        imageView.fit()
    }

    /// 窗口按图片比例重新取形：以原图 100% 的点尺寸为上限，超出屏幕可见区 90% 则等比缩小，
    /// 中心对准进入预览前的窗口中心
    private func wrapWindowToImage() {
        guard let window = view.window, let saved = peekSaved,
              let screen = window.screen ?? NSScreen.main else { return }
        let px = imageView.pixelSize
        guard px.width > 0, px.height > 0 else { return }
        let visible = screen.visibleFrame
        var w = px.width / window.backingScaleFactor
        var h = px.height / window.backingScaleFactor
        let k = min(1, visible.width * 0.9 / w, visible.height * 0.9 / h)
        w *= k; h *= k
        let minSide: CGFloat = 360
        if max(w, h) < minSide {
            let g = minSide / max(w, h)
            w *= g; h *= g
        }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
        frame.origin = CGPoint(x: saved.frame.midX - frame.width / 2, y: saved.frame.midY - frame.height / 2)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - 悬浮工具条

    private func buildToolbar() {
        toolbarView.material = .hudWindow
        toolbarView.blendingMode = .withinWindow
        toolbarView.state = .active
        toolbarView.wantsLayer = true
        toolbarView.layer?.cornerRadius = 13
        toolbarView.layer?.masksToBounds = true
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.isHidden = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        ratingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        ratingLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.25, alpha: 1)
        ratingLabel.isHidden = true
        stack.insertArrangedSubview(ratingLabel, at: 0)
        stack.setCustomSpacing(10, after: ratingLabel)
        toolbarView.addSubview(stack)

        // 按功能分组，组间插入分隔线
        let groups: [[(symbol: String, tip: String, action: Selector)]] = [
            [("plus.magnifyingglass", L10n.t("tip.zoomIn", "放大（↑）"), #selector(zoomIn(_:))),
             ("minus.magnifyingglass", L10n.t("tip.zoomOut", "缩小（↓）"), #selector(zoomOut(_:))),
             ("arrow.down.right.and.arrow.up.left", L10n.t("tip.fit", "适应窗口（0 / 双击）"), #selector(zoomFit(_:))),
             ("1.magnifyingglass", L10n.t("tip.actual", "实际大小（1）"), #selector(zoomActual(_:)))],
            [("rotate.left", L10n.t("tip.rotateCCW", "向左旋转 90°（L）"), #selector(rotateCCW(_:))),
             ("rotate.right", L10n.t("tip.rotateCW", "向右旋转 90°（R）"), #selector(rotateCW(_:)))],
            [("play.fill", L10n.t("tip.slideshow", "幻灯片放映（S）"), #selector(toggleSlideshow(_:)))],
            [("info.circle", L10n.t("tip.info", "照片信息（I）"), #selector(toggleInfoPanel(_:))),
             ("photo.on.rectangle", L10n.t("tip.strip", "底部缩略图栏开关（T）"), #selector(toggleFilmstrip(_:)))],
            [("folder.badge.plus", L10n.t("tip.exportFolder", "把当前显示的照片复制或移动到文件夹（⇧⌘E）"), #selector(exportToFolder(_:))),
             ("square.and.arrow.down", L10n.t("tip.export", "导出压缩副本（⌘S）"), #selector(exportAs(_:))),
             ("pencil", L10n.t("tip.rename", "重命名（回车）"), #selector(renameCurrent(_:))),
             ("trash", L10n.t("tip.trash", "移到废纸篓（⌘⌫）"), #selector(trashCurrent(_:)))],
        ]
        for (gi, group) in groups.enumerated() {
            if gi > 0 {
                let separator = toolbarSeparator()
                stack.addArrangedSubview(separator)
                stack.setCustomSpacing(9, after: separator)
            }
            for d in group {
                let (container, button) = iconButton(symbol: d.symbol, tip: d.tip, action: d.action,
                                                     size: NSSize(width: 36, height: 32), cornerRadius: 7,
                                                     tint: d.symbol == "trash" ? .systemRed : .labelColor)
                if d.symbol == "play.fill" { slideshowButton = button }
                if let a = Self.shortcutAction(for: d.action) { shortcutTips.append((button, d.tip, a)) }
                stack.addArrangedSubview(container)
            }
        }
        view.addSubview(toolbarView)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toolbarView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor),
        ])
    }

    private func toolbarSeparator() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        return view
    }

    /// 图标按钮包在固定尺寸容器里：按钮用 frame + autoresizing 定位（NSButton 的内部
    /// 尺寸约束会干扰 Auto Layout），容器负责进入 Auto Layout 体系
    private func iconButton(symbol: String, tip: String, action: Selector,
                            size: NSSize, cornerRadius: CGFloat,
                            symbolSize: CGFloat = 15,
                            symbolWeight: NSFont.Weight = .medium,
                            tint: NSColor = .labelColor) -> (container: NSView, button: ToolbarButton) {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),
        ])

        let button = ToolbarButton(frame: container.bounds)
        button.target = self
        button.action = action
        if var image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            image = image.withSymbolConfiguration(.init(pointSize: symbolSize, weight: symbolWeight)) ?? image
            button.image = image
        } else {
            button.title = tip
        }
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = tint
        button.toolTip = tip
        button.wantsLayer = true
        button.layer?.cornerRadius = cornerRadius
        button.autoresizingMask = [.width, .height]
        container.addSubview(button)
        return (container, button)
    }

    private func updateSlideshowButton() {
        guard let button = slideshowButton else { return }
        let symbol = slideshowActive ? "stop.fill" : "play.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    private func buildHUD() {
        hudView.material = .hudWindow
        hudView.blendingMode = .withinWindow
        hudView.state = .active
        hudView.wantsLayer = true
        hudView.layer?.cornerRadius = 12
        hudView.layer?.masksToBounds = true
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.isHidden = true

        hudStack.orientation = .vertical
        hudStack.alignment = .leading
        hudStack.spacing = 5
        hudStack.edgeInsets = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
        hudStack.translatesAutoresizingMaskIntoConstraints = false
        hudView.addSubview(hudStack)
        view.addSubview(hudView)

        let labels: [(NSTextField, NSFont, NSColor)] = [
            (hudNameLabel, .systemFont(ofSize: 13, weight: .semibold), .labelColor),
            (hudDimsLabel, .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .labelColor),
            (hudExifLabel1, .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor),
            (hudExifLabel2, .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor),
        ]
        for (label, f, c) in labels {
            label.font = f
            label.textColor = c
            // 单行 + 中段截断：长文件名显示为「前缀…扩展名」，卡片尺寸恒定不撑开
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            hudStack.addArrangedSubview(label)
        }

        NSLayoutConstraint.activate([
            hudStack.topAnchor.constraint(equalTo: hudView.topAnchor),
            hudStack.bottomAnchor.constraint(equalTo: hudView.bottomAnchor),
            hudStack.leadingAnchor.constraint(equalTo: hudView.leadingAnchor),
            hudStack.trailingAnchor.constraint(equalTo: hudView.trailingAnchor),
            hudView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            hudView.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            hudView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func buildExifPanel() {
        exifPanel.material = .hudWindow
        exifPanel.blendingMode = .withinWindow
        exifPanel.state = .active
        exifPanel.wantsLayer = true
        exifPanel.layer?.cornerRadius = 12
        exifPanel.layer?.masksToBounds = true
        exifPanel.translatesAutoresizingMaskIntoConstraints = false
        exifPanel.isHidden = true

        exifStack.orientation = .vertical
        exifStack.alignment = .leading
        exifStack.spacing = 6
        exifStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        exifStack.translatesAutoresizingMaskIntoConstraints = false
        exifPanel.addSubview(exifStack)
        view.addSubview(exifPanel)

        NSLayoutConstraint.activate([
            exifStack.topAnchor.constraint(equalTo: exifPanel.topAnchor),
            exifStack.bottomAnchor.constraint(equalTo: exifPanel.bottomAnchor),
            exifStack.leadingAnchor.constraint(equalTo: exifPanel.leadingAnchor),
            exifStack.trailingAnchor.constraint(equalTo: exifPanel.trailingAnchor),
        ])
    }

    private func buildEmptyState() {
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 12
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Flipic")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .tertiaryLabelColor
        emptyHint.stringValue = L10n.t("ui.emptyHint", "把文件夹或图片拖进这个窗口，或点击「打开…」")
        emptyHint.font = .systemFont(ofSize: 13)
        emptyHint.textColor = .secondaryLabelColor
        let button = NSButton(title: L10n.t("ui.openButton", "打开…"), target: self, action: #selector(openFolderPanel(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large

        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(emptyHint)
        emptyState.addArrangedSubview(button)
        view.addSubview(emptyState)
    }

    // MARK: - 打开与加载

    /// 从访达打开单张照片时，窗口直接贴合照片比例（同空格预览）；打开文件夹还是普通窗口。默认关，设置里打开
    static var openInPeek: Bool {
        get { UserDefaults.standard.bool(forKey: "openInPeek") }
        set { UserDefaults.standard.set(newValue, forKey: "openInPeek") }
    }
    private var peekOnFirstImage = false
    /// 这次贴合预览是打开照片时自动进的：开着「按 Esc 关闭窗口」时，Esc 直接关窗口
    private var peekFromOpen = false

    var isEmpty: Bool { folder.count == 0 }
    var debugFilmstripHeight: CGFloat { filmstrip.frame.height }

    func open(url: URL) {
        exitCompare()
        prefetchedURLs.removeAll()
        decodeQueue.cancelAllOperations()
        prefetchQueue.cancelAllOperations()
        thumbQueue.cancelAllOperations()
        folderGeneration += 1
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        showFirstAfterResort = isDir.boolValue
        peekOnFirstImage = !isDir.boolValue && Self.openInPeek && !CommandLine.arguments.contains(where: { $0.hasPrefix("--") && !["--peekopentest", "--press-esc", "--press-next"].contains($0) })
        let ok = folder.open(url: url)
        emptyState.isHidden = ok
        updateControlsPresence()
        if !ok {
            imageView.set(image: nil, resetToFit: true, isNew: true)
            emptyHint.stringValue = L10n.t("ui.noImages", "这里没有可识别的图片文件")
        }
        filmstrip.collectionView.reloadData()
        filmstrip.scrollTo(index: folder.index)
        if ok {
            view.window?.makeFirstResponder(imageView)
            showImage(resetToFit: true)
            startFolderWarmup()
            loadCaptureDatesIfNeeded()
            showCleanupHintIfNeeded()
        } else {
            updateHUD()
        }
    }

    private var previewPixelTarget: CGFloat {
        let scale = view.window?.backingScaleFactor ?? 2
        let b = view.bounds
        return min(max(max(b.width, b.height) * scale, 1024), 8192)
    }

    /// 加载管线：缓存命中直出 → 降采样预览秒开 → 放大到预览不够清晰时才解全分辨率。
    /// 主线程只做缓存查询，文件 I/O 与解码全部在限流队列里
    private func showImage(resetToFit: Bool) {
        generation += 1
        let gen = generation
        fullRequested = false
        guard let item = folder.current else { return }
        let url = item.url
        // 「窗口」菜单里按文件名区分多个窗口（标题栏本身是隐藏的）
        view.window?.title = url.lastPathComponent
        decodeQueue.cancelAllOperations()
        updateSmartCache()
        updateHUD(); updateExifPanel(); syncFilmstripSelection(); loadRating(for: url)
        updateMarkedOnlyPill()

        let fitPx = previewPixelTarget
        if let info = loader.cachedInfo(for: url),
           let hit = loader.cachedFull(for: url) ?? loader.cachedPreview(for: url, maxPixel: fitPx) {
            fullRequested = loader.cachedFull(for: url) != nil
            adopt(hit, logicalSize: info.pixelSize, resetToFit: resetToFit, isNew: true)
            if info.isAnimated { imageView.startAnimatedPlayback(url: url) }
            return
        }

        let loader = self.loader
        decodeQueue.addOperation { [weak self] in
            guard self?.generation == gen, let info = loader.info(for: url) else { return }
            let pv = loader.preview(for: url, maxPixel: fitPx)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, let pv else { return }
                self.adopt(pv, logicalSize: info.pixelSize, resetToFit: resetToFit, isNew: true)
                // 动图：ImageIO 在主队列按帧时长驱动播放
                if info.isAnimated { self.imageView.startAnimatedPlayback(url: url) }
            }
        }
    }

    /// 由视图在放大超过预览分辨率时触发：后台解码全分辨率并原位替换
    private func loadFullResolution() {
        guard !fullRequested, let url = folder.current?.url else { return }
        fullRequested = true
        let gen = generation
        let loader = self.loader
        decodeQueue.addOperation { [weak self] in
            guard self?.generation == gen, let info = loader.info(for: url) else { return }
            let full = loader.fullImage(for: url)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, let full else { return }
                self.adopt(full, logicalSize: info.pixelSize, resetToFit: false, isNew: false)
            }
        }
    }

    private func adopt(_ image: CGImage, logicalSize: CGSize, resetToFit: Bool, isNew: Bool) {
        folder.setCurrentPixelSize(logicalSize)
        imageView.set(image: image, logicalSize: logicalSize, resetToFit: resetToFit, isNew: isNew)
        if isNew { BenchProbe.adopted() } else { BenchProbe.fullWidth = image.width }
        if isNew, peekSaved != nil { wrapWindowToImage() }
        if isNew, peekOnFirstImage {
            peekOnFirstImage = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.peekSaved == nil else { return }
                self.imageView.enterPeek()
                self.peekFromOpen = self.peekSaved != nil
            }
        }
        updateHUD()
    }

    /// --selftest 自检：验证左右箭头的命中测试与点击动作（仅诊断用）
    func runSelfTest() {
        NSLog("SELFTEST locale=%@ menu.open=%@", Bundle.main.preferredLocalizations.first ?? "?",
              L10n.t("menu.open", "打开…"))
        let p = CGPoint(x: 34, y: view.bounds.midY)
        let hit = view.hitTest(p)
        NSLog("SELFTEST hitTest(\(p.x), \(p.y)) -> \(String(describing: type(of: hit)))")
        if let hit {
            NSLog("SELFTEST hit frame=\(hit.frame) hidden=\(hit.isHidden) alpha=\(hit.alphaValue)")
        }
        NSLog("SELFTEST prevContainer frame=\(prevArrowContainer.frame) hidden=\(prevArrowContainer.isHidden)")
        NSLog("SELFTEST prevButton frame=\(prevArrowButton.frame) hidden=\(prevArrowButton.isHidden)")
        if let button = hit as? NSButton {
            button.performClick(nil)
            NSLog("SELFTEST performClick 完成")
        } else {
            NSLog("SELFTEST 命中的不是按钮！")
        }
        // 导出面板 + 预估大小链路自检
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.exportAs(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            NSLog("SELFTEST estimate=\(self?.exportEstimateLabel?.stringValue ?? "?")")
            if let panel = self?.exportSavePanel, let sheetParent = panel.sheetParent {
                sheetParent.endSheet(panel)
            }
        }
        // 动图播放链路自检
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
            self?.open(url: URL(fileURLWithPath: "/tmp/photoview-anim"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            NSLog("SELFTEST animation animated=\(self?.imageView.isAnimated ?? false) size=\(Int(self?.imageView.pixelSize.width ?? 0))x\(Int(self?.imageView.pixelSize.height ?? 0))")
        }
    }

    var debugZoomState: String { imageView.fitDiagnostics }

    private func navigate(_ delta: Int) {
        // 手动翻页不带幻灯片的渐变
        if !advancingSlideshow { imageView.pendingFadeDuration = nil }
        if BenchProbe.traceNav { NSLog("TRACE navigate delta=%d slideshow=%d from=%d", delta, advancingSlideshow ? 1 : 0, folder.index) }
        if CommandLine.arguments.contains("--selftest") {
            NSLog("SELFTEST navigate delta=\(delta) index \(folder.index) ->")
        }
        lastNavDirection = delta
        showFirstAfterResort = false
        folder.go(delta)
        showImage(resetToFit: false)
    }

    private func goTo(_ index: Int) {
        lastNavDirection = index >= folder.index ? 1 : -1
        showFirstAfterResort = false
        folder.jump(to: index)
        showImage(resetToFit: false)
    }

    // MARK: - 排序

    @objc func setSortKey(_ sender: NSMenuItem) {
        guard let key = SortKey(rawValue: sender.tag), key != folder.sortKey else { return }
        folder.sortKey = key
        applySort()
        loadCaptureDatesIfNeeded()
    }

    /// 适应窗口时按 Esc 直接关闭窗口（退出），默认关
    static var escCloses: Bool {
        get { UserDefaults.standard.bool(forKey: "escCloses") }
        set { UserDefaults.standard.set(newValue, forKey: "escCloses") }
    }

    @objc func toggleEscCloses(_ sender: Any?) {
        Self.escCloses.toggle()
        flash(Self.escCloses ? L10n.t("msg.escClosesOn", "适应窗口时按 Esc 关闭 Flipic")
                             : L10n.t("msg.escClosesOff", "Esc 不再关闭窗口"))
    }

    @objc func toggleFadeTransition(_ sender: Any?) {
        ZoomableImageView.fadeTransition.toggle()
    }

    @objc func setWheelAction(_ sender: NSMenuItem) {
        ZoomableImageView.wheelNavigates = sender.tag == 1
        flash(sender.tag == 1 ? L10n.t("wheel.navigate.on", "滚轮：切换图片（⌘+滚轮缩放）")
                              : L10n.t("wheel.zoom.on", "滚轮：缩放图片（⌘+滚轮平移）"))
    }

    @objc func toggleWheelZoomInverted(_ sender: Any?) {
        ZoomableImageView.wheelZoomInverted.toggle()
        flash(ZoomableImageView.wheelZoomInverted ? L10n.t("wheel.inverted.on", "滚轮缩放方向已反转")
                                                   : L10n.t("wheel.inverted.off", "滚轮缩放方向已恢复默认"))
    }

    @objc func toggleSortReversed(_ sender: Any?) {
        folder.sortReversed.toggle()
        applySort()
    }

    /// 重排后当前看的图不变，只更新序号、胶片条与预取窗口
    private func applySort() {
        guard folder.count > 0 else { return }
        exitCompare()
        if showFirstAfterResort {
            folder.resort(keeping: nil)
            filmstrip.collectionView.reloadData()
            showImage(resetToFit: true)
        } else {
            folder.resort(keeping: folder.current?.url)
            filmstrip.collectionView.reloadData()
            updateHUD()
            updateSmartCache()
            syncFilmstripSelection()
        }
        filmstrip.scrollTo(index: folder.index)
    }

    /// 按拍摄时间排序时在后台并发读 EXIF（只读文件头），读完一次性重排
    private func loadCaptureDatesIfNeeded() {
        guard folder.needsCaptureDates else { return }
        let gen = folderGeneration
        let fallbacks = Dictionary(folder.items.filter { $0.captureDate == nil }.map { ($0.url, $0.modified) },
                                   uniquingKeysWith: { a, _ in a })
        let urls = Array(fallbacks.keys)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var dates = [Date](repeating: .distantPast, count: urls.count)
            dates.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                    buf[i] = FolderModel.readCaptureDate(url: urls[i], fallback: fallbacks[urls[i]] ?? nil)
                }
            }
            let map = Dictionary(uniqueKeysWithValues: zip(urls, dates))
            DispatchQueue.main.async {
                guard let self, self.folderGeneration == gen else { return }
                self.folder.setCaptureDates(map)
                if self.folder.sortKey == .captureDate { self.applySort() }
            }
        }
    }

    /// 缓存窗口随浏览方向滑动：顺翻时前方多备、后方留少量；窗口外显式淘汰，内存有界。
    /// 每次翻页重排预取队列：离当前最近的先解，快速连翻时过期任务直接取消
    private func updateSmartCache() {
        let i = folder.index
        guard folder.items.indices.contains(i) else { return }
        let loader = self.loader
        let n = folder.count

        func distance(_ j: Int) -> Int {
            let d = abs(j - i)
            return min(d, n - d)   // 翻页是循环的，首尾相邻
        }
        var keep = Set<URL>()
        for j in folder.items.indices where distance(j) <= CachePolicy.evictPreviewOutside {
            keep.insert(folder.items[j].url)
        }
        for stale in prefetchedURLs.subtracting(keep) {
            loader.evictPreview(url: stale)
        }
        prefetchedURLs.formIntersection(keep)

        let ahead = lastNavDirection >= 0 ? CachePolicy.previewAhead : CachePolicy.previewBehind
        let behind = lastNavDirection >= 0 ? CachePolicy.previewBehind : CachePolicy.previewAhead
        var order: [URL] = []
        for step in 1...max(ahead, behind) {
            if step <= ahead { order.append(folder.items[(i + step) % n].url) }
            if step <= behind { order.append(folder.items[((i - step) % n + n) % n].url) }
        }
        let current = folder.items[i].url
        let fitPx = previewPixelTarget
        prefetchQueue.cancelAllOperations()
        for url in order where url != current {
            prefetchedURLs.insert(url)
            if loader.cachedPreview(for: url, maxPixel: fitPx) != nil { continue }
            prefetchQueue.addOperation {
                _ = loader.info(for: url)
                _ = loader.preview(for: url, maxPixel: fitPx)
            }
        }
    }

    /// 后台低速预热当前图前后共 100 张的缩略图（每张 ~50KB），胶片条随时秒开；
    /// 换文件夹即作废重来，不与前台抢 CPU
    private func startFolderWarmup() {
        warmupGeneration += 1
        let gen = warmupGeneration
        var urls: [URL] = []
        var next = 1
        while urls.count < CachePolicy.warmupLimit {
            var expanded = false
            for offset in [next, -next] {
                let idx = folder.index + offset
                if urls.count < CachePolicy.warmupLimit, folder.items.indices.contains(idx) {
                    urls.append(folder.items[idx].url)
                    expanded = true
                }
            }
            if !expanded { break }
            next += 1
        }
        let loader = self.loader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for url in urls {
                guard let self, self.warmupGeneration == gen else { return }
                _ = loader.thumb(for: url)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    // MARK: - HUD / EXIF / 胶片条

    /// 左上角只用来显示几秒就消失的临时提示；照片信息统一在右上角面板（I）里看
    private func updateHUD() {
        guard !isFlashing else { return }
        hudView.isHidden = true
    }

    /// 异步读取当前图的 EXIF 摘要与文件大小，读完后刷新信息条

    /// 面板打开时才读完整 EXIF，在后台读完再回主线程排版
    private func updateExifPanel() {
        guard !exifPanel.isHidden, let item = folder.current else { return }
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = ExifReader.read(url: item.url)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, !self.exifPanel.isHidden else { return }
                self.renderExifPanel(entries)
            }
        }
    }

    private func renderExifPanel(_ entries: [ExifEntry]) {
        for v in exifStack.arrangedSubviews { v.removeFromSuperview() }

        let title = NSTextField(labelWithString: L10n.t("ui.exifTitle", "照片信息"))
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        exifStack.addArrangedSubview(title)

        if currentRating > 0 {
            let l = NSTextField(labelWithString: L10n.t("menu.rating", "评分"))
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            let v = NSTextField(labelWithString: Rating.stars(currentRating))
            v.font = .systemFont(ofSize: 12)
            v.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.25, alpha: 1)
            exifStack.addArrangedSubview(l)
            exifStack.addArrangedSubview(v)
        }
        if entries.isEmpty {
            let none = NSTextField(labelWithString: L10n.t("ui.noExif", "此文件没有 EXIF 信息"))
            none.font = .systemFont(ofSize: 12)
            none.textColor = .secondaryLabelColor
            exifStack.addArrangedSubview(none)
        }
        for e in entries {
            let l = NSTextField(labelWithString: e.label)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            exifStack.addArrangedSubview(l)
            if let link = e.link {
                // 拍摄地点：点击在「地图」里打开
                let b = NSButton(title: e.value + "  ↗", target: self, action: #selector(openExifLink(_:)))
                b.isBordered = false
                b.font = .systemFont(ofSize: 12)
                b.contentTintColor = .linkColor
                b.alignment = .left
                b.toolTip = L10n.t("exif.openMaps", "在「地图」中打开")
                b.identifier = NSUserInterfaceItemIdentifier(link.absoluteString)
                b.setAccessibilityLabel(e.label)
                exifStack.addArrangedSubview(b)
                continue
            }
            let v = NSTextField(labelWithString: e.value)
            v.font = .systemFont(ofSize: 12)
            v.textColor = .labelColor
            v.maximumNumberOfLines = 2
            v.lineBreakMode = .byWordWrapping
            v.setAccessibilityLabel(e.label)
            v.preferredMaxLayoutWidth = 260
            exifStack.addArrangedSubview(v)
        }
    }

    @objc private func openExifLink(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// 只改选中态，不 reloadData（整条重建会让所有可见格子重新取缩略图）
    private func syncFilmstripSelection() {
        let cv = filmstrip.collectionView
        guard !folder.items.isEmpty else { return }
        let target = IndexPath(item: folder.index, section: 0)
        if cv.selectionIndexPaths == [target] { return }
        cv.deselectAll(nil)
        cv.selectItems(at: Set([IndexPath(item: folder.index, section: 0)]),
                       scrollPosition: [.centeredHorizontally])
    }

    // MARK: - 菜单动作

    @objc func openFolderPanel(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.current?.url.deletingLastPathComponent()
        panel.message = "选择一个图片文件夹，或其中任意一张图片"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            if resp == .OK, let url = panel.url {
                self.open(url: url)
            } else {
                window.makeFirstResponder(self.imageView)
            }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let item = folder.current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc func trashCurrent(_ sender: Any?) {
        exitCompare()
        guard let item = folder.current else { return }
        let gen = generation
        NSWorkspace.shared.recycle([item.url]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.loader.evict(url: item.url)
                if self.folder.removeCurrent() {
                    self.filmstrip.collectionView.reloadData()
                    self.showImage(resetToFit: false)
                } else {
                    self.imageView.set(image: nil, resetToFit: true, isNew: true)
                    self.emptyState.isHidden = false
                    self.updateControlsPresence()
                    self.emptyHint.stringValue = L10n.t("ui.noMore", "文件夹里没有更多图片了")
                    self.filmstrip.collectionView.reloadData()
                    self.updateHUD()
                }
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { imageView.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { imageView.zoomOut() }
    @objc func zoomFit(_ sender: Any?) { imageView.fit(animate: true) }
    @objc func zoomActual(_ sender: Any?) { imageView.actualSize() }

    @objc func toggleInfoPanel(_ sender: Any?) {
        exifPanel.isHidden.toggle()
        if !exifPanel.isHidden { updateExifPanel() }
    }

    @objc func toggleFilmstrip(_ sender: Any?) {
        let show = filmstrip.isHidden
        filmstrip.isHidden = !show
        filmstripHeight.constant = show ? FilmstripView.stripHeight : 0
    }

    @objc func toggleToolbar(_ sender: Any?) {
        Self.showToolbar.toggle()
        SettingsWindowController.notify("toolbar")
        if Self.showToolbar { pokeControls() }
    }

    @objc func navigateForward(_ sender: Any?) { navigate(1) }
    @objc func navigateBackward(_ sender: Any?) { navigate(-1) }
    @objc func goFirst(_ sender: Any?) { goTo(0) }
    @objc func goLast(_ sender: Any?) { goTo(max(folder.count - 1, 0)) }

    @objc func showShortcuts(_ sender: Any?) {
        SettingsWindowController.shared.show(.shortcuts)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// 自定义快捷键里那些看图界面不直接处理的操作（改成单键后菜单不再接管，由这里转发）
    private func perform(_ action: ShortcutAction) {
        switch action {
        case .edit: openInEditor(nil)
        case .reveal: revealInFinder(nil)
        case .exportAs: exportAs(nil)
        case .saveRotation: saveRotation(nil)
        case .cleanup: if folder.count > 0 { toggleCleanup(nil) }
        case .batchConvert: batchConvert(nil)
        case .batchRename: batchRename(nil)
        case .wallpaper: setWallpaper(nil)
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5: setRating(action.stars ?? 0)
        case .mark: toggleMark(nil)
        case .markedOnly: toggleMarkedOnly(nil)
        case .compare: toggleCompare(nil)
        case .compare4: toggleCompare4(nil)
        case .comparePane: compareCyclePane()
        case .compareSync: toggleCompareSync(nil)
        case .exportFolder: exportToFolder(nil)
        default: break
        }
    }

    @objc private func settingsDidChange(_ note: Notification) {
        switch note.userInfo?["what"] as? String {
        case "sort":
            applySort()
            loadCaptureDatesIfNeeded()
        case "slideshow":
            if slideshowTimer != nil { scheduleSlideshowTimer() }
        case "rating":
            updateRatingLabel()
        case "toolbar":
            toolbarView.isHidden = !Self.showToolbar || folder.current == nil || !controlsVisible
            toolbarView.alphaValue = toolbarView.isHidden ? 0 : 1
            ratingBadgeBottom.constant = ratingBadgeOffset(controls: controlsVisible)
        case "thumbs":
            // 缩略图大小变了：格子、栏高一起改，按新尺寸重新取缩略图
            filmstrip.applyThumbSize()
            if filmstripHeight.constant > 0 { filmstripHeight.constant = FilmstripView.stripHeight }
            ratingBadgeBottom.constant = ratingBadgeOffset(controls: controlsVisible)
            filmstrip.collectionView.reloadData()
            syncFilmstripSelection()
            if imageView.isFit { imageView.fit() }
        case "hdr":
            // 解码方式变了，缓存里的图作废，当前这张重新解码
            loader.purge()
            showImage(resetToFit: false)
        default: break
        }
    }

    /// 工具条按钮的提示跟着自定义快捷键走
    private var shortcutTips: [(button: NSButton, base: String, action: ShortcutAction)] = []

    @objc private func refreshShortcutTips() {
        for t in shortcutTips { t.button.toolTip = Shortcuts.tooltip(t.base, t.action) }
    }

    private static func shortcutAction(for selector: Selector) -> ShortcutAction? {
        switch selector {
        case #selector(navigateBackward(_:)): return .prev
        case #selector(navigateForward(_:)): return .next
        case #selector(zoomIn(_:)): return .zoomIn
        case #selector(zoomOut(_:)): return .zoomOut
        case #selector(zoomActual(_:)): return .actualSize
        case #selector(rotateCCW(_:)): return .rotateCCW
        case #selector(rotateCW(_:)): return .rotateCW
        case #selector(toggleSlideshow(_:)): return .slideshow
        case #selector(toggleInfoPanel(_:)): return .info
        case #selector(toggleFilmstrip(_:)): return .filmstrip
        case #selector(exportAs(_:)): return .exportAs
        case #selector(exportToFolder(_:)): return .exportFolder
        case #selector(renameCurrent(_:)): return .rename
        case #selector(trashCurrent(_:)): return .trash
        default: return nil
        }
    }

    // MARK: - 清理模式

    @objc func toggleCleanup(_ sender: Any?) {
        exitCompare()
        if let cleanup {
            cleanup.finish(nil)
            return
        }
        guard let current = folder.current else { return }
        stopSlideshow()
        imageView.endPeek()
        if folder.markedOnly { toggleMarkedOnly(nil) }
        let folderURL = current.url.deletingLastPathComponent()
        let c = CleanupController(folderURL: folderURL, items: folder.items) { [weak self] changed in
            self?.exitCleanup(changed: changed, folderURL: folderURL)
        }
        addChild(c)
        c.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(c.view)
        NSLayoutConstraint.activate([
            c.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            c.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            c.view.topAnchor.constraint(equalTo: view.topAnchor),
            c.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        cleanup = c
        view.window?.makeFirstResponder(c.grid)
    }

    private func exitCleanup(changed: Bool, folderURL: URL) {
        guard let c = cleanup else { return }
        c.view.removeFromSuperview()
        c.removeFromParent()
        cleanup = nil
        if changed {
            // 删过照片：重新列目录，尽量停在原来那张
            let cur = folder.current?.url
            let keep = cur.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            open(url: keep ?? folderURL)
        }
        view.window?.makeFirstResponder(imageView)
    }

    /// 第一次打开 50 张以上的文件夹时提示一次清理模式
    private func showCleanupHintIfNeeded() {
        let key = "cleanupHintShown"
        guard folder.count >= 50, !UserDefaults.standard.bool(forKey: key),
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.flash(L10n.t("cleanup.tip", "照片很多？⌘⇧K 进入清理模式，找出重复、闭眼和模糊的照片"), seconds: 6)
        }
    }

    // MARK: - HUD 临时提示

    private func flash(_ msg: String, seconds: Double = 2) {
        isFlashing = true
        hudNameLabel.stringValue = msg
        hudDimsLabel.isHidden = true
        hudExifLabel1.isHidden = true
        hudExifLabel2.isHidden = true
        hudView.isHidden = false
        flashItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isFlashing = false
            self?.updateHUD()
        }
        flashItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - 旋转

    @objc func rotateCW(_ sender: Any?) {
        imageView.rotate(clockwise: 1)
        flash(L10n.t("msg.rotHint", "已旋转视图 · ⌘⌥S 可保存到文件"))
    }

    @objc func rotateCCW(_ sender: Any?) {
        imageView.rotate(clockwise: -1)
        flash(L10n.t("msg.rotHint", "已旋转视图 · ⌘⌥S 可保存到文件"))
    }

    // MARK: - 幻灯片放映

    /// 放映中暂停：计时器停掉但仍在放映状态（全屏、缩略图栏自动隐藏），可以翻页、打星，再点一下继续
    private var slideshowPaused = false
    private var slideshowActive: Bool { slideshowTimer != nil || slideshowPaused }

    private func toggleSlideshowPause() {
        guard slideshowActive else { return }
        if slideshowPaused {
            slideshowPaused = false
            scheduleSlideshowTimer()
            flash(L10n.t("msg.slideResumed", "继续播放"))
        } else {
            slideshowTimer?.invalidate()
            slideshowTimer = nil
            slideshowPaused = true
            flash(L10n.t("msg.slidePaused", "已暂停 · 点一下继续"), seconds: 2.5)
        }
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        exitCompare()
        if slideshowActive {
            stopSlideshow()
        } else {
            startSlideshow()
        }
    }

    private func startSlideshow() {
        guard folder.count > 1 else {
            flash(L10n.t("msg.oneImage", "文件夹里只有一张图片"))
            return
        }
        if let window = view.window, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(window)
        }
        scheduleSlideshowTimer()
        updateSlideshowButton()
        setFilmstripFloating(true)
        flash(L10n.f("msg.slideshowOnN", "幻灯片放映中 · 每张 %d 秒 · S 或退出全屏停止", slideshowInterval), seconds: 3)
    }

    static let slideshowIntervals = [1, 2, 3, 5, 10]
    static let slideshowFadeDurations: [Double] = [0.5, 1, 1.5, 2, 3]

    /// 幻灯片切换时渐变：和手动翻页的「翻页渐变」分开，默认开，默认 1 秒
    static var slideshowFade: Bool {
        get { !UserDefaults.standard.bool(forKey: "slideshowFadeOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "slideshowFadeOff") }
    }

    static var slideshowFadeDuration: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "slideshowFadeDuration")
            return slideshowFadeDurations.contains(v) ? v : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: "slideshowFadeDuration") }
    }

    private var advancingSlideshow = false

    /// 每张停留秒数，跨启动记住，默认 3 秒
    private var slideshowInterval: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "slideshowInterval")
            return Self.slideshowIntervals.contains(v) ? v : 3
        }
        set { UserDefaults.standard.set(newValue, forKey: "slideshowInterval") }
    }

    private func scheduleSlideshowTimer() {
        slideshowTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(slideshowInterval), repeats: true) { [weak self] _ in
            guard let self else { return }
            // 渐变不超过间隔的 80%，免得上一张还没淡完下一张就来了
            if Self.slideshowFade {
                self.imageView.pendingFadeDuration = min(Self.slideshowFadeDuration, Double(self.slideshowInterval) * 0.8)
            }
            if BenchProbe.traceNav { NSLog("TRACE slideshow tick interval=%d", self.slideshowInterval) }
            self.advancingSlideshow = true
            self.navigate(1)
            self.advancingSlideshow = false
        }
        RunLoop.main.add(timer, forMode: .common)
        slideshowTimer = timer
    }

    @objc func setSlideshowInterval(_ sender: NSMenuItem) {
        slideshowInterval = sender.tag
        // 放映中改间隔立即生效
        if slideshowTimer != nil { scheduleSlideshowTimer() }
        flash(L10n.f("msg.slideInterval", "幻灯片间隔：每张 %d 秒", sender.tag))
    }

    private var filmstripFloating = false

    /// 放映时缩略图栏改成浮在图片上、随控件自动隐藏；停止放映后回到原位
    private func setFilmstripFloating(_ floating: Bool) {
        guard floating != filmstripFloating else { return }
        filmstripFloating = floating
        if floating {
            imageAboveFilmstrip.isActive = false
            imageToBottom.isActive = true
        } else {
            imageToBottom.isActive = false
            imageAboveFilmstrip.isActive = true
            filmstrip.alphaValue = 1
            filmstrip.isHidden = filmstripHeight.constant == 0
        }
        ratingBadgeBottom.constant = ratingBadgeOffset(controls: controlsVisible)
        view.layoutSubtreeIfNeeded()
        imageView.fit()
        pokeControls()
    }

    private func stopSlideshow() {
        guard slideshowActive else { return }
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        slideshowPaused = false
        updateSlideshowButton()
        setFilmstripFloating(false)
        flash(L10n.t("msg.slideshowOff", "已停止幻灯片放映"))
    }

    @objc private func windowDidExitFullScreen(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        stopSlideshow()
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        stopSlideshow()
    }

    // MARK: - 交给后期软件

    /// 设好的后期软件；被删了就当没设
    static var storedEditorAppURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "editorAppPath"),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "editorAppPath") }
    }
    private var editorAppURL: URL? {
        get { Self.storedEditorAppURL }
        set { Self.storedEditorAppURL = newValue }
    }

    /// 中文句子里夹英文名时两侧加空格（在 Photoshop 中编辑），中文名不加（在预览中编辑）
    private static func spaced(_ name: String) -> String {
        guard L10n.t("menu.editIn", "在%@中编辑").hasPrefix("在"), name.contains(where: { $0.isASCII && $0.isLetter }) else { return name }
        return " \(name) "
    }

    private static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// 交给后期软件的文件：当前是 JPG 等、同名 RAW 也在时用 RAW，后期一般修 RAW
    private func editTargetURL() -> URL? {
        guard let url = folder.current?.url else { return nil }
        if CleanupUnit.isRaw(url) { return url }
        let base = url.deletingPathExtension()
        for ext in CleanupUnit.rawExtensions.sorted() {
            for candidate in [base.appendingPathExtension(ext), base.appendingPathExtension(ext.uppercased())]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return url
    }

    private func open(_ file: URL, with app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.flash(L10n.f("msg.openFailed", "无法用 %1$@ 打开：%2$@", Self.appName(app), error.localizedDescription), seconds: 4)
                } else {
                    self?.flash(L10n.f("msg.openedIn", "已用 %1$@ 打开 %2$@", Self.appName(app), file.lastPathComponent))
                }
            }
        }
    }

    /// ⌘E：用设好的后期软件打开当前照片；还没设就先选一个
    @objc func openInEditor(_ sender: Any?) {
        guard let file = editTargetURL() else { return }
        if let app = editorAppURL {
            open(file, with: app)
        } else {
            pickApplication { [weak self] app in
                self?.editorAppURL = app
                self?.open(file, with: app)
            }
        }
    }

    @objc func chooseEditor(_ sender: Any?) {
        pickApplication { [weak self] app in
            self?.editorAppURL = app
            self?.flash(L10n.f("msg.editorSet", "后期软件：%@ · ⌘E 打开当前照片", Self.appName(app)), seconds: 3)
        }
    }

    private func pickApplication(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L10n.t("panel.chooseEditor", "选择后期软件")
        panel.prompt = L10n.t("panel.choose", "选择")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { done(url) }
        }
    }

    /// 打开方式：当前照片能用哪些软件打开，默认软件排第一，设好的后期软件打勾
    func populateOpenWithMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard cleanup == nil, let file = editTargetURL() else { return }
        let ws = NSWorkspace.shared
        let defaultApp = ws.urlForApplication(toOpen: file)
        var apps = ws.urlsForApplications(toOpen: file)
            .filter { $0.lastPathComponent != Bundle.main.bundleURL.lastPathComponent }
        var seen = Set<String>()
        apps = apps.filter { seen.insert(Self.appName($0)).inserted }
            .sorted { a, b in
                if a == defaultApp { return true }
                if b == defaultApp { return false }
                return Self.appName(a).localizedStandardCompare(Self.appName(b)) == .orderedAscending
            }
        for app in apps {
            let it = NSMenuItem(title: Self.appName(app), action: #selector(openWithMenuItem(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = app
            let icon = ws.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            it.image = icon
            if app.path == editorAppURL?.path { it.state = .on }
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: L10n.t("menu.openWithOther", "其他…"), action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
    }

    @objc private func openWithMenuItem(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let file = editTargetURL() else { return }
        open(file, with: app)
    }

    @objc private func openWithOther(_ sender: Any?) {
        guard let file = editTargetURL() else { return }
        pickApplication { [weak self] app in self?.open(file, with: app) }
    }

    /// 图片上的右键菜单：交给后期软件、打开方式，以及常用的几项
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        add(L10n.t("menu.editChoose", "在后期软件中编辑…"), #selector(openInEditor(_:)))
        let openWith = NSMenuItem(title: L10n.t("menu.openWith", "打开方式"), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: openWith.title)
        sub.delegate = self
        openWith.submenu = sub
        menu.addItem(openWith)
        menu.addItem(.separator())
        let rating = NSMenuItem(title: L10n.t("menu.rating", "评分"), action: nil, keyEquivalent: "")
        let ratingMenu = buildRatingMenu()
        for it in ratingMenu.items { it.target = self }
        rating.submenu = ratingMenu
        menu.addItem(rating)
        add(Self.markMenuTitle(folder.current?.marked ?? false), #selector(toggleMark(_:)))
        add(L10n.t("menu.markedOnly", "只看已标记"), #selector(toggleMarkedOnly(_:)))
        add(L10n.t("menu.exportFolder", "导出到文件夹…"), #selector(exportToFolder(_:)))
        menu.addItem(.separator())
        add(L10n.t("menu.reveal", "在 Finder 中显示"), #selector(revealInFinder(_:)))
        add(L10n.t("menu.trash", "移到废纸篓"), #selector(trashCurrent(_:)))
        return menu
    }

    // MARK: - 评分

    /// 读过的评分；写入后同步更新，避免每次翻页都去读文件
    private var ratingCache: [URL: Int] = [:]
    private let ratingQueue = DispatchQueue(label: "flipic.rating", qos: .userInitiated)

    var currentRating: Int { folder.current.flatMap { ratingCache[$0.url] } ?? 0 }

    private func loadRating(for url: URL) {
        if ratingCache[url] != nil { updateRatingLabel(); return }
        updateRatingLabel()
        ratingQueue.async { [weak self] in
            let r = Rating.read(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.ratingCache[url] = r
                self.folder.setRating(r, url: url)
                if self.folder.current?.url == url { self.updateRatingLabel() }
            }
        }
    }

    /// 同名的 RAW 和 JPG 当成一张照片，一起打分
    private func ratingTargets(for url: URL) -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        let siblings = folder.allItems.map(\.url).filter {
            $0 != url && $0.deletingLastPathComponent() == dir && $0.deletingPathExtension().lastPathComponent == base
        }
        return [url] + siblings
    }

    func setRating(_ stars: Int) {
        guard cleanup == nil, let url = folder.current?.url else { return }
        let targets = ratingTargets(for: url)
        for t in targets {
            ratingCache[t] = stars
            folder.setRating(stars, url: t)
        }
        updateRatingLabel()
        flash(stars == 0 ? L10n.t("rating.cleared", "已取消评分") : Rating.stars(stars), seconds: 1.2)
        if !exifPanel.isHidden { updateExifPanel() }
        ratingQueue.async { [weak self] in
            let failed = targets.filter { !Rating.write(stars, to: $0) }
            guard !failed.isEmpty else { return }
            DispatchQueue.main.async {
                for t in failed {
                    self?.ratingCache[t] = nil
                    self?.folder.setRating(nil, url: t)
                }
                self?.updateRatingLabel()
                self?.flash(L10n.f("rating.failed", "评分没能写入：%@", failed.map(\.lastPathComponent).joined(separator: "、")), seconds: 4)
            }
        }
    }

    @objc func setRatingMenu(_ sender: NSMenuItem) { setRating(sender.tag) }

    /// 工具条左侧的星星：随控件一起出现，没评分不显示
    private let ratingLabel = NSTextField(labelWithString: "")

    /// 底部居中常驻的星级：评过分的照片一直显示。工具条出来时它往上让到工具条上方，工具条隐藏后落回原位；
    /// 设置里可以关掉，关掉后改在工具条里显示
    private let ratingBadge = NSVisualEffectView()
    private var ratingBadgeBottom: NSLayoutConstraint!

    private func ratingBadgeOffset(controls: Bool) -> CGFloat {
        if controls && Self.showToolbar { return -(8 + max(toolbarView.fittingSize.height, 44) + 8) }
        // 放映时缩略图栏隐藏了，星级落到屏幕底部
        return filmstripFloating ? filmstripHeight.constant - 14 : -14
    }
    private let ratingBadgeLabel = NSTextField(labelWithString: "")

    /// 移动鼠标时显示底部工具条；关掉后只用快捷键和菜单，左右翻页箭头照常出现
    static var showToolbar: Bool {
        get { !UserDefaults.standard.bool(forKey: "toolbarHidden") }
        set { UserDefaults.standard.set(!newValue, forKey: "toolbarHidden") }
    }

    static var showRatingBadge: Bool {
        get { !UserDefaults.standard.bool(forKey: "ratingBadgeHidden") }
        set { UserDefaults.standard.set(!newValue, forKey: "ratingBadgeHidden") }
    }

    private func buildRatingBadge() {
        ratingBadge.material = .hudWindow
        ratingBadge.blendingMode = .withinWindow
        ratingBadge.state = .active
        ratingBadge.wantsLayer = true
        ratingBadge.layer?.cornerRadius = 8
        ratingBadge.layer?.masksToBounds = true
        ratingBadge.translatesAutoresizingMaskIntoConstraints = false
        ratingBadge.isHidden = true
        ratingBadgeLabel.font = .systemFont(ofSize: 16, weight: .medium)
        ratingBadgeLabel.textColor = Self.starColor
        ratingBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        ratingBadge.addSubview(ratingBadgeLabel)
        NSLayoutConstraint.activate([
            ratingBadgeLabel.leadingAnchor.constraint(equalTo: ratingBadge.leadingAnchor, constant: 10),
            ratingBadgeLabel.trailingAnchor.constraint(equalTo: ratingBadge.trailingAnchor, constant: -10),
            ratingBadgeLabel.topAnchor.constraint(equalTo: ratingBadge.topAnchor, constant: 5),
            ratingBadgeLabel.bottomAnchor.constraint(equalTo: ratingBadge.bottomAnchor, constant: -5),
        ])
        view.addSubview(ratingBadge)
        buildMarkBadge()
        buildMarkedOnlyPill()
    }

    static let starColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.25, alpha: 1)

    private func updateRatingLabel() {
        let r = currentRating
        let badge = Self.showRatingBadge
        ratingBadgeLabel.stringValue = String(repeating: "★", count: r)
        ratingBadge.isHidden = r == 0 || !badge || peekSaved != nil || cleanup != nil || compareView != nil
        // 刚出现时按当前工具条状态放，免得工具条正显示着却落在它下面
        if !ratingBadge.isHidden { ratingBadgeBottom.constant = ratingBadgeOffset(controls: controlsVisible) }
        // 标记固定在左下角，不随工具条移动，也不受「底部显示星级」开关影响
        markBadge.isHidden = !(folder.current?.marked ?? false) || peekSaved != nil || cleanup != nil || compareView != nil
        if compareView != nil { refreshCompareInfo() }
        markBadgeBottom.constant = ratingBadgeOffset(controls: false)
        ratingLabel.stringValue = Rating.stars(r)
        ratingLabel.isHidden = r == 0 || badge
    }

    /// 「评分」子菜单：5 星到 1 星，最后是未评分，当前评分打勾
    func buildRatingMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.t("menu.rating", "评分"))
        for n in stride(from: 5, through: 1, by: -1) {
            let it = NSMenuItem(title: Rating.stars(n), action: #selector(setRatingMenu(_:)), keyEquivalent: "")
            it.tag = n
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let none = NSMenuItem(title: L10n.t("rating.none", "未评分"), action: #selector(setRatingMenu(_:)), keyEquivalent: "")
        none.tag = 0
        menu.addItem(none)
        return menu
    }

    // MARK: - 挑片标记

    static let markColor = NSColor(calibratedRed: 0.3, green: 0.82, blue: 0.45, alpha: 1)
    /// 左下角的绿色勾：这张标记过。放在角上不挡照片中间和工具条
    private let markBadge = NSVisualEffectView()
    private var markBadgeBottom: NSLayoutConstraint!

    private func buildMarkBadge() {
        markBadge.material = .hudWindow
        markBadge.blendingMode = .withinWindow
        markBadge.state = .active
        markBadge.wantsLayer = true
        markBadge.layer?.cornerRadius = 8
        markBadge.layer?.masksToBounds = true
        markBadge.translatesAutoresizingMaskIntoConstraints = false
        markBadge.isHidden = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = Self.markColor
        let text = NSTextField(labelWithString: L10n.t("ui.marked", "已标记"))
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = .labelColor
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        markBadge.addSubview(stack)
        view.addSubview(markBadge)
        markBadgeBottom = markBadge.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -14)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: markBadge.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: markBadge.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: markBadge.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: markBadge.bottomAnchor, constant: -5),
            markBadge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            markBadgeBottom,
        ])
    }

    static func markMenuTitle(_ marked: Bool) -> String {
        marked ? L10n.t("menu.unmark", "取消标记") : L10n.t("menu.mark", "标记这张")
    }

    /// 标记 / 取消标记当前照片；同名的 RAW 和 JPG 一起标
    @objc func toggleMark(_ sender: Any?) {
        guard cleanup == nil, let item = folder.current else { return }
        let on = !item.marked
        let targets = ratingTargets(for: item.url)
        for t in targets { folder.setMarked(on, url: t) }
        refreshMarks()
        let count = folder.markedCount
        flash(on ? L10n.f("msg.marked", "已标记 · 共 %d 张", count) : L10n.f("msg.unmarked", "已取消标记 · 共 %d 张", count),
              seconds: 1.2)
        ratingQueue.async { [weak self] in
            let failed = targets.filter { !Marks.set(on, for: $0) }
            guard !failed.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for t in failed { self.folder.setMarked(!on, url: t) }
                self.refreshMarks()
                self.flash(L10n.f("msg.markFailed", "标记没能写入：%@", failed.map(\.lastPathComponent).joined(separator: "、")), seconds: 4)
            }
        }
    }

    /// 只看已标记 / 显示全部
    @objc func toggleMarkedOnly(_ sender: Any?) {
        guard cleanup == nil, folder.totalCount > 0 else { return }
        exitCompare()
        let on = !folder.markedOnly
        guard folder.setMarkedOnly(on) else {
            let key = Shortcuts.combo(for: .mark)?.display
            flash(key.map { L10n.f("msg.noMarks", "还没有标记的照片，看图时按 %@ 标记", $0) }
                  ?? L10n.t("msg.noMarksMenu", "还没有标记的照片"), seconds: 2.5)
            return
        }
        filterDidChange()
    }

    /// 筛选条件变了：重建缩略图栏、显示符合条件的那张，顶部计数跟着变
    private func filterDidChange() {
        prefetchedURLs.removeAll()
        filmstrip.collectionView.reloadData()
        filmstrip.scrollTo(index: folder.index)
        showImage(resetToFit: true)
        updateMarkedOnlyPill()
        // 进入筛选时顶部的计数已经说明了，退出时才提示一下
        if folder.filter == nil { flash(L10n.f("msg.markedOnlyOff", "显示全部 %d 张", folder.count), seconds: 1.5) }
    }

    /// 「只看星级」菜单：tag 是最低星级，0 是全部；再选一次同一档回到全部
    @objc func setRatingFilter(_ sender: NSMenuItem) { applyRatingFilter(sender.tag) }

    func applyRatingFilter(_ n: Int, done: (() -> Void)? = nil) {
        guard cleanup == nil, folder.totalCount > 0 else { return }
        exitCompare()
        if n == 0 || folder.filter == .minRating(n) {
            if folder.filter != nil, folder.setFilter(nil) { filterDidChange() }
            done?()
            return
        }
        let finish = { [weak self] in
            guard let self else { return }
            guard self.folder.setFilter(.minRating(n)) else {
                self.flash(L10n.f("msg.noRatingMatch", "没有%@及以上的照片", Rating.stars(n).replacingOccurrences(of: "☆", with: "")), seconds: 2.5)
                done?()
                return
            }
            self.filterDidChange()
            done?()
        }
        let missing = folder.urlsMissingRating
        guard !missing.isEmpty else { finish(); return }
        // 星级只在翻到某张时才读，筛选前把整个文件夹的都读一遍（只读元数据，很快）
        if missing.count > 40 { flash(L10n.t("msg.readingRatings", "正在读取评分…"), seconds: 5) }
        let gen = folderGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var values = [Int](repeating: 0, count: missing.count)
            values.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: missing.count) { i in buf[i] = Rating.read(missing[i]) }
            }
            DispatchQueue.main.async {
                guard let self, self.folderGeneration == gen else { return }
                for (u, r) in zip(missing, values) {
                    self.folder.setRating(r, url: u)
                    self.ratingCache[u] = r
                }
                finish()
            }
        }
    }

    /// 标记变了以后刷新底部徽章、缩略图上的勾和顶部计数，不重建缩略图栏
    private func refreshMarks() {
        updateRatingLabel()
        for case let cell as FilmstripItem in filmstrip.collectionView.visibleItems()
        where folder.items.indices.contains(cell.itemIndex) {
            cell.setMarked(folder.items[cell.itemIndex].marked)
        }
        updateMarkedOnlyPill()
    }

    /// 「只看已标记」时顶部居中的计数，点一下回到显示全部
    private let markedOnlyPill = NSVisualEffectView()
    private let markedOnlyLabel = NSTextField(labelWithString: "")
    private let markedOnlyPillIcon = NSImageView()

    private func buildMarkedOnlyPill() {
        markedOnlyPill.material = .hudWindow
        markedOnlyPill.blendingMode = .withinWindow
        markedOnlyPill.state = .active
        markedOnlyPill.wantsLayer = true
        markedOnlyPill.layer?.cornerRadius = 8
        markedOnlyPill.layer?.masksToBounds = true
        markedOnlyPill.translatesAutoresizingMaskIntoConstraints = false
        markedOnlyPill.isHidden = true
        let icon = markedOnlyPillIcon
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = Self.markColor
        markedOnlyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        markedOnlyLabel.textColor = .labelColor
        let close = NSButton(title: L10n.t("ui.showAll", "显示全部"), target: self, action: #selector(clearFilter(_:)))
        close.isBordered = false
        close.font = .systemFont(ofSize: 12)
        close.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, markedOnlyLabel, close])
        stack.spacing = 6
        stack.setCustomSpacing(12, after: markedOnlyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        markedOnlyPill.addSubview(stack)
        view.addSubview(markedOnlyPill)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: markedOnlyPill.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: markedOnlyPill.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: markedOnlyPill.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: markedOnlyPill.bottomAnchor, constant: -5),
            markedOnlyPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            markedOnlyPill.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
    }

    @objc func clearFilter(_ sender: Any?) {
        if folder.filter != nil, folder.setFilter(nil) { filterDidChange() }
    }

    private func updateMarkedOnlyPill() {
        markedOnlyPill.isHidden = folder.filter == nil || cleanup != nil
        switch folder.filter {
        case .minRating(let n):
            markedOnlyPillIcon.isHidden = true
            markedOnlyLabel.stringValue = L10n.f("ui.ratingPill", "只看%1$@及以上 · %2$d / %3$d",
                                                 String(repeating: "★", count: n), folder.matchingCount, folder.totalCount)
        default:
            markedOnlyPillIcon.isHidden = false
            markedOnlyLabel.stringValue = L10n.f("ui.markedOnlyPill", "只看已标记 · %1$d / %2$d",
                                                 folder.markedCount, folder.totalCount)
        }
    }

    // MARK: - 导出到文件夹

    /// 复制还是移动，记住上次的选择
    static var exportFolderMoves: Bool {
        get { UserDefaults.standard.bool(forKey: "exportFolderMoves") }
        set { UserDefaults.standard.set(newValue, forKey: "exportFolderMoves") }
    }

    /// 测试用：跳过选文件夹的面板，直接导出到这里
    var debugExportTarget: URL?

    /// 把当前显示的照片（筛选中就是筛出来的那些）复制或移动到一个文件夹
    @objc func exportToFolder(_ sender: Any?) {
        guard folder.count > 0, !isProcessing, let source = folder.current?.url.deletingLastPathComponent() else { return }
        exitCompare()
        let urls = folder.items.map(\.url)
        if let target = debugExportTarget {
            runFolderExport(urls, to: target, from: source, move: Self.exportFolderMoves)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("exp.f.prompt", "导出到这里")
        panel.message = exportSummary(count: urls.count)
        let copy = NSButton(radioButtonWithTitle: L10n.t("exp.f.copy", "复制（原文件留在这里）"), target: nil, action: nil)
        let move = NSButton(radioButtonWithTitle: L10n.t("exp.f.move", "移动（从这里移走）"), target: nil, action: nil)
        copy.state = Self.exportFolderMoves ? .off : .on
        move.state = Self.exportFolderMoves ? .on : .off
        // 两个单选按钮共用同一个 action 才会互斥
        copy.action = #selector(exportModeChanged(_:)); copy.target = self
        move.action = #selector(exportModeChanged(_:)); move.target = self
        let row = NSStackView(views: [copy, move])
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .OK, let target = panel.url else { return }
            Self.exportFolderMoves = move.state == .on
            self.runFolderExport(urls, to: target, from: source, move: move.state == .on)
        }
    }

    @objc private func exportModeChanged(_ sender: NSButton) {}

    private func exportSummary(count: Int) -> String {
        switch folder.filter {
        case .marked: return L10n.f("exp.f.summaryMarked", "导出当前显示的 %d 张照片（已标记的）", count)
        case .minRating(let n): return L10n.f("exp.f.summaryRating", "导出当前显示的 %1$d 张照片（%2$@及以上）", count, String(repeating: "★", count: n))
        case nil: return L10n.f("exp.f.summaryAll", "导出当前显示的 %d 张照片（整个文件夹）", count)
        }
    }

    /// 同名的一组文件（比如 RAW 的星级旁车 .xmp）一起走，用同一个新名字；目标里已有同名文件时加编号，不覆盖
    private func runFolderExport(_ urls: [URL], to target: URL, from source: URL, move: Bool) {
        guard target.standardizedFileURL.path != source.standardizedFileURL.path else {
            flash(L10n.t("msg.exportSameFolder", "目标就是当前文件夹，换一个文件夹"), seconds: 3)
            return
        }
        isProcessing = true
        let fm = FileManager.default
        var groups: [(base: String, files: [URL])] = []
        var groupIndex: [String: Int] = [:]
        for u in urls {
            let base = u.deletingPathExtension().lastPathComponent
            var files = [u]
            let side = Rating.sidecarURL(for: u)
            if fm.fileExists(atPath: side.path) { files.append(side) }
            if let gi = groupIndex[base] {
                for f in files where !groups[gi].files.contains(f) { groups[gi].files.append(f) }
            } else {
                groupIndex[base] = groups.count
                groups.append((base, files))
            }
        }
        let total = urls.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done = Set<URL>()
            var failed = 0
            var processed = 0
            for g in groups {
                // 找一个这组所有扩展名都不冲突的名字：base、base 2、base 3…
                var name = g.base
                var n = 1
                while g.files.contains(where: { fm.fileExists(atPath: target.appendingPathComponent(name).appendingPathExtension($0.pathExtension).path) }) {
                    n += 1
                    name = "\(g.base) \(n)"
                }
                for f in g.files {
                    let dest = target.appendingPathComponent(name).appendingPathExtension(f.pathExtension)
                    do {
                        if move { try fm.moveItem(at: f, to: dest) } else { try fm.copyItem(at: f, to: dest) }
                        if urls.contains(f) { done.insert(f) }
                    } catch {
                        if urls.contains(f) { failed += 1 }
                    }
                }
                processed += g.files.filter { urls.contains($0) }.count
                if total > 30, processed % 20 == 0 {
                    let p = processed
                    DispatchQueue.main.async { self?.flash(L10n.f("msg.exporting", "正在处理 %1$d / %2$d", p, total), seconds: 5) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                let folderName = target.lastPathComponent
                var msg = move ? L10n.f("msg.exportedMove", "已移动 %1$d 张到「%2$@」", done.count, folderName)
                               : L10n.f("msg.exportedCopy", "已复制 %1$d 张到「%2$@」", done.count, folderName)
                if failed > 0 { msg += " · " + L10n.f("msg.exportFailed", "%d 个文件没能处理", failed) }
                if move, !done.isEmpty {
                    for u in done { self.loader.evict(url: u) }
                    self.folder.remove(urls: done)
                    self.prefetchedURLs.removeAll()
                    self.filmstrip.collectionView.reloadData()
                    if self.folder.count > 0 {
                        self.showImage(resetToFit: true)
                    } else if self.folder.filter != nil, self.folder.setFilter(nil), self.folder.count > 0 {
                        // 筛出来的都移走了，回到剩下的全部照片
                        self.filmstrip.collectionView.reloadData()
                        self.showImage(resetToFit: true)
                    } else {
                        self.imageView.set(image: nil, resetToFit: true, isNew: true)
                        self.emptyState.isHidden = false
                        self.updateControlsPresence()
                        self.emptyHint.stringValue = L10n.t("ui.noMore", "文件夹里没有更多图片了")
                    }
                    self.updateMarkedOnlyPill()
                }
                self.flash(msg, seconds: 3.5)
            }
        }
    }

    // MARK: - 并排对比

    /// 非 nil 时在并排对比：2 格或 4 格，各格缩放和位置同步，当前格的照片就是 folder.current
    private var compareView: CompareView?
    private var compareActive = 0
    /// 最后一次缩放 / 拖动后的状态；换图的格子照着它摆，nil 表示适应窗口
    private var compareState: ZoomableImageView.ViewState?
    private var compareRatingPending = Set<URL>()
    /// 换图时格子会先回到适应窗口，这个过程不同步给别的格
    private var compareLoading = false
    /// 关掉后各格单独缩放和拖动（⇧L 切换）
    private var compareSynced = true
    /// 测试用：当作按住了 ⌥
    private var debugOptionHeld = false

    @objc func toggleCompare(_ sender: Any?) {
        if let cv = compareView, cv.panes.count == 2 { exitCompare() } else { enterCompare(2) }
    }

    @objc func toggleCompare4(_ sender: Any?) {
        if let cv = compareView, cv.panes.count >= 3 { exitCompare() } else { enterCompare(4) }
    }

    private func enterCompare(_ want: Int) {
        guard cleanup == nil, folder.count >= 2 else {
            flash(L10n.t("msg.compareNeedsTwo", "至少要两张照片才能并排对比"))
            return
        }
        if slideshowActive { stopSlideshow() }
        imageView.endPeek()
        let n = min(want, folder.count)
        let cv: CompareView
        if let existing = compareView {
            cv = existing
        } else {
            cv = CompareView()
            cv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cv, positioned: .above, relativeTo: imageView)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
                cv.topAnchor.constraint(equalTo: imageView.topAnchor),
                cv.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            ])
            compareView = cv
            compareState = nil
            imageView.isHidden = true
            controlsHideTimer?.invalidate()
            setControlsVisible(false)
        }
        // 已有的格子保持原样，新加的格子接着往后放还没出现过的照片
        var used = cv.panes.map(\.photoIndex)
        let startCount = cv.panes.count
        cv.setPaneCount(n)
        cv.layoutSubtreeIfNeeded()
        var next = startCount == 0 ? folder.index : (used.max() ?? folder.index) + 1
        for i in startCount..<n {
            while used.contains(next % folder.count) { next += 1 }
            let idx = next % folder.count
            used.append(idx)
            configurePane(cv.panes[i], at: i)
            loadPane(cv.panes[i], index: idx)
            next += 1
        }
        // 两格时右边是「候选」，← → 换它，左边留着做参照
        compareActivate(startCount == 0 ? (n == 2 ? 1 : 0) : min(compareActive, n - 1))
        updateRatingLabel()
    }

    func exitCompare() {
        guard let cv = compareView else { return }
        cv.removeFromSuperview()
        compareView = nil
        compareState = nil
        compareSynced = true
        imageView.isHidden = false
        showImage(resetToFit: true)
        view.window?.makeFirstResponder(imageView)
        updateRatingLabel()
        pokeControls()
    }

    private func configurePane(_ pane: ComparePane, at i: Int) {
        let iv = pane.imageView
        iv.onMouseDown = { [weak self] in self?.compareActivate(i) }
        iv.onNavigate = { [weak self] d in
            self?.compareActivate(i)
            self?.compareNavigate(d)
        }
        iv.onEscape = { [weak self] in self?.exitCompare() }
        iv.onCommand = { [weak self] action in self?.perform(action) }
        iv.onToggleFilmstrip = { [weak self] in self?.toggleFilmstrip(nil) }
        iv.onToggleInfo = { [weak self] in self?.toggleInfoPanel(nil) }
        iv.onToggleFullscreen = { [weak self] in
            guard let window = self?.view.window else { return }
            window.toggleFullScreen(window)
        }
        iv.onViewChange = { [weak self, weak pane] state, animated in
            guard let self, let pane, let cv = self.compareView, !self.compareLoading, self.compareSynced else { return }
            if NSEvent.modifierFlags.contains(.option) || self.debugOptionHeld {
                // 按住 ⌥：只动这一格，记下它和大家的差；都还在适应窗口时没有可对齐的位置，不记
                if let base = self.compareState, !state.fit {
                    pane.zoomRatio = state.zoom / base.zoom
                    pane.centerDelta = CGPoint(x: state.center.x - base.center.x, y: state.center.y - base.center.y)
                } else {
                    pane.resetAdjustment()
                }
                self.refreshCompareInfo()
                return
            }
            if state.fit {
                self.compareState = nil
                for other in cv.panes where other !== pane { other.imageView.applyViewState(state, animated: animated) }
                return
            }
            // 去掉这一格自己的偏差，得到大家共用的状态，再按各格的偏差摆
            let shared = ZoomableImageView.ViewState(
                fit: false, zoom: state.zoom / pane.zoomRatio,
                center: CGPoint(x: state.center.x - pane.centerDelta.x, y: state.center.y - pane.centerDelta.y))
            self.compareState = shared
            for other in cv.panes where other !== pane { other.imageView.applyViewState(other.placed(shared), animated: animated) }
        }
        iv.onNeedsDetail = { [weak self, weak pane] in
            guard let self, let pane, let url = pane.url else { return }
            let loader = self.loader
            self.decodeQueue.addOperation {
                guard let info = loader.info(for: url), let full = loader.fullImage(for: url) else { return }
                DispatchQueue.main.async {
                    guard pane.url == url else { return }
                    pane.imageView.set(image: full, logicalSize: info.pixelSize, resetToFit: false, isNew: false)
                }
            }
        }
    }

    /// 把第 index 张放进这一格，按其他格当前的缩放和位置摆好
    private func loadPane(_ pane: ComparePane, index: Int) {
        guard folder.items.indices.contains(index) else { return }
        let url = folder.items[index].url
        pane.photoIndex = index
        pane.url = url
        refreshCompareInfo()
        let px = previewPixelTarget
        // 换了照片：之前单独调的偏差作废；不同步时新照片沿用这一格原来的缩放和位置
        pane.resetAdjustment()
        let previous = pane.imageView.debugHasImage ? pane.imageView.viewState : nil
        let place: (CGImage, CGSize) -> Void = { [weak self, weak pane] img, size in
            guard let self, let pane, pane.url == url else { return }
            pane.imageView.pendingFadeDuration = nil
            self.compareLoading = true
            pane.imageView.set(image: img, logicalSize: size, resetToFit: true, isNew: true)
            if let s = self.compareSynced ? self.compareState : previous { pane.imageView.applyViewState(s) }
            self.compareLoading = false
        }
        if let info = loader.cachedInfo(for: url),
           let hit = loader.cachedFull(for: url) ?? loader.cachedPreview(for: url, maxPixel: px) {
            place(hit, info.pixelSize)
            return
        }
        let loader = self.loader
        decodeQueue.addOperation {
            guard let info = loader.info(for: url), let pv = loader.preview(for: url, maxPixel: px) else { return }
            DispatchQueue.main.async { place(pv, info.pixelSize) }
        }
    }

    private func compareActivate(_ i: Int) {
        guard let cv = compareView, cv.panes.indices.contains(i) else { return }
        compareActive = i
        for (j, p) in cv.panes.enumerated() { p.isActive = j == i }
        view.window?.makeFirstResponder(cv.panes[i].imageView)
        folder.jump(to: cv.panes[i].photoIndex)
        syncFilmstripSelection()
        filmstrip.scrollTo(index: folder.index)
        if let url = folder.current?.url {
            view.window?.title = url.lastPathComponent
            loadRating(for: url)
        }
        updateExifPanel()
        refreshCompareInfo()
    }

    /// 当前格换成前一张 / 后一张，跳过别的格已经在显示的
    private func compareNavigate(_ delta: Int) {
        guard let cv = compareView else { return }
        let pane = cv.panes[compareActive]
        let n = folder.count
        let others = Set(cv.panes.enumerated().filter { $0.offset != compareActive }.map(\.element.photoIndex))
        var i = pane.photoIndex
        for _ in 0..<n {
            i = ((i + delta) % n + n) % n
            if !others.contains(i) { break }
        }
        guard i != pane.photoIndex else { return }
        loadPane(pane, index: i)
        compareActivate(compareActive)
    }

    /// 点缩略图：放进当前格
    private func compareShow(_ index: Int) {
        guard let cv = compareView else { return }
        loadPane(cv.panes[compareActive], index: index)
        compareActivate(compareActive)
    }

    /// 同步 / 各自独立。重新同步时以当前格为准，其他格保持现在看的位置，记成各自的偏差
    @objc func toggleCompareSync(_ sender: Any?) {
        guard let cv = compareView else { return }
        compareSynced.toggle()
        if compareSynced {
            let ref = cv.panes[compareActive].imageView.viewState
            for p in cv.panes { p.resetAdjustment() }
            if ref.fit {
                compareState = nil
                for p in cv.panes { p.imageView.applyViewState(ref) }
            } else {
                compareState = ref
                for (j, p) in cv.panes.enumerated() where j != compareActive {
                    let s = p.imageView.viewState
                    if s.fit {
                        p.imageView.applyViewState(ref)
                    } else {
                        p.zoomRatio = s.zoom / ref.zoom
                        p.centerDelta = CGPoint(x: s.center.x - ref.center.x, y: s.center.y - ref.center.y)
                    }
                }
            }
        }
        flash(compareSynced ? L10n.t("msg.compareSyncOn", "各格一起缩放和拖动（按住 ⌥ 只动一格）")
                            : L10n.t("msg.compareSyncOff", "各格单独缩放和拖动"), seconds: 2)
        refreshCompareInfo()
    }

    private func compareCyclePane() {
        guard let cv = compareView else { return }
        compareActivate((compareActive + 1) % cv.panes.count)
    }

    /// 各格左下角的序号、文件名、星级、标记
    private func refreshCompareInfo() {
        guard let cv = compareView else { return }
        for p in cv.panes where folder.items.indices.contains(p.photoIndex) {
            let item = folder.items[p.photoIndex]
            let url = item.url
            if ratingCache[url] == nil, !compareRatingPending.contains(url) {
                compareRatingPending.insert(url)
                ratingQueue.async { [weak self] in
                    let r = Rating.read(url)
                    DispatchQueue.main.async {
                        self?.ratingCache[url] = r
                        self?.compareRatingPending.remove(url)
                        self?.refreshCompareInfo()
                    }
                }
            }
            let status = !compareSynced ? L10n.t("ui.compareUnsynced", "未同步")
                : p.isAdjusted ? L10n.t("ui.compareAdjusted", "单独调过") : nil
            p.setInfo(position: p.photoIndex + 1, total: folder.count, name: url.lastPathComponent,
                      rating: ratingCache[url] ?? 0, marked: item.marked, status: status)
        }
    }

    // MARK: - 新版本提示

    /// 顶部居中的一条小提示，不挡操作：点「下载」打开下载地址，点 × 本版本不再提醒
    private var updateBanner: NSView?

    func showUpdateBanner(_ release: UpdateChecker.Release) {
        guard updateBanner == nil else { return }
        let banner = NSVisualEffectView()
        banner.material = .hudWindow
        banner.blendingMode = .withinWindow
        banner.state = .active
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 10
        banner.layer?.masksToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: L10n.f("update.available", "Flipic %@ 可以更新了", release.version))
        text.font = .systemFont(ofSize: 12.5, weight: .medium)
        let download = NSButton(title: L10n.t("update.now", "立即更新"), target: self, action: #selector(updateBannerDownload(_:)))
        download.bezelStyle = .rounded
        download.controlSize = .small
        download.identifier = NSUserInterfaceItemIdentifier(release.download.absoluteString)
        pendingRelease = release
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("update.skip", "不再提醒这个版本"))!,
                             target: self, action: #selector(updateBannerSkip(_:)))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L10n.t("update.skip", "不再提醒这个版本")
        close.identifier = NSUserInterfaceItemIdentifier(release.version)
        let stack = NSStackView(views: [text, download, close])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: banner.topAnchor),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
        updateBanner = banner
    }

    private var pendingRelease: UpdateChecker.Release?

    @objc private func updateBannerDownload(_ sender: NSButton) {
        if let r = pendingRelease { Updater.shared.install(r) }
        updateBanner?.removeFromSuperview()
        updateBanner = nil
    }

    @objc private func updateBannerSkip(_ sender: NSButton) {
        UpdateChecker.skippedVersion = sender.identifier?.rawValue
        updateBanner?.removeFromSuperview()
        updateBanner = nil
    }

    var debugUpdateBannerVisible: Bool { updateBanner?.superview != nil }
    func debugCapture(to path: String) { captureWindow(to: path, raw: true) }
    func debugSkipUpdate() {
        guard let banner = updateBanner else { return }
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.action == #selector(updateBannerSkip(_:)) { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        if let b = find(banner) { updateBannerSkip(b) }
    }

    // MARK: - 设为桌面壁纸

    @objc func setWallpaper(_ sender: Any?) {
        guard let item = folder.current, let screen = NSScreen.main else { return }
        do {
            try NSWorkspace.shared.setDesktopImageURL(item.url, for: screen, options: [:])
            flash(L10n.f("msg.wallpaperSet", "已设为桌面壁纸： %@", item.url.lastPathComponent))
        } catch {
            flash(L10n.f("msg.wallpaperFailed", "设置壁纸失败： %@", error.localizedDescription))
        }
    }

    // MARK: - 批量转换格式

    @objc private func qualityChanged(_ sender: NSSlider) {
        qualityLabel?.stringValue = L10n.f("bc.quality", "质量 %d", Int(sender.doubleValue))
    }

    @objc private func batchFormatChanged(_ sender: NSPopUpButton) {
        batchQualitySlider?.isEnabled = sender.indexOfSelectedItem != 1   // PNG 无损，质量滑杆禁用
    }

    private func buildBatchAlert() -> (NSAlert, NSPopUpButton, NSSlider) {
        let alert = NSAlert()
        alert.messageText = L10n.t("bc.title", "批量转换格式")
        alert.informativeText = L10n.f("bc.info", "将当前文件夹 %d 张图片转换后存入子文件夹 Converted-*（同名不同扩展名）。", folder.count)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 54, width: 240, height: 26))
        popup.addItems(withTitles: ["JPEG", "PNG", "HEIC"])
        popup.target = self
        popup.action = #selector(batchFormatChanged(_:))
        let slider = NSSlider(value: 85, minValue: 40, maxValue: 100, target: self,
                              action: #selector(qualityChanged(_:)))
        batchQualitySlider = slider
        slider.frame = NSRect(x: 0, y: 26, width: 240, height: 24)
        let label = NSTextField(labelWithString: L10n.f("bc.quality", "质量 %d", 85))
        label.font = .systemFont(ofSize: 11)
        label.frame = NSRect(x: 0, y: 4, width: 240, height: 18)
        qualityLabel = label
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 84))
        box.addSubview(popup)
        box.addSubview(slider)
        box.addSubview(label)
        alert.accessoryView = box
        alert.addButton(withTitle: L10n.t("bc.start", "开始转换"))
        alert.addButton(withTitle: L10n.t("alert.cancel", "取消"))
        return (alert, popup, slider)
    }

    @objc func batchConvert(_ sender: Any?) {
        guard !folder.items.isEmpty, !isProcessing else { return }
        let (alert, popup, slider) = buildBatchAlert()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        convertAll(popup.indexOfSelectedItem, quality: slider.doubleValue)
    }

    /// --shot 模式专用：以 sheet 弹出批量转换对话框（本进程渲染，可真实截取）
    private var shotBatchAlert: NSAlert?
    func presentBatchSheetForShot() {
        guard let window = view.window else { return }
        let (alert, _, _) = buildBatchAlert()
        shotBatchAlert = alert
        alert.beginSheetModal(for: window) { _ in }
    }

    private func convertAll(_ index: Int, quality: Double) {
        guard let current = folder.current else { return }
        let table = [("public.jpeg", "jpg"), ("public.png", "png"), ("public.heic", "heic")]
        let (uti, ext) = table[index]
        let srcItems = folder.items
        let outDir = current.url.deletingLastPathComponent().appendingPathComponent("Converted-\(ext)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        isProcessing = true
        flash("转换中 0/\(srcItems.count)", seconds: 3600)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var ok = 0, fail = 0
            for (i, item) in srcItems.enumerated() {
                autoreleasepool {
                    guard item.url.pathExtension.lowercased() != ext,
                          let img = ImageLoader.decodedFull(url: item.url) else {
                        fail += 1
                        return
                    }
                    let outURL = outDir.appendingPathComponent(
                        item.url.deletingPathExtension().lastPathComponent + "." + ext)
                    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, uti as CFString, 1, nil) else {
                        fail += 1
                        return
                    }
                    CGImageDestinationAddImage(dest, img,
                                               [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    if CGImageDestinationFinalize(dest) { ok += 1 } else { fail += 1 }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.flash(L10n.f("msg.converting", "转换中 %1$d/%2$d", i + 1, srcItems.count), seconds: 3600)
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
                self?.flash(L10n.f("msg.convertDone", "转换完成：成功 %1$d，失败 %2$d，输出在 Converted-%3$@/", ok, fail, ext), seconds: 4)
            }
        }
    }

    // MARK: - 重命名当前图片

    @objc func renameCurrent(_ sender: Any?) {
        exitCompare()
        guard let item = folder.current, !isProcessing else { return }
        let ext = item.url.pathExtension
        let base = item.url.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.rename", "重命名")
        alert.informativeText = ext.isEmpty
            ? L10n.t("alert.renameNoExt", "输入新的名称")
            : L10n.f("alert.renameKeepExt", "输入新的名称（保留 .%@ 扩展名）", ext)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = base
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L10n.t("alert.renameButton", "重命名"))
        alert.addButton(withTitle: L10n.t("alert.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            flash(L10n.t("msg.prefixEmpty", "前缀不能为空"))
            return
        }
        if newName == base {
            view.window?.makeFirstResponder(imageView)
            return
        }
        let sanitized = newName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folderURL = item.url.deletingLastPathComponent()
        let fm = FileManager.default
        var candidate = ext.isEmpty ? sanitized : "\(sanitized).\(ext)"
        var n = 2
        while candidate != item.url.lastPathComponent,
              fm.fileExists(atPath: folderURL.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(sanitized) \(n)" : "\(sanitized) \(n).\(ext)"
            n += 1
        }
        do {
            try fm.moveItem(at: item.url, to: folderURL.appendingPathComponent(candidate))
        } catch {
            flash(L10n.f("msg.renameFailed", "重命名失败： %@", error.localizedDescription))
            return
        }
        folder.renameCurrent(to: candidate)
        loader.evict(url: folderURL.appendingPathComponent(candidate))  // 无害；确保旧键不残留
        updateHUD()
        view.window?.makeFirstResponder(imageView)
        flash(L10n.f("msg.renamedTo", "已重命名为 %@", candidate))
    }

    // MARK: - 导出

    /// 后台把当前图（已含旋转）编码写入目标位置，完成后回主线程提示
    private func runExport(sourceURL: URL, turns: Int, destURL: URL, uti: String, quality: Double,
                           currentBytes: Int64, completion: @escaping (String) -> Void) {
        isProcessing = true
        flash(L10n.t("msg.exporting", "导出中…"), seconds: 3600)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = ImageLoader.decodedFull(url: sourceURL)
                .flatMap { ImageLoader.rotated($0, quarterTurns: turns) }
            var result: String
            if let image, let bytes = ImageExporter.write(image, to: destURL, uti: uti, quality: quality) {
                let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                result = L10n.f("msg.exported", "已导出 %1$@：%2$@ → %3$@",
                                destURL.lastPathComponent, fmt(currentBytes), fmt(bytes))
            } else {
                result = L10n.f("msg.exportFailed", "导出失败： %@", destURL.lastPathComponent)
            }
            DispatchQueue.main.async {
                self?.isProcessing = false
                completion(result)
            }
        }
    }

    /// ⌘S：导出压缩副本（保存面板交给用户选择位置、文件名、格式与质量）
    @objc func exportAs(_ sender: Any?) {
        guard let item = folder.current, !isProcessing, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = L10n.t("exp.title", "导出压缩图片")
        panel.message = L10n.t("exp.message", "选择保存位置、文件名与格式")
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.nameFieldStringValue = item.url.deletingPathExtension().lastPathComponent + "-compressed.jpg"

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 62, width: 280, height: 26))
        popup.addItems(withTitles: Self.exportFormats.map { $0.name })
        popup.target = self
        popup.action = #selector(exportFormatChanged(_:))

        let qualityLabel = NSTextField(labelWithString: L10n.f("exp.quality", "质量 %d", 85))
        qualityLabel.font = .systemFont(ofSize: 12)
        qualityLabel.frame = NSRect(x: 0, y: 38, width: 90, height: 18)
        let slider = NSSlider(value: 85, minValue: 40, maxValue: 100, target: self, action: #selector(exportQualityChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 92, y: 34, width: 188, height: 24)

        let estimateLabel = NSTextField(labelWithString: L10n.f("exp.estimating", "预计大小：计算中…"))
        estimateLabel.font = .systemFont(ofSize: 12)
        estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.frame = NSRect(x: 0, y: 8, width: 280, height: 18)

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 92))
        box.addSubview(popup)
        box.addSubview(qualityLabel)
        box.addSubview(slider)
        box.addSubview(estimateLabel)
        panel.accessoryView = box

        exportFormatPopup = popup
        exportQualitySlider = slider
        exportQualityLabel = qualityLabel
        exportEstimateLabel = estimateLabel
        exportSavePanel = panel

        syncExportFormat()
        scheduleExportEstimate()

        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            defer {
                self.exportFormatPopup = nil
                self.exportQualitySlider = nil
                self.exportQualityLabel = nil
                self.exportEstimateLabel = nil
                self.exportSavePanel = nil
                self.exportEstimateWork?.cancel()
            }
            guard resp == .OK, let url = panel.url else { return }
            let f = Self.exportFormats[self.exportFormatPopup?.indexOfSelectedItem ?? 0]
            let currentBytes = ((try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.size] as? Int64) ?? 0
            self.runExport(sourceURL: item.url, turns: self.imageView.rotationTurns, destURL: url,
                           uti: f.uti.identifier, quality: self.exportQualitySlider?.doubleValue ?? 85,
                           currentBytes: currentBytes) { msg in
                self.flash(msg, seconds: 4)
            }
        }
    }

    // MARK: - 导出面板：格式联动 + 大小预估

    private func syncExportFormat() {
        guard let popup = exportFormatPopup,
              let panel = exportSavePanel,
              Self.exportFormats.indices.contains(popup.indexOfSelectedItem) else { return }
        let f = Self.exportFormats[popup.indexOfSelectedItem]
        panel.allowedContentTypes = [f.uti]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + f.ext
        exportQualitySlider?.isEnabled = f.uti != .png
    }

    @objc private func exportFormatChanged(_ sender: NSPopUpButton) {
        syncExportFormat()
        scheduleExportEstimate()
    }

    @objc private func exportQualityChanged(_ sender: NSSlider) {
        exportQualityLabel?.stringValue = L10n.f("exp.quality", "质量 %d", Int(sender.doubleValue))
        scheduleExportEstimate()
    }

    /// 防抖 0.3s 后在后台真实编码一次，给出预估文件大小（带缓存）
    private func scheduleExportEstimate() {
        guard let popup = exportFormatPopup, let slider = exportQualitySlider,
              let label = exportEstimateLabel, let item = folder.current,
              Self.exportFormats.indices.contains(popup.indexOfSelectedItem) else { return }
        let f = Self.exportFormats[popup.indexOfSelectedItem]
        exportEstimateWork?.cancel()
        exportEstimateGeneration += 1
        let gen = exportEstimateGeneration
        let key = "\(item.url.path)#\(imageView.rotationTurns)#\(f.uti.identifier)#\(Int(slider.doubleValue))"
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        if let cached = exportEstimateCache[key] {
            label.stringValue = L10n.f("exp.estimate", "预计大小： %@", fmt(cached))
            return
        }
        label.stringValue = L10n.f("exp.estimating", "预计大小：计算中…")
        let turns = imageView.rotationTurns
        let loader = self.loader
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flipic-estimate.\(f.ext)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.exportEstimateGeneration == gen else { return }
            let image = loader.fullImage(for: item.url).flatMap { ImageLoader.rotated($0, quarterTurns: turns) }
            var bytes: Int64?
            if let image { bytes = ImageExporter.write(image, to: tmp, uti: f.uti.identifier, quality: slider.doubleValue) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.exportEstimateGeneration == gen else { return }
                if let bytes {
                    self.exportEstimateCache[key] = bytes
                    self.exportEstimateLabel?.stringValue = L10n.f("exp.estimate", "预计大小： %@", fmt(bytes))
                } else {
                    self.exportEstimateLabel?.stringValue = L10n.f("exp.estimate", "预计大小： %@", "--")
                }
            }
        }
        exportEstimateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// ⌘⌥S：把视图旋转无损写回文件
    @objc func saveRotation(_ sender: Any?) {
        guard let item = folder.current, !isProcessing else { return }
        guard !imageView.isAnimated else {
            flash(L10n.t("msg.rotAnimated", "动图不支持写回旋转"))
            return
        }
        let turns = ((imageView.rotationTurns % 4) + 4) % 4
        guard turns != 0 else {
            flash(L10n.t("msg.rotNone", "当前没有待保存的旋转"))
            return
        }
        isProcessing = true
        flash(L10n.t("msg.rotSaving", "保存旋转中…"), seconds: 3600)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ImageLoader.writeRotation(url: item.url, clockwiseTurns: turns)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                switch result {
                case .lossless:
                    self.flash(L10n.t("msg.rotSaved", "已保存旋转（无损）"), seconds: 3)
                case .reencoded:
                    self.flash(L10n.t("msg.rotSavedReencoded", "已保存旋转（该格式重新编码）"), seconds: 3)
                case .failed:
                    self.flash(L10n.f("msg.rotFailed", "保存旋转失败： %@", " "), seconds: 3)
                    return
                }
                self.loader.evict(url: item.url)
                self.showImage(resetToFit: false)
            }
        }
    }

    // MARK: - 关于窗口（简介 / 使用方式 / 快捷键，多语言）

    @objc func showAbout(_ sender: Any?) {
        if let wc = aboutWindowController {
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.t("menu.about", "关于 Flipic")
        window.appearance = NSAppearance(named: .darkAqua)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 680))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 680))
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 26, height: 26)
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(aboutContent())
        scroll.documentView = textView
        window.contentView = scroll
        window.center()

        let wc = NSWindowController(window: window)
        aboutWindowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func aboutContent() -> NSAttributedString {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let body = L10n.t("about.body", "")
        let shortcuts = L10n.t("sc.body", "")
        let full = body + "\n\n■ " + L10n.t("about.shortcutsTitle", "快捷键") + "\n" + shortcuts

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = 6

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "Flipic \(version)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]))
        for line in full.components(separatedBy: "\n") {
            let isHeading = line.hasPrefix("■")
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: isHeading ? NSFont.systemFont(ofSize: 14.5, weight: .semibold)
                                 : NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: isHeading ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]))
        }
        return out
    }

    // MARK: - 真实界面截图（--shot 自拍模式，抓取自身窗口，无需屏幕录制权限）

    /// --peektest：用真实的空格按键事件驱动「按住预览」与「点按切换」，记录窗口尺寸并截图（仅诊断用）
    func runPeekTest(outDir: String) {
        guard let window = view.window else { return }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func key(_ down: Bool, _ chars: String, repeatFlag: Bool = false) {
            let code: UInt16 = chars == " " ? 49 : 124
            let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: repeatFlag, keyCode: code)!
            if down { imageView.keyDown(with: e) } else { imageView.keyUp(with: e) }
        }
        func report(_ tag: String) {
            let f = window.frame, c = window.contentLayoutRect, px = imageView.pixelSize
            NSLog("PEEK %@ window=%.0fx%.0f windowRatio=%.4f imageRatio=%.4f filmstripHidden=%d hudHidden=%d toolbarHidden=%d %@",
                  tag, f.width, f.height, f.width / f.height, px.width / max(px.height, 1),
                  filmstrip.isHidden ? 1 : 0, hudView.isHidden ? 1 : 0, toolbarView.isHidden ? 1 : 0, imageView.fitDiagnostics)
            _ = c
            captureWindow(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(tag).png").path, raw: true)
        }
        var t = 0.5
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0) { report("0-before") }
        at(0.5) { key(true, " "); key(false, " ") }             // 点一下空格：进入预览
        at(0.9) { report("1-peek") }
        at(0.3) { key(true, "\u{F703}"); key(false, "\u{F703}") }   // 预览中按 →
        at(1.4) { report("2-peek-next") }
        at(0.3) { key(true, " ", repeatFlag: true) }            // 系统重复事件不应切换
        at(0.5) { report("3-repeat-ignored") }
        at(0.3) { key(true, " "); key(false, " ") }             // 再点一下：退出
        at(1.0) { report("4-exited") }
        at(0.3) { key(true, " "); key(false, " ") }             // 再进入
        at(1.0) { key(true, "\u{1B}"); key(false, "\u{1B}") }       // Esc 退出
        at(1.0) { report("5-esc-exited") }
        at(0.5) { NSApp.terminate(nil) }
    }

    /// --shot-browse：按当前排序依次抓拍文件夹里每一张的浏览视图（官网翻页演示用）
    /// --cleanup-shot <输出目录> <文件夹>：进入清理模式，等扫描完，逐个分类截图，再试放大检查；
    /// 文件夹名含 trash-test 时再走一遍移到废纸篓 + 撤销
    func runCleanupTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let folderURL = folder.current?.url.deletingLastPathComponent()
        func fileCount() -> Int {
            guard let folderURL else { return -1 }
            return ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? [])
                .filter { ImageLoader.isSupportedExtension($0) }.count
        }
        let started = Date()
        toggleCleanup(nil)
        func waitScan(_ then: @escaping () -> Void) {
            if cleanup?.isScanFinished == true { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitScan(then) }
        }
        waitScan { [self] in
            NSLog("CLEANUP scan finished in %.2fs: %@", Date().timeIntervalSince(started), cleanup?.debugSummary ?? "-")
            var t = 0.6
            func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            for c in CleanupCategory.allCases {
                at(0.1) { self.cleanup?.debugSelect(c) }
                at(0.9) { self.captureWindow(to: "\(outDir)/cat-\(c).png", raw: true) }
            }
            for c in [CleanupCategory.closedEyes, .similar] {
                at(0.1) { self.cleanup?.debugSelect(c); self.cleanup?.debugFocusFirst(); self.cleanup?.debugTogglePreview() }
                at(1.2) { self.captureWindow(to: "\(outDir)/preview-\(c).png", raw: true) }
                at(1.5) { self.captureWindow(to: "\(outDir)/preview2-\(c).png", raw: true); self.cleanup?.debugTogglePreview() }
            }
            // 真实按键：→ 移到第二张，回车切换勾选，空格放大，再空格关闭
            func key(_ code: UInt16, _ chars: String) {
                guard let w = self.view.window, let grid = self.cleanup?.grid,
                      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: w.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                grid.keyDown(with: e)
            }
            at(0.2) { self.cleanup?.debugSelect(.similar); self.cleanup?.debugFocusFirst(); NSLog("CLEANUP keys start %@", self.cleanup?.debugSummary ?? "-") }
            at(0.2) { key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)) }
            at(0.2) { key(36, "\r"); NSLog("CLEANUP after return %@", self.cleanup?.debugSummary ?? "-") }
            at(0.2) { key(49, " ") }
            at(1.0) { self.captureWindow(to: "\(outDir)/keys-preview.png", raw: true); key(49, " ") }
            at(0.3) { key(36, "\r"); NSLog("CLEANUP after 2nd return %@", self.cleanup?.debugSummary ?? "-") }
            if folderURL?.path.contains("trash-test") == true {
                at(0.3) { NSLog("CLEANUP before trash files=%d %@", fileCount(), self.cleanup?.debugSummary ?? "-"); self.cleanup?.debugTrash() }
                at(2.0) {
                    NSLog("CLEANUP after trash files=%d %@", fileCount(), self.cleanup?.debugSummary ?? "-")
                    self.captureWindow(to: "\(outDir)/after-trash.png", raw: true)
                    self.cleanup?.debugUndo()
                }
                at(1.0) { NSLog("CLEANUP after undo files=%d %@", fileCount(), self.cleanup?.debugSummary ?? "-") }
            }
            at(0.3) { self.cleanup?.finish(nil) }
            at(1.0) {
                NSLog("CLEANUP viewer after exit count=%d", self.folder.count)
                self.captureWindow(to: "\(outDir)/viewer-after.png", raw: true)
                NSApp.terminate(nil)
            }
        }
    }

    /// --wheeltest <文件夹>：用合成的滚轮 / 触控板事件验证「滚轮缩放 / 滚轮翻页」两种设置
    func runWheelTest() {
        let saved = ZoomableImageView.wheelNavigates
        func wheel(_ dy: Int32, dx: Int32 = 0, precise: Bool = false, phase: Int64 = 0, momentum: Int64 = 0, cmd: Bool = false) {
            guard let w = view.window,
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                   wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            if cmd { cg.flags = .maskCommand }
            let p = imageView.convert(NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), to: nil)
            cg.location = CGPoint(x: w.frame.minX + p.x, y: (w.screen?.frame.maxY ?? 0) - (w.frame.minY + p.y))
            if let e = NSEvent(cgEvent: cg) { imageView.scrollWheel(with: e) }
        }
        func state(_ tag: String) {
            NSLog("WHEEL %@ index=%d %@", tag, folder.index, imageView.fitDiagnostics)
        }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.5) { ZoomableImageView.wheelNavigates = false; state("0-start zoom-mode") }
        at(0.3) { wheel(-1); wheel(-1); state("1-zoom-mode wheel down x2 (expect same index, zoomed)") }
        at(0.3) { self.imageView.fit(); ZoomableImageView.wheelNavigates = true; state("2-nav-mode fitted") }
        at(0.3) { wheel(-1); state("3-wheel down (expect +1)") }
        at(0.3) { wheel(-1); wheel(-1); wheel(-1); state("4-three ticks same instant (expect +1 only)") }
        at(0.3) { wheel(1); state("5-wheel up (expect -1)") }
        at(0.3) {
            // 触控板一次滑动：began + 多个 changed，总量远超阈值，只翻一张；随后的惯性不翻
            wheel(-4, precise: true, phase: 1)
            for _ in 0..<8 { wheel(-12, precise: true, phase: 2) }
            wheel(0, precise: true, phase: 4)
            for _ in 0..<5 { wheel(-20, precise: true, momentum: 2) }
            state("6-trackpad swipe (expect +1)")
        }
        at(0.3) { wheel(-1, cmd: true); wheel(-1, cmd: true); state("7-cmd+wheel (expect zoomed, same index)") }
        at(0.3) { wheel(-1); state("8-wheel while zoomed (expect pan, same index)") }
        at(0.3) {
            // 放大后双指往上推（自然滚动下 deltaY 为负）：照片跟着往上走，centerOffset.y 变小；往右推 deltaX 为正，照片往右
            NSLog("WHEEL 8a-before %@", self.imageView.fitDiagnostics)
            wheel(-30, dx: 30, precise: true, phase: 1)
            wheel(0, precise: true, phase: 4)
            state("8b-trackpad up+right while zoomed (expect y smaller by 30, x larger by 30)")
        }
        at(0.3) { self.imageView.fit(); wheel(-1); state("9-fit again, wheel down (expect +1)") }
        let savedInv = ZoomableImageView.wheelZoomInverted
        at(0.3) { ZoomableImageView.wheelNavigates = false; ZoomableImageView.wheelZoomInverted = false; self.imageView.fit(); wheel(1); wheel(1); state("10-normal wheel up x2") }
        at(0.3) { ZoomableImageView.wheelZoomInverted = true; self.imageView.fit(); wheel(1); wheel(1); state("11-inverted wheel up x2 (expect opposite of 10)") }
        let savedNavInv = ZoomableImageView.wheelNavInverted
        at(0.3) { ZoomableImageView.wheelNavigates = true; ZoomableImageView.wheelNavInverted = false; self.imageView.fit(); state("12-nav normal before") }
        at(0.3) { wheel(-1); state("13-nav normal wheel down (expect +1)") }
        at(0.3) { ZoomableImageView.wheelNavInverted = true; wheel(-1); state("14-nav inverted wheel down (expect -1)") }
        at(0.3) {
            wheel(-4, precise: true, phase: 1)
            for _ in 0..<8 { wheel(-12, precise: true, phase: 2) }
            wheel(0, precise: true, phase: 4)
            state("15-nav inverted trackpad swipe down (expect -1)")
        }
        // 触控板左右滑：适应窗口时翻页（不管滚轮是缩放还是翻页），放大后平移；上下滑照旧
        func hswipe(_ dx: Int32) {
            wheel(0, dx: dx / 3, precise: true, phase: 1)
            for _ in 0..<8 { wheel(0, dx: dx, precise: true, phase: 2) }
            wheel(0, precise: true, phase: 4)
            for _ in 0..<5 { wheel(0, dx: dx, precise: true, momentum: 2) }
        }
        at(0.3) { ZoomableImageView.wheelNavigates = false; ZoomableImageView.wheelNavInverted = false; self.imageView.fit(); state("16-zoom mode fitted before swipe") }
        at(0.3) { hswipe(12); state("17-swipe fingers left (expect +1, scale unchanged)") }
        at(0.3) { hswipe(-12); state("18-swipe fingers right (expect -1)") }
        at(0.3) { ZoomableImageView.wheelNavigates = true; hswipe(12); state("19-nav mode swipe left (expect +1)") }
        at(0.3) { self.imageView.actualSize() }
        at(0.5) { state("20-zoomed before swipe") }
        at(0.1) { hswipe(12); state("21-zoomed swipe (expect same index, pan x)") }
        at(0.3) {
            ZoomableImageView.wheelNavigates = false
            self.imageView.fit()
            wheel(-4, precise: true, phase: 1)
            for _ in 0..<6 { wheel(-10, precise: true, phase: 2) }
            wheel(0, precise: true, phase: 4)
            state("22-vertical swipe in zoom mode (expect zoom, same index)")
        }
        at(0.3) { ZoomableImageView.wheelNavigates = saved; ZoomableImageView.wheelZoomInverted = savedInv; ZoomableImageView.wheelNavInverted = savedNavInv; NSApp.terminate(nil) }
    }

    /// --slidetest <文件夹> <应用路径>：幻灯片 1 秒间隔 + 交给后期软件
    func runSlideAndEditorTest(appPath: String) {
        let savedInterval = UserDefaults.standard.object(forKey: "slideshowInterval")
        let savedEditor = UserDefaults.standard.object(forKey: "editorAppPath")
        let item = NSMenuItem(); item.tag = 1
        setSlideshowInterval(item)
        let start = folder.index
        var shown: [String] = []
        let t0 = Date()
        startSlideshow()
        for k in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) + 0.5) { [self] in
                shown.append("\(self.folder.index):\(self.imageView.debugHasImage ? "img" : "EMPTY")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.8) { [self] in
            stopSlideshow()
            NSLog("SLIDE interval=1 start=%d after %.1fs: %@", start, Date().timeIntervalSince(t0), shown.joined(separator: " "))
            NSLog("EDIT target=%@", editTargetURL()?.lastPathComponent ?? "-")
            editorAppURL = URL(fileURLWithPath: appPath)
            let probe = NSMenuItem(title: "", action: #selector(openInEditor(_:)), keyEquivalent: "")
            _ = validateMenuItem(probe)
            NSLog("EDIT menu title=%@", probe.title)
            let m = NSMenu(); populateOpenWithMenu(m)
            NSLog("EDIT openWith items=%d first=%@ checked=%@", m.items.count, m.items.first?.title ?? "-",
                  m.items.first { $0.state == .on }?.title ?? "-")
            openInEditor(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSLog("EDIT hud=%@", self.hudNameLabel.stringValue)
                if let v = savedInterval { UserDefaults.standard.set(v, forKey: "slideshowInterval") } else { UserDefaults.standard.removeObject(forKey: "slideshowInterval") }
                if let v = savedEditor { UserDefaults.standard.set(v, forKey: "editorAppPath") } else { UserDefaults.standard.removeObject(forKey: "editorAppPath") }
                NSApp.terminate(nil)
            }
        }
    }

    /// --zoomtest <文件夹>：0 键在指定点放大到 100%（该点下的像素不动）、再按恢复；翻页渐变开关
    func runZoomFadeTest() {
        let saved = ZoomableImageView.fadeTransition
        let b = imageView.bounds
        let p = CGPoint(x: b.width * 0.75, y: b.height * 0.3)
        let before = imageView.debugImagePoint(p)
        imageView.debugToggle(at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let after = imageView.debugImagePoint(p)
            NSLog("ZOOM press0 %@ | point (%.0f,%.0f) image px before=(%.1f,%.1f) after=(%.1f,%.1f)", imageView.fitDiagnostics, p.x, p.y, before.x, before.y, after.x, after.y)
            imageView.debugToggle(at: p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                NSLog("ZOOM press0 again %@", imageView.fitDiagnostics)
                ZoomableImageView.fadeTransition = false
                navigate(1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                    NSLog("FADE off -> animating=%d", imageView.debugContentsAnimating ? 1 : 0)
                    ZoomableImageView.fadeTransition = true
                    navigate(1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                        NSLog("FADE on -> animating=%d", imageView.debugContentsAnimating ? 1 : 0)
                        ZoomableImageView.fadeTransition = saved
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// --hudtest <输出目录> <文件夹>：翻页后左上角不出现信息、临时提示照常；Esc 先关右上角照片信息
    func runHUDTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func esc() {
            guard let w = view.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: w.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53) else { return }
            imageView.keyDown(with: e)
        }
        navigate(1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            NSLog("HUD after nav hidden=%d info panel open=%d", hudView.isHidden ? 1 : 0, exifPanel.isHidden ? 0 : 1)
            captureWindow(to: "\(outDir)/default.png", raw: true)
            flash("test flash")
            NSLog("HUD flash shows=%d", hudView.isHidden ? 0 : 1)
            toggleInfoPanel(nil)
            NSLog("INFO open=%d", exifPanel.isHidden ? 0 : 1)
            esc()
            NSLog("INFO after esc open=%d", exifPanel.isHidden ? 0 : 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                NSLog("HUD after flash hidden=%d", hudView.isHidden ? 1 : 0)
                NSApp.terminate(nil)
            }
        }
    }

    /// --settingstest <输出目录> <文件夹>：设置窗口三页截图；自定义快捷键改键、菜单同步、冲突与保留键
    func runSettingsTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let savedShortcuts = UserDefaults.standard.data(forKey: "customShortcuts")
        Shortcuts.resetAll()
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                             windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        }
        func press(_ code: UInt16, _ chars: String) { if let e = key(code, chars) { imageView.keyDown(with: e) } }
        func infoOpen() -> Int { exifPanel.isHidden ? 0 : 1 }
        func menuItem(_ sel: Selector) -> NSMenuItem? {
            func find(_ m: NSMenu) -> NSMenuItem? {
                for it in m.items {
                    if it.action == sel { return it }
                    if let sub = it.submenu, let f = find(sub) { return f }
                }
                return nil
            }
            return NSApp.mainMenu.flatMap(find)
        }
        func shot(_ w: NSWindow?, _ name: String) {
            guard let w, let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber),
                                                           [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL,
                                                             "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        let settings = SettingsWindowController.shared
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.3) { [self] in
            press(34, "i"); NSLog("SET 1-default I opens info=%d", infoOpen())
            press(34, "i"); NSLog("SET 2-default I closes info=%d", infoOpen())
            let edit = menuItem(#selector(openInEditor(_:)))
            NSLog("SET 3-default edit menu key=%@ mods=%lu", edit?.keyEquivalent ?? "-", edit?.keyEquivalentModifierMask.rawValue ?? 0)
            Shortcuts.set(KeyCombo(keyCode: 40, chars: "k"), for: .info)
            press(34, "i"); NSLog("SET 4-after remap I does nothing info=%d", infoOpen())
            press(40, "k"); NSLog("SET 5-K opens info=%d", infoOpen())
            press(40, "k")
            Shortcuts.set(KeyCombo(keyCode: 14, mods: [.command, .option], chars: "e"), for: .edit)
            NSLog("SET 6-edit menu key=%@ optcmd=%d", edit?.keyEquivalent ?? "-",
                  edit?.keyEquivalentModifierMask == [.command, .option] ? 1 : 0)
            NSLog("SET 7-owner of R=%@ reserved cmdW=%d", Shortcuts.owner(of: KeyCombo(keyCode: 15, chars: "r"))?.rawValue ?? "-",
                  Shortcuts.isReserved(KeyCombo(keyCode: 13, mods: .command, chars: "w")) ? 1 : 0)
            NSLog("SET 8-info tooltip=%@", shortcutTips.first { $0.action == .info }?.button.toolTip ?? "-")
            settings.show(.general)
        }
        at(0.8) { shot(settings.window, "general") }
        at(0.2) { settings.show(.mouse) }
        at(0.6) { shot(settings.window, "mouse") }
        at(0.2) { settings.show(.shortcuts) }
        at(0.6) { shot(settings.window, "shortcuts") }
        at(0.2) {
            // 模拟在录制按钮上操作：点一下，按 ⇧⌘I 录下；再录 ⌘W（保留键，应拒绝）；再录 R（被向右旋转占用，应转移）；⌫ 清除
            guard let rec = settings.debugRecorder(for: .info), let w = settings.window else { NSLog("SET rec missing"); return }
            func rkey(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags) {
                rec.performClick(nil)
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                               context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return }
                if !rec.performKeyEquivalent(with: e) { rec.keyDown(with: e) }
            }
            rkey(34, "i", [.command, .shift])
            NSLog("SET R1-recorded info=%@", Shortcuts.combo(for: .info)?.display ?? "nil")
            rkey(13, "w", .command)
            NSLog("SET R2-cmdW rejected info=%@ status=%@", Shortcuts.combo(for: .info)?.display ?? "nil", settings.debugStatus())
        }
        at(0.3) {
            guard let rec = settings.debugRecorder(for: .info), let w = settings.window else { return }
            func rkey(_ code: UInt16, _ ch: String) {
                rec.performClick(nil)
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                               context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return }
                rec.keyDown(with: e)
            }
            rkey(15, "r")
            NSLog("SET R3-R moved info=%@ rotateCW=%@ status=%@", Shortcuts.combo(for: .info)?.display ?? "nil",
                  Shortcuts.combo(for: .rotateCW)?.display ?? "nil", settings.debugStatus())
            shot(settings.window, "shortcuts-moved")
        }
        at(0.3) {
            guard let rec = settings.debugRecorder(for: .info), let w = settings.window else { return }
            rec.performClick(nil)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                        context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
                rec.keyDown(with: e)
            }
            NSLog("SET R4-backspace cleared info=%@", Shortcuts.combo(for: .info)?.display ?? "nil")
        }
        at(0.2) { [self] in
            let before = folder.sortKey.rawValue
            UserDefaults.standard.set(SortKey.size.rawValue, forKey: "sortKey")
            SettingsWindowController.notify("sort")
            NSLog("SET 9-sort %d -> %d", before, folder.sortKey.rawValue)
            UserDefaults.standard.set(before, forKey: "sortKey")
            SettingsWindowController.notify("sort")
            Shortcuts.resetAll()
            press(34, "i"); NSLog("SET 10-after reset I opens info=%d", infoOpen())
            let edit = menuItem(#selector(openInEditor(_:)))
            NSLog("SET 11-after reset edit menu key=%@ cmdOnly=%d", edit?.keyEquivalent ?? "-",
                  edit?.keyEquivalentModifierMask == .command ? 1 : 0)
            if let savedShortcuts { UserDefaults.standard.set(savedShortcuts, forKey: "customShortcuts") }
            NSApp.terminate(nil)
        }
    }

    /// --ratingtest <文件夹>：各格式写入 / 读回评分，像素不变；按键 4 给同名 RAW+JPG 一起打分；菜单取消评分
    /// --marktest <截图目录> <文件夹>：按 P 标记第 1、3 张和 pair.jpg，⇧P 只看已标记，筛选中取消一张，再切回全部；
    /// 每步记录列表、磁盘上的标签和截图
    func runMarkTest(outDir: String) {
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                imageView.keyDown(with: e)
            }
        }
        func report(_ tag: String) {
            let onDisk = folder.allItems.filter { Marks.isMarked(URL(fileURLWithPath: $0.url.path)) }.map(\.url.lastPathComponent)
            NSLog("MARK %@ | shown=%d/%d markedOnly=%d current=%@ marked=%d badge=%d pill=%d strip=%d | disk=[%@] model=%d",
                  tag, folder.count, folder.totalCount, folder.markedOnly ? 1 : 0, folder.current?.url.lastPathComponent ?? "-",
                  folder.current?.marked == true ? 1 : 0, markBadge.isHidden ? 0 : 1, markedOnlyPill.isHidden ? 0 : 1,
                  filmstrip.collectionView.numberOfItems(inSection: 0), onDisk.joined(separator: ","), folder.markedCount)
        }
        let pairIndex = folder.items.firstIndex { $0.url.lastPathComponent == "pair.jpg" } ?? 1
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.0) { self.goTo(0); }
        at(0.6) { key("p", 35) }
        at(0.6) { report("1-mark first"); self.captureWindow(to: "\(outDir)/1-marked.png", raw: true) }
        at(0.2) { self.goTo(2) }
        at(0.6) { key("p", 35) }
        at(0.4) { self.goTo(pairIndex) }
        at(0.6) { key("p", 35) }
        at(0.6) { report("2-marked 1st,3rd,pair (pair raw follows)") }
        at(0.2) { self.goTo(1) }
        at(0.6) { key("P", 35, .shift) }
        at(0.8) { report("3-marked only, started from unmarked #2"); self.captureWindow(to: "\(outDir)/2-marked-only.png", raw: true) }
        at(0.2) { key("p", 35) }
        at(0.6) { report("4-unmark inside filter (stays listed)") }
        at(0.2) { key("P", 35, .shift) }
        at(0.8) { report("5-show all") }
        at(0.2) { key("P", 35, .shift) }
        at(0.8) { report("6-marked only again (unmarked one gone)") }
        at(0.2) { key("P", 35, .shift) }
        at(0.6) { NSApp.terminate(nil) }
    }

    /// --comparetest <截图目录> <文件夹>：C 进入两格对比、在当前格放大（另一格同步）、→ 换候选、Tab 换格并按 P、⇧C 四格、Esc 退出
    func runCompareTest(outDir: String) {
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            guard let target = view.window?.firstResponder as? NSView,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            target.keyDown(with: e)
        }
        func fmt(_ s: ZoomableImageView.ViewState) -> String {
            s.fit ? "fit" : String(format: "x%.2f@(%.3f,%.3f)", s.zoom, s.center.x, s.center.y)
        }
        func report(_ tag: String) {
            let panes = compareView?.panes ?? []
            NSLog("CMP %@ | panes=%d active=%d current=%@ main=%@ | %@", tag, panes.count, compareActive,
                  folder.current?.url.lastPathComponent ?? "-", imageView.isHidden ? "hidden" : "shown",
                  panes.map { "[\($0.photoIndex) \(fmt($0.imageView.viewState)) img=\($0.imageView.debugImage?.width ?? 0)/\(Int($0.imageView.pixelSize.width)) \($0.debugInfo)]" }.joined(separator: " "))
        }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.0) { self.goTo(0) }
        at(0.8) { key("c", 8) }
        at(1.2) { report("1-C two panes"); self.captureWindow(to: "\(outDir)/1-two.png", raw: true) }
        at(0.2) {
            guard let p = self.compareView?.panes[self.compareActive] else { return }
            p.imageView.debugToggle(at: CGPoint(x: p.bounds.width * 0.3, y: p.bounds.height * 0.4))
        }
        at(1.2) { report("2-zoomed active pane (other follows)"); self.captureWindow(to: "\(outDir)/2-zoomed.png", raw: true) }
        at(0.2) { self.debugOptionHeld = true; self.compareView?.panes[0].imageView.debugPan(dx: 60, dy: 0); self.debugOptionHeld = false }
        at(0.4) { report("2a-option-drag left pane only") }
        at(0.2) { self.compareView?.panes[1].imageView.debugPan(dx: 0, dy: 40) }
        at(0.4) { report("2b-drag right pane: both move, left keeps its offset") }
        at(0.2) { key("L", 37, .shift) }
        at(0.3) { self.compareView?.panes[1].imageView.debugPan(dx: 0, dy: 40) }
        at(0.4) { report("2c-sync off: right moves alone") }
        at(0.2) { key("L", 37, .shift) }
        at(0.3) { self.compareView?.panes[1].imageView.debugPan(dx: 0, dy: -40) }
        at(0.4) { report("2d-sync on again: both move, offsets kept") }
        at(0.2) { key("", 124) }
        at(1.2) { report("3-right arrow: candidate changes, keeps zoom") }
        at(0.2) { key("\t", 48) }
        at(0.4) { key("p", 35) }
        at(0.6) { report("4-tab to left pane, P marks it") }
        at(0.2) { key("C", 8, .shift) }
        at(1.5) { report("5-shift-C four panes"); self.captureWindow(to: "\(outDir)/3-four.png", raw: true) }
        at(0.2) { key("\u{1B}", 53) }
        at(1.0) { report("6-Esc exits to single view"); self.captureWindow(to: "\(outDir)/4-exit.png", raw: true) }
        at(0.3) { if self.folder.current?.marked == true { self.toggleMark(nil) } }
        at(0.8) { NSApp.terminate(nil) }
    }

    /// --exporttest <输出目录> <文件夹>：只看 4 星以上 → 复制到 copy/（里面先放一个同名文件）→ 移动到 move/ → 回到剩下的全部照片。
    /// 星级要事先写好：a.jpg 5 星、pair 4 星（RAW 用旁车 .xmp）、c.jpg 2 星
    func runExportTest(outDir: String) {
        let out = URL(fileURLWithPath: outDir)
        let copyDir = out.appendingPathComponent("copy"), moveDir = out.appendingPathComponent("move")
        func list(_ d: URL) -> String {
            ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted().joined(separator: ",")
        }
        func report(_ tag: String) {
            NSLog("EXP %@ | shown=%d/%d filter=%@ items=[%@] | src=[%@] copy=[%@] move=[%@]", tag, folder.count, folder.totalCount,
                  String(describing: folder.filter), folder.items.map(\.url.lastPathComponent).joined(separator: ","),
                  list(folder.allItems.first?.url.deletingLastPathComponent() ?? out.appendingPathComponent("src")), list(copyDir), list(moveDir))
        }
        let src = folder.current?.url.deletingLastPathComponent()
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.0) { self.applyRatingFilter(4) { report("1-only 4 stars and up") } }
        at(1.0) { self.pokeControls() }
        at(0.6) { self.captureWindow(to: "\(outDir)/filter.png", raw: true) }
        at(1.0) { self.debugExportTarget = copyDir; Self.exportFolderMoves = false; self.exportToFolder(nil) }
        at(1.5) { report("2-copied (a.jpg existed -> a 2.jpg, pair.xmp follows)") }
        at(0.2) { self.debugExportTarget = moveDir; Self.exportFolderMoves = true; self.exportToFolder(nil) }
        at(1.5) {
            NSLog("EXP srcdir=[%@]", list(src ?? out))
            report("3-moved: source loses them, back to remaining photos")
        }
        at(0.3) { Self.exportFolderMoves = false; NSApp.terminate(nil) }
    }

    func runRatingTest() {
        func pixelHash(_ url: URL) -> Int {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let data = img.dataProvider?.data else { return 0 }
            return (data as Data).hashValue
        }
        for item in folder.items where !CleanupUnit.isRaw(item.url) || item.url.pathExtension.lowercased() == "dng" {
            let before = pixelHash(item.url)
            let size0 = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0
            let ok = Rating.write(3, to: item.url)
            let back = Rating.read(item.url)
            let after = pixelHash(item.url)
            let size1 = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0
            NSLog("RATE %@ write=%d read=%d pixelsSame=%d size %d->%d sidecar=%d", item.url.lastPathComponent, ok ? 1 : 0, back,
                  before == after ? 1 : 0, size0, size1, FileManager.default.fileExists(atPath: Rating.sidecarURL(for: item.url).path) ? 1 : 0)
        }
        guard let pairIndex = folder.items.firstIndex(where: { $0.url.lastPathComponent.hasPrefix("pair") && !CleanupUnit.isRaw($0.url) }) else {
            NSLog("RATE no pair"); NSApp.terminate(nil); return
        }
        goTo(pairIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                        context: nil, characters: "4", charactersIgnoringModifiers: "4", isARepeat: false, keyCode: 21) {
                imageView.keyDown(with: e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                let jpg = folder.items[pairIndex].url
                let raw = jpg.deletingPathExtension().appendingPathExtension("ARW")
                NSLog("RATE key4 jpg=%d raw=%d label=%@ hidden=%d", Rating.read(jpg), Rating.read(raw), ratingLabel.stringValue, ratingLabel.isHidden ? 1 : 0)
                pokeControls()
                captureWindow(to: jpg.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rating-shot.png").path, raw: true)
                let probe = NSMenuItem(title: "", action: #selector(setRatingMenu(_:)), keyEquivalent: "")
                probe.tag = 4
                _ = validateMenuItem(probe)
                NSLog("RATE menu 4 checked=%d", probe.state == .on ? 1 : 0)
                probe.tag = 0
                setRatingMenu(probe)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    NSLog("RATE cleared jpg=%d raw=%d hidden=%d", Rating.read(jpg), Rating.read(raw), ratingLabel.isHidden ? 1 : 0)
                    let side = Rating.sidecarURL(for: raw)
                    NSLog("RATE sidecar keeps lightroom data=%d", ((try? String(contentsOf: side, encoding: .utf8)) ?? "").contains("crs:Exposure2012") ? 1 : 0)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// --ratingshot <输出目录> <文件夹>：打开已评分的照片，等控件自动隐藏后截图，星级应仍在；未评分的照片不显示
    func runRatingShot(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.3) { self.goTo(0) }
        at(5.0) {
            NSLog("RSHOT opened rated=%d badgeVisible=%d toolbarHidden=%d", self.currentRating, self.ratingBadge.isHidden ? 0 : 1, self.toolbarView.alphaValue < 0.5 ? 1 : 0)
            self.captureWindow(to: "\(outDir)/opened-rated.png", raw: true)
        }
        at(0.2) { self.pokeControls() }
        at(0.8) { self.captureWindow(to: "\(outDir)/controls-visible.png", raw: true) }
        at(0.3) { self.goTo(self.folder.items.firstIndex { $0.url.lastPathComponent == "pair.jpg" } ?? 0) }
        at(1.5) { NSLog("RSHOT unrated rated=%d badgeVisible=%d", self.currentRating, self.ratingBadge.isHidden ? 0 : 1) }
        at(0.2) { self.setRating(5) }
        at(4.5) {
            NSLog("RSHOT after key5 badge=%@ visible=%d", self.ratingBadgeLabel.stringValue, self.ratingBadge.isHidden ? 0 : 1)
            self.captureWindow(to: "\(outDir)/after-rate.png", raw: true)
            self.setRating(0)
        }
        at(1.0) { NSApp.terminate(nil) }
    }

    /// --slidefadetest <文件夹>：翻页渐变关、幻灯片渐变开 1.5 秒：放映切换有渐变且时长对，手动翻页没有；
    /// 幻灯片渐变关掉后放映也没有；间隔 1 秒时渐变压到 0.8 秒
    func runSlideFadeTest() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "fadeTransition"), d.object(forKey: "slideshowFadeOff"), d.object(forKey: "slideshowFadeDuration"), d.object(forKey: "slideshowInterval"))
        ZoomableImageView.fadeTransition = false
        Self.slideshowFade = true
        Self.slideshowFadeDuration = 1.5
        slideshowInterval = 2
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func state(_ tag: String) { NSLog("SFADE %@ animating=%d duration=%.2f", tag, imageView.debugContentsAnimating ? 1 : 0, imageView.debugFadeDuration) }
        at(0.5) { self.scheduleSlideshowTimer() }
        at(2.25) { state("1-slideshow advance (expect 1, 1.50)") }
        at(0.2) { self.stopSlideshow(); self.navigate(1) }
        at(0.1) { state("2-manual next, paging fade off (expect 0)") }
        at(0.5) { Self.slideshowFade = false; self.scheduleSlideshowTimer() }
        at(2.25) { state("3-slideshow fade off (expect 0)") }
        at(0.2) { self.stopSlideshow(); Self.slideshowFade = true; self.slideshowInterval = 1; self.scheduleSlideshowTimer() }
        at(1.2) { state("4-interval 1s (expect 1, 0.80)") }
        // 竖图 → 横图：渐变时旧图那层保持竖图比例，新图是横图比例，都不拉伸
        at(0.3) {
            self.stopSlideshow()
            self.slideshowInterval = 2
            Self.slideshowFadeDuration = 3
            if let i = self.folder.items.firstIndex(where: { (self.loader.info(for: $0.url)?.pixelSize).map { $0.height > $0.width } ?? false }) {
                self.goTo(i)
            }
        }
        at(1.0) { self.scheduleSlideshowTimer() }
        at(2.6) {
            func ratio(_ r: CGRect?) -> Double { guard let r, r.height > 0 else { return 0 }; return Double(r.width / r.height) }
            let px = self.imageView.pixelSize
            NSLog("SFADE 5-portrait->landscape ghostRatio=%.3f newRatio=%.3f newImageRatio=%.3f", ratio(self.imageView.debugGhostFrame),
                  ratio(self.imageView.debugImageFrame), Double(px.width / max(px.height, 1)))
            if let out = ProcessInfo.processInfo.environment["SFADE_SHOT"] { self.captureWindow(to: out, raw: true) }
        }
        at(0.3) {
            self.stopSlideshow()
            for (k, v) in [("fadeTransition", saved.0), ("slideshowFadeOff", saved.1), ("slideshowFadeDuration", saved.2), ("slideshowInterval", saved.3)] {
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
            NSApp.terminate(nil)
        }
    }

    /// --fadeseq <输出目录> <文件夹>：真正的放映（进全屏），竖图换横图的渐变过程中连拍几帧，记录两层的比例
    func runFadeSequence(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let saved = (d.object(forKey: "slideshowFadeDuration"), d.object(forKey: "slideshowInterval"), d.object(forKey: "slideshowFadeOff"))
        Self.slideshowFade = true
        Self.slideshowFadeDuration = 2
        slideshowInterval = 3
        if let i = folder.items.firstIndex(where: { (loader.info(for: $0.url)?.pixelSize).map { $0.height > $0.width } ?? false }) { goTo(i) }
        func ratio(_ r: CGRect?) -> Double { guard let r, r.height > 0 else { return 0 }; return Double(r.width / r.height) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.toggleSlideshow(nil) }
        // 进全屏约 1 秒，第一次切换在开始后 3 秒
        for (n, dt) in [3.9, 4.25, 4.6, 4.95, 5.3].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + dt) {
                let pg = self.imageView.debugGhostPresentation
                NSLog("FSEQ %d ghostRatio=%.3f ghostOpacity=%.2f newRatio=%.3f newOpacity=%.2f fullscreen=%d", n, ratio(self.imageView.debugGhostFrame), pg,
                      ratio(self.imageView.debugImageFrame), self.imageView.debugImagePresentationOpacity,
                      self.view.window?.styleMask.contains(.fullScreen) == true ? 1 : 0)
                self.captureWindow(to: "\(outDir)/f\(n).png", raw: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
            self.toggleSlideshow(nil)
            for (k, v) in [("slideshowFadeDuration", saved.0), ("slideshowInterval", saved.1), ("slideshowFadeOff", saved.2)] {
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
            if let w = self.view.window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        }
    }

    /// --slidestriptest <输出目录> <文件夹>：放映时没动鼠标，缩略图栏跟控件一起隐藏、图片铺到底；动一下出现；停止后回原位
    func runSlideStripTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func state(_ tag: String) {
            NSLog("STRIP %@ stripVisible=%d alpha=%.2f imageBottom=%.0f stripTop=%.0f toolbarVisible=%d", tag,
                  filmstrip.isHidden ? 0 : 1, filmstrip.alphaValue, imageView.frame.minY, filmstrip.frame.maxY,
                  (toolbarView.isHidden || toolbarView.alphaValue < 0.5) ? 0 : 1)
        }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.3) { state("0-before") }
        at(0.2) { self.toggleSlideshow(nil) }
        at(5.0) { state("1-slideshow idle (expect strip hidden, image to bottom)"); self.captureWindow(to: "\(outDir)/idle.png", raw: true) }
        at(0.2) { self.pokeControls() }
        at(0.5) { state("2-mouse moved (expect strip visible)"); self.captureWindow(to: "\(outDir)/moved.png", raw: true) }
        at(0.2) { self.toggleSlideshow(nil) }
        at(0.8) { state("3-stopped (expect strip visible, image above strip)") }
        at(0.3) {
            if let w = self.view.window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        }
    }

    /// --hdrtest <文件夹>：每张图在 HDR 开 / 关两种情况下的解码结果；开着时显示 HDR 图，图层申请高光余量，屏幕当前余量应大于 1
    func runHDRTest() {
        let saved = UserDefaults.standard.object(forKey: "hdrEnabled")
        func desc(_ img: CGImage?) -> String {
            guard let img else { return "nil" }
            return "\(img.bitsPerComponent)bit \((img.colorSpace?.name as String?) ?? "-") hdr=\(ImageLoader.isHDR(img) ? 1 : 0)"
        }
        NSLog("HDR supported=%d screenPotential=%.1f", ImageLoader.hdrSupported ? 1 : 0, NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0)
        for item in folder.items {
            let off = ImageLoader.renderThumbnail(url: item.url, maxPixel: 1600)
            let on = ImageLoader.renderThumbnail(url: item.url, maxPixel: 1600, hdr: true)
            NSLog("HDR decode %@ off=[%@] on=[%@]", item.url.lastPathComponent, desc(off), desc(on))
        }
        let names = folder.items.map(\.url.lastPathComponent)
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func show(_ name: String, _ tag: String) {
            at(0.2) { if let i = names.firstIndex(of: name) { self.goTo(i) } }
            at(1.5) {
                NSLog("HDR show %@ %@ layerEDR=%d shown=[%@] screenHeadroomNow=%.2f windowVisible=%d front=%@", tag, name, self.imageView.debugEDR ? 1 : 0,
                      desc(self.imageView.debugImage), self.view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0,
                      self.view.window?.occlusionState.contains(.visible) == true ? 1 : 0,
                      NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")
            }
        }
        at(0.1) { NSApp.activate(ignoringOtherApps: true); self.view.window?.orderFrontRegardless(); ImageLoader.hdrEnabled = true; SettingsWindowController.notify("hdr") }
        show("sdr.jpg", "on-baseline")
        at(5.0) { NSLog("HDR baseline after 5s screenHeadroomNow=%.2f", self.view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0) }
        let hdrNames = names.filter { $0 != "sdr.jpg" }
        for n in hdrNames { show(n, "on") }
        at(0.1) { ImageLoader.hdrEnabled = false; SettingsWindowController.notify("hdr") }
        if let first = hdrNames.first { show(first, "off") }
        at(15.0) { NSLog("HDR off after 20s screenHeadroomNow=%.2f", self.view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0) }
        at(0.3) {
            if let saved { UserDefaults.standard.set(saved, forKey: "hdrEnabled") } else { UserDefaults.standard.removeObject(forKey: "hdrEnabled") }
            NSApp.terminate(nil)
        }
    }

    /// --pausetest <文件夹>：放映中单击暂停（不再换图）、再单击继续；双击仍是缩放、不暂停；拖动不暂停
    func runPauseTest() {
        let d = UserDefaults.standard
        let savedInterval = d.object(forKey: "slideshowInterval")
        slideshowInterval = 2
        guard let w = view.window else { return }
        let center = imageView.convert(NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), to: nil)
        // 直接把事件交给图片视图：不抢前台、不进全屏，用户在用别的软件时也能测
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: imageView.mouseDown(with: e)
            case .leftMouseDragged: imageView.mouseDragged(with: e)
            default: imageView.mouseUp(with: e)
            }
        }
        func click(_ n: Int = 1) { mouse(.leftMouseDown, center, clicks: n); mouse(.leftMouseUp, center, clicks: n) }
        func state(_ tag: String) {
            NSLog("PAUSE %@ active=%d paused=%d key=%d appActive=%d front=%@ index=%d scale=%@", tag, slideshowActive ? 1 : 0, slideshowPaused ? 1 : 0,
                  w.isKeyWindow ? 1 : 0, NSApp.isActive ? 1 : 0, NSWorkspace.shared.frontmostApplication?.localizedName ?? "-", folder.index, imageView.fitDiagnostics)
        }
        var t = 0.0
        var idx = 0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.3) { self.scheduleSlideshowTimer() }
        at(2.0) { click() }
        let wait = NSEvent.doubleClickInterval + 0.3
        NSLog("PAUSE doubleClickInterval=%.2f", NSEvent.doubleClickInterval)
        at(wait) { state("1-after single click (expect paused)"); idx = self.folder.index }
        at(3.0) { NSLog("PAUSE 2-3s later indexSame=%d", self.folder.index == idx ? 1 : 0) }
        at(0.1) { click() }
        at(wait) { state("3-click again (expect playing)"); idx = self.folder.index }
        at(2.2) { NSLog("PAUSE 4-advanced after resume=%d", self.folder.index != idx ? 1 : 0) }
        at(0.1) { click(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { click(2) } }
        at(wait + 0.2) { state("5-double click (expect still playing)") }
        at(0.2) {
            self.imageView.fit()
            mouse(.leftMouseDown, center, clicks: 1)
            mouse(.leftMouseDragged, NSPoint(x: center.x + 80, y: center.y + 40), clicks: 1)
            mouse(.leftMouseUp, NSPoint(x: center.x + 80, y: center.y + 40), clicks: 1)
        }
        at(wait + 0.1) { state("6-drag (expect still playing)") }
        at(0.2) {
            self.stopSlideshow()
            if let savedInterval { d.set(savedInterval, forKey: "slideshowInterval") } else { d.removeObject(forKey: "slideshowInterval") }
            if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        }
    }

    /// --pantest <文件夹>：放大后往各方向拖很远，图片边缘应贴住窗口边缘不再移动；比窗口小的方向居中
    func runPanTest() {
        guard let w = view.window else { return }
        func drag(_ dx: CGFloat, _ dy: CGFloat) {
            let c = imageView.convert(NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), to: nil)
            for (type, p) in [(NSEvent.EventType.leftMouseDown, c), (.leftMouseDragged, NSPoint(x: c.x + dx, y: c.y + dy)), (.leftMouseUp, NSPoint(x: c.x + dx, y: c.y + dy))] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                switch type {
                case .leftMouseDown: imageView.mouseDown(with: e)
                case .leftMouseDragged: imageView.mouseDragged(with: e)
                default: imageView.mouseUp(with: e)
                }
            }
        }
        func state(_ tag: String) {
            let f = imageView.debugImageFrame, b = imageView.bounds
            NSLog("PAN %@ frame=(%.0f,%.0f %.0fx%.0f) view=%.0fx%.0f left=%.0f right=%.0f bottom=%.0f top=%.0f", tag, f.minX, f.minY, f.width, f.height,
                  b.width, b.height, f.minX, f.maxX - b.width, f.minY, f.maxY - b.height)
        }
        imageView.actualSize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            state("0-100%")
            drag(0, -5000); state("1-dragged far up (expect top=0)")
            drag(0, 10000); state("2-dragged far down (expect bottom=0)")
            drag(-8000, 0); state("3-dragged far left (expect right=0)")
            drag(8000, 0); state("4-dragged far right (expect left=0)")
            imageView.fit()
            imageView.debugToggle(at: CGPoint(x: 5, y: 5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                state("5-zoom at corner (expect no gap: left<=0 bottom<=0)")
                NSApp.terminate(nil)
            }
        }
    }

    /// --thumbtest <输出目录> <文件夹>：缩略图大小切换后，栏高、格子大小、缩略图像素跟着变，照片区域让出空间
    func runThumbTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let saved = UserDefaults.standard.object(forKey: "thumbSize")
        func state(_ tag: String) {
            let layout = filmstrip.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
            let px = folder.items.first.flatMap { loader.cachedThumb(for: $0.url) }.map { max($0.width, $0.height) } ?? 0
            NSLog("THUMB %@ size=%.0f stripHeight=%.0f item=%.0f thumbPx=%d imageBottom=%.0f", tag, FilmstripView.thumbSize,
                  filmstrip.frame.height, layout?.itemSize.width ?? 0, px, imageView.frame.minY)
        }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.5) { state("0-default") }
        for size in [128.0, 48.0] {
            at(0.2) { FilmstripView.thumbSize = size; SettingsWindowController.notify("thumbs") }
            at(1.5) { state("size \(Int(size))"); self.captureWindow(to: "\(outDir)/thumb-\(Int(size)).png", raw: true) }
        }
        at(0.3) {
            if let saved { UserDefaults.standard.set(saved, forKey: "thumbSize") } else { UserDefaults.standard.removeObject(forKey: "thumbSize") }
            NSApp.terminate(nil)
        }
    }

    /// 测试用：当前是否在贴合预览、窗口比例、是不是打开时自动进的
    var debugPeekState: String {
        let f = view.window?.frame ?? .zero
        let px = imageView.pixelSize
        return String(format: "peeking=%d fromOpen=%d windowRatio=%.3f imageRatio=%.3f filmstripHidden=%d",
                      peekSaved != nil ? 1 : 0, peekFromOpen ? 1 : 0, f.width / max(f.height, 1), px.width / max(px.height, 1), filmstrip.isHidden ? 1 : 0)
    }

    func debugPressEsc() {
        guard let w = view.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                             context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) else { return }
        imageView.keyDown(with: e)
    }

    func debugPressNext() {
        guard let w = view.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                             context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) else { return }
        imageView.keyDown(with: e)
    }

    func debugPressSpace() {
        guard let w = view.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                             context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { return }
        imageView.keyDown(with: e)
    }

    func runListTest() {
        NSLog("LIST opened=%@ count=%d items=%@", folder.current?.url.lastPathComponent ?? "-", folder.count,
              folder.items.map(\.url.lastPathComponent).joined(separator: ","))
        // 打开时就开始计时，直到画面出来（最多等 15 秒），量的是用户看到的等待时间
        let opened = Date()
        var i = 0
        func waitShown(_ start: Date, _ done: @escaping () -> Void) {
            // 当前这张的尺寸对上了才算显示出来，免得把上一张的画面当成这一张
            let want = folder.current.flatMap { loader.cachedInfo(for: $0.url)?.pixelSize }
            let shown = imageView.debugHasImage && want != nil && imageView.pixelSize == want
            if shown || Date().timeIntervalSince(start) > 15 { done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { waitShown(start, done) }
        }
        func step() {
            guard i < folder.count else { NSApp.terminate(nil); return }
            let start = i == 0 ? opened : Date()
            if i > 0 { goTo(i) }
            waitShown(start) { [self] in
                let px = imageView.pixelSize
                NSLog("LIST %@ shown=%d size=%.0fx%.0f after=%.2fs", folder.current?.url.lastPathComponent ?? "-", imageView.debugHasImage ? 1 : 0,
                      px.width, px.height, Date().timeIntervalSince(start))
                i += 1
                if CommandLine.arguments.contains("--zoom-full"), i == 1 {
                    // 放大到 100%，等全分辨率图换上来，记录用了多久
                    let z = Date()
                    let before = imageView.debugImage?.width ?? 0
                    zoomActual(nil)
                    func waitFull() {
                        let w = imageView.debugImage?.width ?? 0
                        if w > before || Date().timeIntervalSince(z) > 20 {
                            NSLog("LIST zoom 100%%: backing %d -> %d after=%.2fs", before, w, Date().timeIntervalSince(z))
                            NSApp.terminate(nil)
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitFull() }
                    }
                    waitFull()
                    return
                }
                step()
            }
        }
        step()
    }

    /// --esctest <文件夹>：Esc 关闭开着时，放大先回适应窗口，再按关窗口；关着时不关窗口
    func runEscTest() {
        let saved = Self.escCloses
        func esc() {
            guard let w = view.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: w.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53) else { return }
            imageView.keyDown(with: e)
        }
        Self.escCloses = false
        esc()
        NSLog("ESC off: window visible=%d", view.window?.isVisible == true ? 1 : 0)
        Self.escCloses = true
        imageView.actualSize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            esc()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                NSLog("ESC on, zoomed -> fit=%d window visible=%d", imageView.isFit ? 1 : 0, view.window?.isVisible == true ? 1 : 0)
                Self.escCloses = saved   // 关窗口会退出进程，先恢复设置
                Self.escCloses = true
                NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                    Self.escCloses = saved
                    NSLog("ESC on, fit -> app terminating (window closed)")
                }
                esc()
            }
        }
    }

    /// --xhs-shots <输出目录> <文件夹>：小红书配图用的几张原始窗口截图
    func runXhsShots(outDir: String) {
        guard let window = view.window else { return }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        window.setFrame(CGRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        window.center()
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func cap(_ name: String) { captureWindow(to: "\(outDir)/\(name).png", raw: true) }
        at(0.3) { self.goTo(0) }
        at(1.6) { self.pokeControls() }
        at(0.4) { cap("browse") }
        at(0.2) { self.toggleInfoPanel(nil) }
        at(1.2) { self.pokeControls() }
        at(0.4) { cap("info") }
        at(0.2) { self.toggleInfoPanel(nil); self.goTo(2) }
        at(1.6) {
            // 哈尔施塔特：在湖边房子那里按 0
            let b = self.imageView.bounds
            self.imageView.debugToggle(at: CGPoint(x: b.width * 0.66, y: b.height * 0.62))
        }
        at(2.4) { self.pokeControls() }
        at(0.4) { cap("zoom") }
        // 贴合预览用最后一张（文件夹里放一张竖图，窗口收窄才看得出效果）
        at(0.2) { self.imageView.fit(); self.goTo(max(self.folder.count - 1, 0)) }
        at(1.4) { _ = self.beginPeek() }
        at(1.6) { cap("peek") }
        at(0.3) { self.endPeek() }
        at(1.0) { NSApp.terminate(nil) }
    }

    func runBrowseShots(outDir: String) {
        guard let window = view.window else { return }
        window.setFrame(CGRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        window.center()
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let total = folder.count
        for i in 0..<total {
            let t = 0.4 + Double(i) * 1.6
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.goTo(i) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.0) { [weak self] in self?.pokeControls() }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.35) { [weak self] in
                self?.captureWindow(to: URL(fileURLWithPath: outDir)
                    .appendingPathComponent(String(format: "browse-%02d.png", i + 1)).path)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(total) * 1.6 + 0.5) { NSApp.terminate(nil) }
    }

    func runShotSequence(outDir: String) {
        guard let window = view.window else { return }
        window.setFrame(CGRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        window.center()
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        func shot(_ name: String, at actionTime: Double, capture captureTime: Double,
                  showControls: Bool = true, include: (() -> NSWindow?)? = nil,
                  _ action: @escaping () -> Void = {}) {
            DispatchQueue.main.asyncAfter(deadline: .now() + actionTime) { [weak self] in
                guard let self else { return }
                action()
            }
            // 抓拍前唤醒控件（静默 3 秒会触发自动隐藏），留 0.35s 淡入
            if showControls {
                DispatchQueue.main.asyncAfter(deadline: .now() + captureTime - 0.35) { [weak self] in
                    self?.pokeControls()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + captureTime) { [weak self] in
                guard let self else { return }
                self.captureWindow(to: URL(fileURLWithPath: outDir).appendingPathComponent(name).path,
                                   includePanel: include?())
            }
        }

        // 1 浏览主视图（全景 + 信息卡）
        shot("01-browse.png", at: 0.4, capture: 2.6) { self.goTo(4) }
        // 2 EXIF 面板（带 EXIF 的 HEIC）
        shot("02-exif.png", at: 3.2, capture: 6.6) {
            self.goTo(2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.toggleInfoPanel(nil) }
        }
        // 3 100% 细节
        shot("03-zoom.png", at: 7.0, capture: 8.8) {
            self.toggleInfoPanel(nil)
            self.imageView.actualSize()
        }
        // 4 全屏沉浸（控件自动隐藏）
        shot("04-slideshow.png", at: 9.2, capture: 13.4, showControls: false) {
            self.imageView.fit()
            self.view.window?.toggleFullScreen(nil)
            self.scheduleControlsHide()
        }
        // 5 导出面板（sheet 打开 + 预估大小就绪）
        shot("05-export.png", at: 13.8, capture: 19.6, include: { self.shotBatchAlert?.window }) {
            if let window = self.view.window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.presentBatchSheetForShot() }
        }
        // 收尾退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 22.0) {
            if let panel = self.exportSavePanel, let parent = panel.sheetParent {
                parent.endSheet(panel)
            }
            exit(0)
        }
    }

    /// 抓取自身窗口（.optionIncludingWindow 只渲染窗口自身内容，不受遮挡影响）；
    /// sheet 弹窗单独抓取后合成到相对位置。系统允许应用抓取自己的窗口，无需 TCC 授权
    /// raw：按窗口原尺寸保存，不规格化到商店截图尺寸
    private func captureWindow(to path: String, includePanel: NSWindow? = nil, raw: Bool = false) {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        let wid = CGWindowID(window.windowNumber)
        // AppKit 坐标（左下原点）→ CG 坐标（左上原点），限定只抓窗口矩形
        let f = window.frame
        let cgRect = CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
        guard let img = CGWindowListCreateImage(cgRect, [.optionIncludingWindow],
                                                wid, .bestResolution) else {
            NSLog("SHOT capture failed")
            return
        }
        if raw {
            if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                          "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
            return
        }
        var sheetImg: CGImage?
        var sheetRel = CGPoint.zero   // sheet 左上角相对窗口左上角（点）
        if let sw = includePanel {
            let sf = sw.frame
            let sRect = CGRect(x: sf.minX, y: screen.frame.maxY - sf.maxY, width: sf.width, height: sf.height)
            sheetImg = CGWindowListCreateImage(sRect, [.optionIncludingWindow],
                                               CGWindowID(sw.windowNumber), .bestResolution)
            sheetRel = CGPoint(x: sf.minX - f.minX, y: f.maxY - sf.maxY)
        }
        // 统一规格化到 2880×1800（aspect-cover、无 alpha）
        let tw = 2880, th = 1800
        let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        let s: CGFloat = max(CGFloat(tw) / CGFloat(img.width), CGFloat(th) / CGFloat(img.height))
        let w: CGFloat = CGFloat(img.width) * s
        let h: CGFloat = CGFloat(img.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (CGFloat(tw) - w) / 2, y: (CGFloat(th) - h) / 2, width: w, height: h))
        // 点 → 画布像素换算：img 像素宽 / 窗口点宽 = backingScale，再乘画布缩放 s
        let backing = f.width > 0 ? CGFloat(img.width) / f.width : 2
        let k = s * backing
        if let sheetImg {
            let sheetW = CGFloat(sheetImg.width) * s
            let sheetH = CGFloat(sheetImg.height) * s
            let sheetX = sheetRel.x * k
            let sheetY = CGFloat(th) - sheetRel.y * k - sheetH
            ctx.draw(sheetImg, in: CGRect(x: sheetX, y: sheetY, width: sheetW, height: sheetH))
        }
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        NSLog("SHOT saved \(path)")
    }

    // MARK: - 批量重命名

    @objc func batchRename(_ sender: Any?) {
        guard !folder.items.isEmpty, !isProcessing, let current = folder.current else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("br.title", "批量重命名")
        alert.informativeText = L10n.f("br.info", "将当前文件夹 %d 张图片重命名为「前缀-001.扩展名」格式。", folder.count)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current.url.deletingLastPathComponent().lastPathComponent
        field.placeholderString = L10n.t("br.field", "前缀")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("br.button", "重命名"))
        alert.addButton(withTitle: L10n.t("alert.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let prefix = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else {
            flash(L10n.t("msg.prefixEmpty", "前缀不能为空"))
            return
        }
        let oldCurrentURL = current.url
        let folderURL = oldCurrentURL.deletingLastPathComponent()
        let fm = FileManager.default
        var renamedCount = 0
        var newNameOfCurrent: String?
        var seq = 1
        for item in folder.items {
            let ext = item.url.pathExtension
            var candidate = "\(prefix)-\(String(format: "%03d", seq)).\(ext)"
            while candidate != item.url.lastPathComponent,
                  fm.fileExists(atPath: folderURL.appendingPathComponent(candidate).path) {
                seq += 1
                candidate = "\(prefix)-\(String(format: "%03d", seq)).\(ext)"
            }
            if candidate != item.url.lastPathComponent {
                if (try? fm.moveItem(at: item.url, to: folderURL.appendingPathComponent(candidate))) != nil {
                    renamedCount += 1
                    if item.url == oldCurrentURL { newNameOfCurrent = candidate }
                }
            }
            seq += 1
        }
        folderGeneration += 1
        folder.open(url: folderURL)
        if let newName = newNameOfCurrent {
            folder.jump(to: folder.items.firstIndex { $0.url.lastPathComponent == newName } ?? 0)
        }
        prefetchedURLs.removeAll()
        filmstrip.collectionView.reloadData()
        showImage(resetToFit: true)
        showFirstAfterResort = false
        loadCaptureDatesIfNeeded()
        view.window?.makeFirstResponder(imageView)
        flash(L10n.f("msg.renamedCount", "已重命名 %d 张图片", renamedCount))
    }
}

// MARK: - 胶片条数据源

extension ViewerViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        folder.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.filmstripID, for: indexPath) as! FilmstripItem
        let idx = indexPath.item
        item.itemIndex = idx
        guard idx < folder.count else { return item }
        let url = folder.items[idx].url
        item.setMarked(folder.items[idx].marked)
        if let cached = loader.cachedThumb(for: url) {
            item.setThumbnail(cached)
        } else {
            item.setThumbnail(nil)
            thumbQueue.addOperation { [loader] in
                let t = loader.thumb(for: url)
                DispatchQueue.main.async {
                    if item.itemIndex == idx {
                        item.setThumbnail(t)
                    }
                }
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first else { return }
        if compareView != nil {
            compareShow(ip.item)
            return
        }
        folder.jump(to: ip.item)
        showImage(resetToFit: false)
        view.window?.makeFirstResponder(imageView)
    }
}

// MARK: - 工具条按钮（不抢第一响应者；悬停/按压有圆角高亮，仿系统 HUD 控件）

private final class ToolbarButton: NSButton {
    private static let hoverColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
    private static let pressedColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    /// NSButton 会为内容生成必需优先级的宽高约束，顶掉外部尺寸约束——设置完图标后调用
    func stripInternalSizeConstraints() {
        for c in constraints where c.firstAttribute == .width || c.firstAttribute == .height {
            c.isActive = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Self.hoverColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = Self.pressedColor
        super.mouseDown(with: event)
        layer?.backgroundColor = Self.hoverColor
    }
}

// MARK: - 拖放

private final class DropView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onMouseMoved: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            return false
        }
        onDrop(urls)
        return true
    }
}

// MARK: - 菜单勾选状态

extension ViewerViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if cleanup != nil {
            // 清理模式里只留退出清理和打开别的文件夹，其余看图操作都停用
            return menuItem.action == #selector(toggleCleanup(_:)) || menuItem.action == #selector(showSettings(_:))
                || menuItem.action == #selector(showAbout(_:)) || menuItem.action == #selector(showShortcuts(_:))
        }
        if menuItem.action == #selector(toggleCleanup(_:)) {
            menuItem.state = .off
            return folder.count > 0
        }
        if menuItem.action == #selector(setSortKey(_:)) {
            menuItem.state = menuItem.tag == folder.sortKey.rawValue ? .on : .off
        } else if menuItem.action == #selector(toggleEscCloses(_:)) {
            menuItem.state = Self.escCloses ? .on : .off
        } else if menuItem.action == #selector(toggleFadeTransition(_:)) {
            menuItem.state = ZoomableImageView.fadeTransition ? .on : .off
        } else if menuItem.action == #selector(setSlideshowInterval(_:)) {
            menuItem.state = menuItem.tag == slideshowInterval ? .on : .off
        } else if menuItem.action == #selector(openInEditor(_:)) {
            menuItem.title = editorAppURL.map { L10n.f("menu.editIn", "在%@中编辑", Self.spaced(Self.appName($0))) }
                ?? L10n.t("menu.editChoose", "在后期软件中编辑…")
            return folder.current != nil
        } else if menuItem.action == #selector(setWheelAction(_:)) {
            menuItem.state = (menuItem.tag == 1) == ZoomableImageView.wheelNavigates ? .on : .off
        } else if menuItem.action == #selector(toggleWheelZoomInverted(_:)) {
            menuItem.state = ZoomableImageView.wheelZoomInverted ? .on : .off
        } else if menuItem.action == #selector(setRatingMenu(_:)) {
            menuItem.state = menuItem.tag == currentRating ? .on : .off
            return folder.current != nil
        } else if menuItem.action == #selector(toggleSortReversed(_:)) {
            menuItem.state = folder.sortReversed ? .on : .off
        } else if menuItem.action == #selector(toggleCompare(_:)) {
            menuItem.state = (compareView?.panes.count ?? 0) == 2 ? .on : .off
            return folder.count >= 2
        } else if menuItem.action == #selector(toggleCompare4(_:)) {
            menuItem.state = (compareView?.panes.count ?? 0) >= 3 ? .on : .off
            return folder.count >= 2
        } else if menuItem.action == #selector(setRatingFilter(_:)) {
            let current: Int = { if case .minRating(let n) = folder.filter { return n }; return folder.filter == nil ? 0 : -1 }()
            menuItem.state = menuItem.tag == current ? .on : .off
            return folder.totalCount > 0
        } else if menuItem.action == #selector(exportToFolder(_:)) {
            return folder.count > 0 && !isProcessing
        } else if menuItem.action == #selector(toggleCompareSync(_:)) {
            menuItem.state = compareSynced ? .on : .off
            return compareView != nil
        } else if menuItem.action == #selector(toggleToolbar(_:)) {
            menuItem.state = Self.showToolbar ? .on : .off
        } else if menuItem.action == #selector(toggleMark(_:)) {
            menuItem.title = Self.markMenuTitle(folder.current?.marked ?? false)
            return folder.current != nil
        } else if menuItem.action == #selector(toggleMarkedOnly(_:)) {
            menuItem.state = folder.markedOnly ? .on : .off
            return folder.current != nil
        }
        return true
    }
}

// MARK: - 右键「打开方式」子菜单

extension ViewerViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { populateOpenWithMenu(menu) }
}

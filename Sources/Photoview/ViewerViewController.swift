import AppKit
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

final class ViewerViewController: NSViewController {

    let folder = FolderModel()
    let loader = ImageLoader.shared

    let imageView = ZoomableImageView()
    let filmstrip = FilmstripView()
    private let hudView = NSVisualEffectView()
    private let hudStack = NSStackView()
    private let hudNameLabel = NSTextField(labelWithString: "")
    private let hudDimsLabel = NSTextField(labelWithString: "")
    private let hudExifLabel1 = NSTextField(labelWithString: "")
    private let hudExifLabel2 = NSTextField(labelWithString: "")
    private let exifPanel = NSVisualEffectView()
    private let exifStack = NSStackView()
    let emptyState = NSStackView()
    let emptyHint = NSTextField(labelWithString: "")
    private let toolbarView = NSVisualEffectView()
    /// 右上角：照片信息、置顶、分享（和「照片」「预览」一样：信息按钮和它打开的面板在同一个角，分享在最右），
    /// 跟工具条一起出现和淡出
    private let cornerBar = NSVisualEffectView()
    private var infoButton: NSButton?
    private var infoPanelObservation: NSKeyValueObservation?
    /// 左上角文件名，紧挨窗口的红黄绿按钮，和工具条一起出现和淡出；
    /// 衬一块和右上角同样的半透明底，亮色照片上也看得清
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let fileNameBar = NSVisualEffectView()
    /// 实况照片：文件名下面的「实况」标签，鼠标移上去在照片上播放同名的 .MOV
    private let liveBadge = LiveBadge()
    private var liveMovie: URL?
    private var liveView: PHLivePhotoView?
    #if FLIPIC_PRO
    /// 翻页时要照搬到下一张的放大倍数和位置（Pro）
    var pendingPageZoom: ZoomableImageView.ViewState?
    /// 按内容查找的搜索框和这个文件夹的索引（Pro）
    var contentSearch: ContentSearchUI?
    #endif
    private var fileNameLeading: NSLayoutConstraint!
    private var slideshowButton: NSButton?
    private var pinButton: NSButton?
    /// 「磨砂玻璃」背景：系统材质，透出窗口后面的内容再模糊
    private let glassView = NSVisualEffectView()
    /// 叠在磨砂上的细颗粒，看起来才像毛玻璃；全屏时没东西可透，全靠它出质感
    private let grainView = NSView()
    private let glassDim = NSView()

    /// 128 点见方的随机颗粒，按屏幕像素生成（Retina 下不发糊），平铺使用
    private static let grainColor: CGColor = {
        let px = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedWhite, bytesPerRow: px * 2, bitsPerPixel: 16),
              let data = rep.bitmapData else { return NSColor.clear.cgColor }
        var rng = SystemRandomNumberGenerator()
        for i in 0..<(px * px) {
            // 一半偏亮一半偏暗，透明度各不相同；预乘 alpha
            let a = UInt8.random(in: 0...40, using: &rng)
            let light = Bool.random(using: &rng)
            data[i * 2] = light ? a : 0
            data[i * 2 + 1] = a
        }
        rep.size = NSSize(width: 128, height: 128)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return NSColor(patternImage: image).cgColor
    }()
    private var shareButton: NSButton?
    private var prevArrowContainer: NSView!
    private var nextArrowContainer: NSView!
    private var prevArrowButton: ToolbarButton!
    private var nextArrowButton: ToolbarButton!
    var controlsHideTimer: Timer?
    private var controlsVisible = true
    var filmstripHeight: NSLayoutConstraint!
    /// 平时图片停在缩略图栏上方；幻灯片放映时图片铺到底，缩略图栏浮在上面，跟着控件一起自动隐藏
    private var imageAboveFilmstrip: NSLayoutConstraint!
    private var imageToBottom: NSLayoutConstraint!
    private var generation = 0
    private var slideshowTimer: Timer?
    var isProcessing = false
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
    var prefetchedURLs = Set<URL>()
    private var lastNavDirection = 1
    private var fullRequested = false
    private var folderGeneration = 0
    /// 别的软件（Photoshop 等）存了文件夹里的照片，自动换成新的
    private lazy var folderWatcher = FolderWatcher { [weak self] in self?.folderDidChange() }
    /// 翻到视频时的播放器和底部控制条
    private(set) lazy var video = VideoPlayback(imageView: imageView)
    /// 翻到视频时自动收起了缩略图栏
    private var filmstripHiddenForVideo = false
    var currentIsVideo: Bool { folder.current.map { Video.isVideo($0.url) } ?? false }
    /// 看到有文件不见了，过一会儿再对一次才从列表拿掉
    private var pendingRemovalCheck: DispatchWorkItem?
    /// 打开的是文件夹且用户还没翻页：拍摄时间读完重排后回到新的第一张
    private var showFirstAfterResort = false
    /// 按住空格预览：进入前的窗口与界面状态，退出时原样恢复；非 nil 即正在预览
    private var peekSaved: (frame: NSRect, minSize: NSSize, filmstripHidden: Bool, infoHidden: Bool)?
    /// 清理模式开着时盖在整个看图界面上
    var cleanup: CleanupController?
    /// 照片上的实况文本（系统支持时才有）；停在一张照片上半秒后才分析，连翻时不分析
    private(set) var liveText: LiveTextController?
    private var liveTextWork: DispatchWorkItem?
    private var liveTextStepAt: CFAbsoluteTime = 0
    /// 已经开始分析的是第几次换图（generation）：预览换成原图时不再分析一遍
    private var liveTextGen = -1

    /// 当前图解码：最多 2 路并行（新图预览 + 旧图全分辨率不互相堵）；翻页即取消过期任务
    let decodeQueue = ViewerViewController.makeQueue("decode", width: 2, qos: .userInitiated)
    /// 预取串行：后台一次只解一张，不与前台抢 CPU 和内存带宽
    private let prefetchQueue = ViewerViewController.makeQueue("prefetch", width: 1, qos: .utility)
    /// 草图：三路并行（JPEG 按 1/4 解码大多走硬件解码器，占 CPU 不多），不和清晰图、预取抢
    private let draftQueue = ViewerViewController.makeQueue("draft", width: 3, qos: .userInitiated)
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
        static let draftAhead = 3        // 快速连翻时浏览方向前方先备草图的张数
        static let draftKeepAhead = 9    // 内存吃紧时草图留到前方第几张（弱机上要从前方第 3~6 张开始备）
        static let pressureNear = 2      // 内存吃紧时预览只留前后各 2 张
    }

    /// 当前照片屏幕上已经是什么：还没换过来 / 胶片条缩略图 / 草图 / 清晰图（预览或原图），只升不降
    private enum Shown: Int { case none, thumb, draft, sharp }
    private var shown = Shown.none
    private var shownResetToFit = false
    /// 快速连翻：翻页比清晰预览解得还快时只出草图，停下来再解清晰图，再按浏览方向预取邻居
    private var rapidPaging = false
    private var fastStep = false
    private var lastStepAt: CFAbsoluteTime = 0
    private var stepInterval: CFTimeInterval = 1
    /// 翻页间隔的滑动平均和最近几次：按键事件常常两三个挤在一起到，单看上一次间隔不准
    private var stepIntervalAvg: CFTimeInterval = 1
    private var recentIntervals: [CFTimeInterval] = []
    private var settleTimer: DispatchSourceTimer?
    /// 正在解的草图（按 URL）：连翻时每一步都会重排，正在解的不再重复排
    private var draftOps: [URL: Operation] = [:]
    /// 屏幕尺寸预览实测的解码耗时（滑动平均）：快机 75ms 左右，弱机 150ms 以上
    private var sharpCost: CFTimeInterval = 0.09
    /// 草图实测的解码耗时（滑动平均）：4500 万像素 JPEG 快机 35ms 左右，弱机 80ms 以上
    private var draftCost: CFTimeInterval = 0.05

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

        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.appearance = NSAppearance(named: .darkAqua)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(glassView)
        // 系统材质偏灰，压一层半透明黑，像深色烟熏玻璃
        glassDim.wantsLayer = true
        glassDim.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.38).cgColor
        glassDim.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(glassDim)
        grainView.wantsLayer = true
        grainView.layer?.backgroundColor = Self.grainColor
        grainView.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(grainView)
        for v in [glassView, glassDim, grainView] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
                v.topAnchor.constraint(equalTo: dropView.topAnchor),
                v.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            ])
        }

        imageView.allowsBackdrop = true
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
        imageView.onKeyIntercept = { [weak self] event in self?.handleVideoKey(event) ?? false }
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
                return
            }
            #if FLIPIC_PRO
            // 按内容查找的搜索框开着时，Esc 先清除并关掉它（照片信息面板开着时先关面板）
            if self.exifPanel.isHidden, self.closeContentSearchOnEscape() { return }
            #endif
            if !self.exifPanel.isHidden {
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
        if TextRecognition.liveTextSupported {
            liveText = LiveTextController(imageView: imageView)
            imageView.onImageFrameChange = { [weak self] in self?.liveText?.imageFrameChanged() }
            imageView.onRotate = { [weak self] in
                self?.liveText?.reset()
                self?.scheduleLiveText(restart: true)
            }
            imageView.onMouseDown = { [weak self] in self?.liveText?.clearSelection() }
            imageView.ignoresDoubleClick = { [weak self] p in self?.liveText?.hasInteractiveItem(at: p) ?? false }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidExitFullScreen(_:)),
                                               name: NSWindow.didExitFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidEnterFullScreen(_:)),
                                               name: NSWindow.didEnterFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)),
                                               name: SettingsWindowController.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcutTips),
                                               name: Shortcuts.didChange, object: nil)
        // 从 Photoshop 切回来时再对一遍，监听漏掉的（网络盘、外接盘）也能换上
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.collectionView.dataSource = self
        filmstrip.collectionView.delegate = self
        filmstrip.collectionView.register(FilmstripItem.self, forItemWithIdentifier: Self.filmstripID)
        filmstrip.collectionView.onClick = { [weak self] i, mods in self?.filmstripClicked(i, mods) }
        filmstrip.collectionView.onBlankClick = { [weak self] in
            guard let self, self.filmstrip.collectionView.selectionIndexPaths.count > 1 else { return }
            self.keepStripSelection = false
            self.syncFilmstripSelection()
            self.updateRatingLabel()
        }
        filmstrip.collectionView.dragURLs = { [weak self] i in self?.filmstripDragURLs(from: i) ?? [] }
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

            // 让开右上角的置顶、分享
            exifPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 46),
            exifPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            exifPanel.widthAnchor.constraint(equalToConstant: 300),

            ratingBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ratingBadgeBottom,

            toolbarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -8),
            video.bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            video.bar.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -8),

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

    func pokeControls() {
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

    func setControlsVisible(_ visible: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        var targets: [NSView] = [prevArrowContainer!, nextArrowContainer!]
        // 看视频时照片工具栏换成视频控制条
        if Self.showToolbar { targets += video.isActive ? [cornerBar] : [toolbarView, cornerBar] }
        if Self.showFileName { targets.append(fileNameBar) }
        if liveMovie != nil { targets.append(liveBadge) }
        if video.isActive { targets.append(video.bar) }
        if visible { placeFileName() }
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

    func updateControlsPresence() {
        let present = folder.current != nil
        for t in [toolbarView, cornerBar, fileNameBar, prevArrowContainer!, nextArrowContainer!] { t.isHidden = !present }
        if !Self.showToolbar { toolbarView.isHidden = true; cornerBar.isHidden = true }
        if !Self.showFileName { fileNameBar.isHidden = true }
        if liveMovie == nil { liveBadge.isHidden = true }
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

    /// 窗口按图片比例重新取形：以原图 100% 的点尺寸为上限，超出屏幕可见区 90% 则等比缩小。
    /// 刚进入预览时中心对准进入前的窗口；翻页时按设置对准当前窗口（用户拖过去的位置）或进入前的窗口
    private func wrapWindowToImage(keepingCurrent: Bool = false) {
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
        let anchor = keepingCurrent ? window.frame : saved.frame
        frame.origin = CGPoint(x: anchor.midX - frame.width / 2, y: anchor.midY - frame.height / 2)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - 顶部：左上文件名、右上置顶和分享

    static var showFileName: Bool {
        get { UserDefaults.standard.object(forKey: "showFileName") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showFileName") }
    }

    private func buildTopCorners() {
        cornerBar.material = .hudWindow
        cornerBar.blendingMode = .withinWindow
        cornerBar.state = .active
        cornerBar.wantsLayer = true
        cornerBar.layer?.cornerRadius = 10
        cornerBar.layer?.masksToBounds = true
        cornerBar.translatesAutoresizingMaskIntoConstraints = false
        cornerBar.isHidden = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        #if FLIPIC_PRO
        // 工作台原来只在「窗口」菜单和 ⌥⌘B 里，放到信息按钮左边
        if WorkbenchFeature.isEnabled {
            let tip = L10n.t("menu.workbench", "工作台")
            let (container, button) = iconButton(symbol: "square.grid.2x2", tip: Shortcuts.tooltip(tip, .workbench),
                                                 action: #selector(openWorkbench(_:)),
                                                 size: NSSize(width: 32, height: 28), cornerRadius: 7, tint: .labelColor)
            shortcutTips.append((button, tip, .workbench))
            stack.addArrangedSubview(container)
        }
        #endif
        for (symbol, tip, action) in [("info.circle", L10n.t("tip.info", "照片信息（I）"), #selector(toggleInfoPanel(_:))),
                                      ("pin", L10n.t("tip.pin", "窗口置顶：浮在其他软件上面"), #selector(togglePinned(_:))),
                                      ("square.and.arrow.up", L10n.t("tip.share", "分享"), #selector(shareCurrent(_:)))] {
            let (container, button) = iconButton(symbol: symbol, tip: tip, action: action,
                                                 size: NSSize(width: 32, height: 28), cornerRadius: 7, tint: .labelColor)
            switch symbol {
            case "info.circle": infoButton = button
            case "pin": pinButton = button
            default: shareButton = button
            }
            if let a = Self.shortcutAction(for: action) { shortcutTips.append((button, tip, a)) }
            stack.addArrangedSubview(container)
        }
        cornerBar.addSubview(stack)
        view.addSubview(cornerBar)
        // 信息面板开着时 i 按钮高亮，和置顶的图钉一样；面板在很多地方开关，直接观察它的显示状态
        infoPanelObservation = exifPanel.observe(\.isHidden, options: [.initial, .new]) { [weak self] panel, _ in
            let on = !panel.isHidden
            self?.infoButton?.image = NSImage(systemSymbolName: on ? "info.circle.fill" : "info.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            self?.infoButton?.contentTintColor = on ? .controlAccentColor : .labelColor
        }

        fileNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fileNameLabel.textColor = .labelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.cell?.truncatesLastVisibleLine = true
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileNameBar.material = .hudWindow
        fileNameBar.blendingMode = .withinWindow
        fileNameBar.state = .active
        fileNameBar.wantsLayer = true
        fileNameBar.layer?.cornerRadius = 7
        fileNameBar.layer?.masksToBounds = true
        fileNameBar.translatesAutoresizingMaskIntoConstraints = false
        fileNameBar.isHidden = true
        fileNameBar.addSubview(fileNameLabel)
        view.addSubview(fileNameBar)
        fileNameLeading = fileNameBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 78)
        liveBadge.isHidden = true
        liveBadge.onHover = { [weak self] inside in inside ? self?.playLivePhoto(nil) : self?.stopLivePhoto() }
        liveBadge.onClick = { [weak self] in self?.playLivePhoto(nil) }
        view.addSubview(liveBadge)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cornerBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cornerBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: cornerBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cornerBar.trailingAnchor),
            cornerBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            cornerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            fileNameLeading,
            // 和红黄绿按钮在同一条水平线（标题栏高 28，按钮中心离顶边 14）
            fileNameBar.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            fileNameBar.heightAnchor.constraint(equalToConstant: 22),
            fileNameBar.trailingAnchor.constraint(lessThanOrEqualTo: cornerBar.leadingAnchor, constant: -12),
            fileNameLabel.leadingAnchor.constraint(equalTo: fileNameBar.leadingAnchor, constant: 8),
            fileNameLabel.trailingAnchor.constraint(equalTo: fileNameBar.trailingAnchor, constant: -8),
            fileNameLabel.centerYAnchor.constraint(equalTo: fileNameBar.centerYAnchor),
            liveBadge.leadingAnchor.constraint(equalTo: fileNameBar.leadingAnchor),
            liveBadge.topAnchor.constraint(equalTo: fileNameBar.bottomAnchor, constant: 6),
        ])
    }

    /// 文件名紧跟在缩放按钮右边；全屏时红黄绿按钮不在，贴左边
    private func placeFileName() {
        guard let window = view.window else { return }
        if !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton) {
            fileNameLeading.constant = zoom.frame.maxX + 12
        } else {
            fileNameLeading.constant = 16
        }
    }

    // MARK: - 实况照片

    /// 换了照片：停掉正在放的，查这张有没有带实况标记的同名 .MOV，有就显示「实况」标签
    private func updateLivePhoto(for url: URL) {
        stopLivePhoto()
        liveMovie = nil
        liveBadge.isHidden = true
        LivePhoto.check(url) { [weak self] mov in
            guard let self, self.folder.current?.url == url else { return }
            self.liveMovie = mov
            self.liveBadge.isHidden = mov == nil || !self.controlsVisible || self.peekSaved != nil
            self.liveBadge.alphaValue = self.liveBadge.isHidden ? 0 : 1
        }
    }

    /// 在照片上播一遍实况（适应窗口时播，放大着就先回到整张）；不是实况照片时提示一下
    @objc func playLivePhoto(_ sender: Any?) {
        guard let item = folder.current, compareView == nil else { return }
        guard let mov = liveMovie else {
            if sender != nil || NSApp.currentEvent?.type == .keyDown { flash(L10n.t("live.none", "这张不是实况照片"), seconds: 1.2) }
            return
        }
        if !imageView.viewState.fit { zoomFit(nil) }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = CGSize(width: imageView.bounds.width * scale, height: imageView.bounds.height * scale)
        LivePhoto.load(photo: item.url, movie: mov, targetSize: size) { [weak self] live in
            guard let self, let live, self.folder.current?.url == item.url else { return }
            let v = self.liveView ?? {
                let v = PHLivePhotoView()
                v.delegate = self
                v.contentMode = .aspectFit
                self.view.addSubview(v, positioned: .above, relativeTo: self.imageView)
                self.liveView = v
                return v
            }()
            v.frame = self.imageView.frame
            v.livePhoto = live
            // 系统控件自己也画一个 LIVE 角标，和左上角的「实况」重复，藏掉
            v.livePhotoBadgeView?.isHidden = true
            v.isHidden = false
            v.startPlayback(with: .full)
        }
    }

    func stopLivePhoto() {
        guard let v = liveView else { return }
        v.stopPlayback()
        v.isHidden = true
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
            [("photo.on.rectangle", L10n.t("tip.strip", "底部缩略图栏开关（T）"), #selector(toggleFilmstrip(_:)))],
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
                if d.symbol == "pin" { pinButton = button }
                if d.symbol == "square.and.arrow.up" { shareButton = button }
                if let a = Self.shortcutAction(for: d.action) { shortcutTips.append((button, d.tip, a)) }
                stack.addArrangedSubview(container)
            }
        }
        view.addSubview(toolbarView)
        view.addSubview(video.bar)
        video.onMessage = { [weak self] m in self?.flash(m, seconds: 3) }
        video.onActiveChange = { [weak self] in self?.videoActiveChanged() }
        buildTopCorners()

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

        let title = NSTextField(labelWithString: AppInfo.name)
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
        recentList.orientation = .vertical
        recentList.alignment = .centerX
        recentList.spacing = 2
        emptyState.addArrangedSubview(recentList)
        emptyState.setCustomSpacing(24, after: button)
        view.addSubview(emptyState)
        refreshRecentList()
        NotificationCenter.default.addObserver(forName: Recents.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRecentList()
        }
    }

    /// 开始页「打开…」下面列最近打开过的 5 个文件夹，点一下直接打开
    private let recentList = NSStackView()

    private func refreshRecentList() {
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Recents.folders.prefix(5)
        guard !urls.isEmpty else { return }
        let head = NSTextField(labelWithString: L10n.t("ui.recent", "最近打开"))
        head.font = .systemFont(ofSize: 11, weight: .semibold)
        head.textColor = .tertiaryLabelColor
        recentList.addArrangedSubview(head)
        for u in urls {
            let b = NSButton(title: u.lastPathComponent, target: self, action: #selector(openRecentFolder(_:)))
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.font = .systemFont(ofSize: 13)
            b.toolTip = u.path
            b.identifier = NSUserInterfaceItemIdentifier(u.path)
            b.lineBreakMode = .byTruncatingMiddle
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
            recentList.addArrangedSubview(b)
        }
    }

    @objc private func openRecentFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        open(url: URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: - 打开与加载

    /// 从访达打开单张照片时，窗口直接贴合照片比例（同空格预览）；打开文件夹还是普通窗口。默认关，设置里打开
    /// 贴合预览里翻上一张、下一张时，窗口留在用户拖到的位置（以当前窗口中心对齐）；关掉则回到进入预览前的中心。默认打开
    /// 翻过最后一张回到第一张（反之亦然）；默认关：到头了停住，轻轻回弹一下。幻灯片不受影响，照样循环
    static var wrapAround: Bool {
        get { UserDefaults.standard.bool(forKey: "wrapAround") }
        set { UserDefaults.standard.set(newValue, forKey: "wrapAround") }
    }

    static var peekKeepsPosition: Bool {
        get { UserDefaults.standard.object(forKey: "peekKeepsPosition") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "peekKeepsPosition") }
    }

    static var openInPeek: Bool {
        get { UserDefaults.standard.bool(forKey: "openInPeek") }
        set { UserDefaults.standard.set(newValue, forKey: "openInPeek") }
    }
    private var peekOnFirstImage = false
    /// 这次贴合预览是打开照片时自动进的：开着「按 Esc 关闭窗口」时，Esc 直接关窗口
    private var peekFromOpen = false

    var isEmpty: Bool { folder.count == 0 }
    var debugFilmstripHeight: CGFloat { filmstrip.frame.height }

    /// 从工作台回来：这张就在当前列表里时直接翻过去，不重新读文件夹
    func show(photo url: URL) {
        let path = url.standardizedFileURL.path
        if let i = folder.items.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
            exitCompare()
            if i != folder.index { goTo(i) }
        } else {
            open(url: url)
        }
    }

    func open(url: URL) {
        exitCompare()
        #if FLIPIC_PRO
        contentSearchFolderWillChange()
        #endif
        prefetchedURLs.removeAll()
        decodeQueue.cancelAllOperations()
        prefetchQueue.cancelAllOperations()
        draftQueue.cancelAllOperations()
        thumbQueue.cancelAllOperations()
        endRapidPaging()
        folderGeneration += 1
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        showFirstAfterResort = isDir.boolValue
        peekOnFirstImage = !isDir.boolValue && Self.openInPeek && !CommandLine.arguments.contains(where: { $0.hasPrefix("--") && !["--peekopentest", "--press-esc", "--press-next"].contains($0) })
        let ok = folder.open(url: url)
        #if FLIPIC_PRO
        if ok { applyMergePairs(keep: isDir.boolValue ? nil : url.standardizedFileURL) }
        #endif
        emptyState.isHidden = ok
        updateControlsPresence()
        if !ok {
            imageView.set(image: nil, resetToFit: true, isNew: true)
            emptyHint.stringValue = L10n.t("ui.noImages", "这里没有可识别的图片文件")
        }
        filmstrip.collectionView.reloadData()
        filmstrip.scrollTo(index: folder.index)
        folderWatcher.watch(folder.folderURL)
        if ok, let dir = folder.folderURL { Recents.note(dir) }
        if ok {
            view.window?.makeFirstResponder(imageView)
            showImage(resetToFit: true)
            startFolderWarmup()
            loadCaptureDatesIfNeeded()
            showCleanupHintIfNeeded()
            #if FLIPIC_PRO
            // 用过按内容查找的：闲下来后在后台先把这个文件夹分析好
            contentSearchFolderDidOpen()
            #endif
        } else {
            updateHUD()
        }
    }

    var previewPixelTarget: CGFloat {
        let scale = view.window?.backingScaleFactor ?? 2
        let b = view.bounds
        return min(max(max(b.width, b.height) * scale, 1024), 8192)
    }

    /// 加载管线：缓存命中直出 → 降采样预览秒开 → 放大到预览不够清晰时才解全分辨率。
    /// 未命中时先把手头最好的低清图（草图、胶片条缩略图）放上去，每按一下画面都跟着换，清晰图到了原位替换。
    /// 快速连翻（翻页比清晰预览解得快）时只解草图，停下来才解清晰图。
    /// 主线程只做缓存查询，文件 I/O 与解码全部在限流队列里
    func showImage(resetToFit: Bool) {
        generation += 1
        let gen = generation
        fullRequested = false
        shown = .none
        shownResetToFit = resetToFit
        let fast = fastStep
        fastStep = false
        scheduleLiveText(restart: true)
        guard let item = folder.current else { return }
        let url = item.url
        // 「窗口」菜单里按文件名区分多个窗口（标题栏本身是隐藏的）；左上角也显示
        view.window?.title = url.lastPathComponent
        fileNameLabel.stringValue = url.lastPathComponent
        updateLivePhoto(for: url)
        video.show(mainViewerActive && cleanup == nil ? url : nil)
        decodeQueue.cancelAllOperations()
        draftQueue.cancelAllOperations()
        updateHUD(); updateExifPanel(); syncFilmstripSelection(); loadRating(for: url)
        updateMarkedOnlyPill()
        #if FLIPIC_PRO
        if beforeAfter != nil {
            endRapidPaging()
            updateSmartCache()
            reloadBeforeAfter()
            return
        }
        #endif

        let fitPx = previewPixelTarget
        let info = loader.cachedInfo(for: url)
        let sharpHit = info == nil ? nil : loader.cachedFull(for: url) ?? loader.cachedPreview(for: url, maxPixel: fitPx)
        // 翻得快、清晰图又没备好，进入快速连翻；进去以后直到停下来都按快速连翻走
        if fast, sharpHit == nil || rapidPaging {
            rapidPaging = true
        } else if !fast {
            endRapidPaging()
        }

        if let info, let hit = sharpHit {
            fullRequested = loader.cachedFull(for: url) != nil
            shown = .sharp
            adopt(hit, logicalSize: info.pixelSize, resetToFit: resetToFit, isNew: true)
            if info.isAnimated { imageView.startAnimatedPlayback(url: url) }
            if rapidPaging {
                updateSmartCache(prefetch: false)
                scheduleDrafts(includeCurrent: false)
                scheduleSettle()
            } else {
                updateSmartCache()
            }
            return
        }

        // 未命中：草图或胶片条缩略图先顶上去（按原图尺寸摆，清晰图来了不跳）
        if let info, !info.isAnimated {
            if let d = loader.cachedDraft(for: url) {
                showDraft(d, level: .draft, info: info)
            } else if let t = loader.cachedThumb(for: url) {
                showDraft(t, level: .thumb, info: info)
            }
        }
        if rapidPaging {
            updateSmartCache(prefetch: false)
            scheduleDrafts(includeCurrent: shown != .draft)
            scheduleSettle()
            return
        }
        // 正常翻页：草图和清晰图同时开解，草图先到先上；原图本来就不大时清晰图本身就快，不另出草图
        if shown == .none, info.map({ max($0.pixelSize.width, $0.pixelSize.height) > fitPx * 1.6 }) ?? true {
            enqueueDraft(url)
        }
        let op = enqueueSharp(url: url, gen: gen)
        updateSmartCache(after: op)
    }

    /// navigate / goTo 调用：记下这一步离上一步多久，判断是不是在快速连翻
    private func notePagingStep() {
        let now = CFAbsoluteTimeGetCurrent()
        stepInterval = now - lastStepAt
        lastStepAt = now
        // 停顿过（超过半秒）就重新开始算平均
        if stepInterval > 0.5 {
            stepIntervalAvg = 1
        } else {
            stepIntervalAvg = stepIntervalAvg > 0.5 ? stepInterval : stepIntervalAvg * 0.7 + stepInterval * 0.3
        }
        recentIntervals = Array((recentIntervals + [stepInterval]).suffix(4))
        // 比清晰预览解得还快（最多 150ms 一张）才算；默认按键重复（约 80~120ms）在快机上照常逐张出清晰图
        fastStep = stepInterval < min(0.15, max(sharpCost * 1.25, 0.06))
        #if FLIPIC_PRO
        // 按内容查找的后台分析给翻页让路
        ContentIndex.notePaging()
        #endif
    }

    private func endRapidPaging() {
        rapidPaging = false
        settleTimer?.cancel()
        settleTimer = nil
    }

    /// 主看图界面在用（不在并排对比、修图前后对比里）
    private var mainViewerActive: Bool {
        #if FLIPIC_PRO
        if beforeAfter != nil { return false }
        #endif
        return compareView == nil
    }

    /// 屏幕尺寸的清晰预览，解完换到屏幕上（已有草图时原位替换）
    @discardableResult
    private func enqueueSharp(url: URL, gen: Int) -> Operation {
        let loader = self.loader
        let fitPx = previewPixelTarget
        let op = BlockOperation { [weak self] in
            guard self?.generation == gen, let info = loader.info(for: url) else { return }
            let cached = loader.cachedPreview(for: url, maxPixel: fitPx) != nil
            let t0 = CFAbsoluteTimeGetCurrent()
            let pv = loader.preview(for: url, maxPixel: fitPx)
            let cost = CFAbsoluteTimeGetCurrent() - t0
            BenchProbe.log("sharp decoded \(url.lastPathComponent) \(Int(cost * 1000))ms")
            DispatchQueue.main.async {
                guard let self, self.generation == gen, let pv else { return }
                if !cached { self.sharpCost = self.sharpCost * 0.7 + cost * 0.3 }
                self.showSharp(pv, info: info, url: url)
            }
        }
        decodeQueue.addOperation(op)
        return op
    }

    private func showSharp(_ image: CGImage, info: ImageInfo, url: URL) {
        guard shown != .sharp else { return }
        let first = shown == .none
        shown = .sharp
        adopt(image, logicalSize: info.pixelSize, resetToFit: first && shownResetToFit, isNew: first)
        // 动图：ImageIO 在主队列按帧时长驱动播放
        if info.isAnimated { imageView.startAnimatedPlayback(url: url) }
    }

    /// 低清图上屏：第一次算换了新图（重置旋转、按住的缩放照常恢复），之后的更清楚的版本原位替换
    private func showDraft(_ image: CGImage, level: Shown, info: ImageInfo) {
        guard level.rawValue > shown.rawValue else { return }
        let first = shown == .none
        shown = level
        adopt(image, logicalSize: info.pixelSize, resetToFit: first && shownResetToFit, isNew: first, draft: true)
    }

    /// 解一张草图；解完时如果正好停在这张、屏幕上还没有更好的，就放上去
    private func enqueueDraft(_ url: URL) {
        draftOps = draftOps.filter { $0.value.isExecuting || (!$0.value.isFinished && !$0.value.isCancelled) }
        if draftOps[url] != nil { return }
        let loader = self.loader
        let fitPx = previewPixelTarget
        let op = BlockOperation { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let d = loader.draft(for: url, previewPixel: fitPx), let info = loader.cachedInfo(for: url) else { return }
            let cost = CFAbsoluteTimeGetCurrent() - t0
            BenchProbe.log("draft \(url.lastPathComponent) \(Int(cost * 1000))ms")
            DispatchQueue.main.async {
                guard let self else { return }
                if cost > 0.003, !d.sharp { self.draftCost = self.draftCost * 0.7 + cost * 0.3 }
                guard self.folder.current?.url == url, self.mainViewerActive else { return }
                if d.sharp {
                    self.showSharp(d.image, info: info, url: url)
                } else {
                    self.showDraft(d.image, level: .draft, info: info)
                }
            }
        }
        draftOps[url] = op
        draftQueue.addOperation(op)
    }

    /// 快速连翻：解浏览方向前方几张的草图；上一步排着没开始的已在 showImage 里取消。
    /// 从解完时才会翻到的那张开始：草图要 40ms、30ms 翻一张时从后面第 2 张起，弱机上草图 90ms 就从第 3、4 张起，
    /// 解当前这张等解完早翻过去了。翻得比草图慢时当前这张（还没有草图的话）排第一个
    private func scheduleDrafts(includeCurrent: Bool) {
        let i = folder.index, n = folder.count
        guard folder.items.indices.contains(i) else { return }
        let fitPx = previewPixelTarget
        let pace = max(stepIntervalAvg, 0.01)
        let lead = min(max(Int((draftCost / pace).rounded(.up)), 1), 6)
        var urls: [URL] = includeCurrent && draftCost < pace ? [folder.items[i].url] : []
        let dir = lastNavDirection >= 0 ? 1 : -1
        for step in lead..<(lead + CachePolicy.draftAhead) {
            let j = i + dir * step
            if !Self.wrapAround, !folder.items.indices.contains(j) { break }
            let url = folder.items[((j % n) + n) % n].url
            if urls.contains(url) || loader.cachedDraft(for: url) != nil || loader.cachedPreview(for: url, maxPixel: fitPx) != nil { continue }
            urls.append(url)
        }
        for url in urls { enqueueDraft(url) }
    }

    /// 停下来（一段时间没有下一步）：先解当前这张的清晰图，解完再按浏览方向预取邻居。
    /// 等多久跟着翻页节奏走：按键重复 30ms 时等 65ms 左右，最多 150ms；刚隔了一段长的就按它多等一点
    private func scheduleSettle() {
        settleTimer?.cancel()
        let gen = generation
        // 严格定时：普通 asyncAfter 在窗口不在最前、或系统省电时会被合并推迟上百毫秒
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == gen else { return }
            BenchProbe.log("settle")
            self.endRapidPaging()
            guard self.mainViewerActive, let url = self.folder.current?.url else { return }
            if self.shown == .sharp {
                self.updateSmartCache()
            } else {
                self.updateSmartCache(after: self.enqueueSharp(url: url, gen: gen))
            }
        }
        settleTimer = timer
        let wait = min(max(stepIntervalAvg * 2.2, (recentIntervals.max() ?? 0) * 1.15, 0.06), 0.15)
        BenchProbe.log(String(format: "settle in %.0fms lead=%.0fms/%.0fms", wait * 1000, draftCost * 1000, stepIntervalAvg * 1000))
        timer.schedule(deadline: .now() + wait, leeway: .milliseconds(2))
        timer.resume()
    }

    @objc private func appDidBecomeActive(_ note: Notification) { folderDidChange() }

    /// 翻到视频或离开视频：照片工具栏和视频控制条换位置，可见状态跟着当前的控件显隐走
    private func videoActiveChanged() {
        // 播放时画面占满：缩略图栏收起；暂停、播完或回到照片时放回来
        if video.isActive, video.isPlaying, !filmstrip.isHidden {
            filmstripHiddenForVideo = true
            filmstrip.isHidden = true
            filmstripHeight.constant = 0
        } else if !(video.isActive && video.isPlaying), filmstripHiddenForVideo {
            filmstripHiddenForVideo = false
            filmstrip.isHidden = false
            filmstripHeight.constant = FilmstripView.stripHeight
            filmstrip.scrollTo(index: folder.index)
        }
        let showTools = controlsVisible && Self.showToolbar
        toolbarView.isHidden = video.isActive || !showTools
        toolbarView.alphaValue = toolbarView.isHidden ? 0 : 1
        video.bar.isHidden = !video.isActive || !controlsVisible
        video.bar.alphaValue = video.bar.isHidden ? 0 : 1
    }

    /// 看视频时：回车播放 / 暂停，⇧← ⇧→ 快退快进 5 秒；旋转、放大到眼睛、识别文字这些只对照片有用的键不响应
    private func handleVideoKey(_ event: NSEvent) -> Bool {
        guard currentIsVideo, mainViewerActive else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // where 只约束 case 里最后一个模式，按键和修饰键分开判断
        let code = event.keyCode
        if (code == 36 || code == 76), mods.isEmpty {
            video.toggle()
            pokeControls()
            return true
        }
        if (code == 123 || code == 124), mods == .shift {
            video.seek(by: code == 123 ? -5 : 5)
            pokeControls()
            return true
        }
        switch Shortcuts.action(for: event) {
        case .rotateCW, .rotateCCW, .zoomEye, .copyText, .saveRotation: return true
        default: return false
        }
    }

    /// 文件夹有变化：先换掉被改过的照片，再对一遍新增和不见了的
    private func folderDidChange(removing: Bool = false) {
        guard folder.folderURL != nil else { return }
        reloadChangedFiles()
        syncFolderWithDisk(removing: removing)
    }

    /// 别处新放进来的照片加进列表和缩略图栏，删掉、改名走的拿掉；当前这张还在就停在它上面。
    /// 并排对比、清理模式里先不动，回到看图时（切回来、下次有变化）再对
    private func syncFolderWithDisk(removing: Bool) {
        guard mainViewerActive, cleanup == nil else { return }
        let before = folder.current?.url
        let wasEmpty = folder.count == 0
        let r = folder.syncWithDisk(removing: removing)
        if !removing, !r.missing.isEmpty {
            pendingRemovalCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.folderDidChange(removing: true) }
            pendingRemovalCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
        let removed = removing ? r.missing : []
        guard !r.added.isEmpty || !removed.isEmpty else { return }
        for u in removed { loader.evict(url: u); prefetchedURLs.remove(u) }
        #if FLIPIC_PRO
        if !r.added.isEmpty { applyMergePairs(keep: folder.current?.url) }
        #endif
        filmstrip.collectionView.reloadData()
        if folder.count == 0 {
            imageView.set(image: nil, resetToFit: true, isNew: true)
            emptyState.isHidden = false
            emptyHint.stringValue = L10n.t("ui.noMore", "文件夹里没有更多图片了")
            updateControlsPresence()
            updateHUD()
        } else if wasEmpty || folder.current?.url != before {
            emptyState.isHidden = true
            updateControlsPresence()
            showImage(resetToFit: true)
            filmstrip.scrollTo(index: folder.index)
        } else {
            syncFilmstripSelection()
            updateHUD()
        }
    }

    /// 文件夹里有照片被别的软件改过：清掉旧缓存、刷新缩略图；正在看的这张原地换成新的，缩放和位置不动
    private func reloadChangedFiles() {
        guard folder.count > 0 else { return }
        let changed = folder.takeModifiedOutside()
        guard !changed.isEmpty else { return }
        for u in changed { loader.evict(url: u) }
        prefetchedURLs.subtract(changed)
        let rows = changed.compactMap { u in folder.items.firstIndex { $0.url == u } }
        filmstrip.collectionView.reloadItems(at: Set(rows.map { IndexPath(item: $0, section: 0) }))
        guard let url = folder.current?.url, changed.contains(url) else { return }
        guard mainViewerActive else { showImage(resetToFit: false); return }
        // 直接解全分辨率：放大着看的时候不用再等一轮
        generation += 1
        let gen = generation
        fullRequested = true
        let loader = self.loader
        decodeQueue.addOperation { [weak self] in
            guard self?.generation == gen, let info = loader.info(for: url) else { return }
            let full = info.isAnimated ? nil : loader.fullImage(for: url)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                // 动图走原来的播放流程
                guard let full else { self.showImage(resetToFit: false); return }
                self.shown = .sharp
                self.adopt(full, logicalSize: info.pixelSize, resetToFit: false, isNew: false)
                self.updateExifPanel()
                self.loadRating(for: url)
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
                self.shown = .sharp
                self.adopt(full, logicalSize: info.pixelSize, resetToFit: false, isNew: false)
            }
        }
    }

    private func adopt(_ image: CGImage, logicalSize: CGSize, resetToFit: Bool, isNew: Bool, draft: Bool = false) {
        folder.setCurrentPixelSize(logicalSize)
        imageView.set(image: image, logicalSize: logicalSize, resetToFit: resetToFit, isNew: isNew, draft: draft)
        if isNew { BenchProbe.adopted() } else if !draft { BenchProbe.fullWidth = image.width }
        if !draft { BenchProbe.sharpShown() }
        if !draft { scheduleLiveText() }
        #if FLIPIC_PRO
        if isNew { restoreZoomAfterPaging() }
        #endif
        if isNew, peekSaved != nil { wrapWindowToImage(keepingCurrent: Self.peekKeepsPosition) }
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
    var debugHasImage: Bool { imageView.debugHasImage }
    var debugShownLevel: String {
        let px = imageView.debugImage.map { "\($0.width)x\($0.height)" } ?? "-"
        return "\(shown) \(px) of \(Int(imageView.pixelSize.width))x\(Int(imageView.pixelSize.height)) \(folder.current?.url.lastPathComponent ?? "")"
    }

    func navigate(_ delta: Int) {
        // 手动翻页不带幻灯片的渐变
        if !advancingSlideshow { imageView.pendingFadeDuration = nil }
        if BenchProbe.traceNav { NSLog("TRACE navigate delta=%d slideshow=%d from=%d", delta, advancingSlideshow ? 1 : 0, folder.index) }
        if CommandLine.arguments.contains("--selftest") {
            NSLog("SELFTEST navigate delta=\(delta) index \(folder.index) ->")
        }
        // 挑片时按住方向键一路翻，到头了不能悄悄绕回第一张，不然会把挑过的又挑一遍
        if !advancingSlideshow, !Self.wrapAround, folder.count > 0, !(0..<folder.count).contains(folder.index + delta) {
            bounceAtEnd(delta)
            return
        }
        lastNavDirection = delta
        showFirstAfterResort = false
        notePagingStep()
        #if FLIPIC_PRO
        rememberZoomForPaging()
        #endif
        folder.go(delta)
        showImage(resetToFit: false)
    }

    func goTo(_ index: Int) {
        lastNavDirection = index >= folder.index ? 1 : -1
        showFirstAfterResort = false
        notePagingStep()
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
    /// 每次翻页重排预取队列：离当前最近的先解，快速连翻时过期任务直接取消。
    /// prefetch = false 时只淘汰不预取（快速连翻中）；after 给出时等当前这张的清晰图解完再开始预取
    private func updateSmartCache(prefetch: Bool = true, after: Operation? = nil) {
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

        // 告诉 ImageLoader 当前看哪张：内存吃紧时留前后 2 张预览、胶片条预热范围内的缩略图
        let items = folder.items
        let dir = lastNavDirection >= 0 ? 1 : -1
        let around = { (r: Int) in Set((-r...r).map { items[((i + $0) % n + n) % n].url }) }
        let near = around(min(CachePolicy.pressureNear, n / 2))
        let draftKeep = Set((1...CachePolicy.draftKeepAhead).map { items[((i + dir * $0) % n + n) % n].url })
        loader.setFocus(owner: self, current: folder.items[i].url, near: near, ahead: draftKeep,
                        wide: around(min(CachePolicy.warmupLimit / 2, n / 2)))

        prefetchQueue.cancelAllOperations()
        guard prefetch else { return }
        // 不在快速连翻了：草图交给清晰预览，只留当前这张的（它的清晰图可能还在解）
        loader.trimDrafts(keeping: [folder.items[i].url])
        let ahead = lastNavDirection >= 0 ? CachePolicy.previewAhead : CachePolicy.previewBehind
        let behind = lastNavDirection >= 0 ? CachePolicy.previewBehind : CachePolicy.previewAhead
        var order: [URL] = []
        for step in 1...max(ahead, behind) {
            if step <= ahead { order.append(folder.items[(i + step) % n].url) }
            if step <= behind { order.append(folder.items[((i - step) % n + n) % n].url) }
        }
        let current = folder.items[i].url
        let fitPx = previewPixelTarget
        for url in order where url != current {
            prefetchedURLs.insert(url)
            if loader.cachedPreview(for: url, maxPixel: fitPx) != nil { continue }
            let op = BlockOperation {
                _ = loader.info(for: url)
                _ = loader.preview(for: url, maxPixel: fitPx)
            }
            if let after { op.addDependency(after) }
            prefetchQueue.addOperation(op)
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
    func updateHUD() {
        guard !isFlashing else { return }
        hudView.isHidden = true
    }

    /// 异步读取当前图的 EXIF 摘要与文件大小，读完后刷新信息条

    /// 面板打开时才读完整 EXIF，在后台读完再回主线程排版
    func updateExifPanel() {
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

        let title = NSTextField(labelWithString: currentIsVideo ? L10n.t("ui.videoInfoTitle", "视频信息") : L10n.t("ui.exifTitle", "照片信息"))
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

    /// 只改选中态，不 reloadData（整条重建会让所有可见格子重新取缩略图）。
    /// 翻页、换筛选等都会回到只选当前这张；在多选里点来点去时保留多选
    func syncFilmstripSelection() {
        let cv = filmstrip.collectionView
        guard !folder.items.isEmpty else { return }
        let target = IndexPath(item: folder.index, section: 0)
        if keepStripSelection, cv.selectionIndexPaths.contains(target) { return }
        stripAnchor = nil
        if cv.selectionIndexPaths == [target] { return }
        cv.deselectAll(nil)
        cv.selectItems(at: Set([IndexPath(item: folder.index, section: 0)]),
                       scrollPosition: [.centeredHorizontally])
    }

    // MARK: - 缩略图栏多选

    /// ⇧ 点击从这张开始选一段；没有就从当前照片开始
    private var stripAnchor: Int?
    /// 多选里换着看某一张时，showImage 不把多选收成一张
    private var keepStripSelection = false

    /// 缩略图栏里 ⇧ / ⌘ 多选的照片，按列表顺序；平时只选当前这张时是空的
    var stripPicked: [URL] {
        guard cleanup == nil, compareView == nil else { return [] }
        let sel = filmstrip.collectionView.selectionIndexPaths.map(\.item).filter { folder.items.indices.contains($0) }
        return sel.count > 1 ? sel.sorted().map { folder.items[$0].url } : []
    }

    /// 多选时是选中的那些，否则是当前这张
    private var actionURLs: [URL] {
        let picked = stripPicked
        if !picked.isEmpty { return picked }
        return folder.current.map { [$0.url] } ?? []
    }

    /// 和访达一样：⇧ 点击选中一段，⌘ 点击加上或去掉一张（⌃ 也算，照顾用惯 Windows 的人），⇧⌘ 再加一段
    func filmstripClicked(_ i: Int, _ mods: NSEvent.ModifierFlags) {
        guard folder.items.indices.contains(i) else { return }
        if compareView != nil {
            compareShow(i)
            return
        }
        let cv = filmstrip.collectionView
        var sel = Set(cv.selectionIndexPaths.map(\.item).filter { folder.items.indices.contains($0) })
        let toggle = mods.contains(.command) || mods.contains(.control)
        if cleanup == nil, mods.contains(.shift) {
            let a = stripAnchor ?? folder.index
            stripAnchor = a
            let range = Set(min(a, i)...max(a, i))
            sel = toggle ? sel.union(range) : range
        } else if cleanup == nil, toggle {
            if sel.contains(i) { if sel.count > 1 { sel.remove(i) } } else { sel.insert(i) }
            stripAnchor = i
        } else {
            sel = [i]
        }
        // 显示点的那张；⌘ 点掉一张时停在正在看的这张，点掉的就是它时换成离它最近的一张选中的
        let show = sel.contains(i) ? i : sel.contains(folder.index) ? folder.index
            : sel.min { (abs($0 - i), $0) < (abs($1 - i), $1) } ?? i
        keepStripSelection = sel.count > 1
        cv.selectionIndexPaths = Set(sel.map { IndexPath(item: $0, section: 0) })
        if show != folder.index {
            folder.jump(to: show)
            showImage(resetToFit: false)
        } else if sel.count == 1 {
            stripAnchor = nil
        }
        keepStripSelection = false
        view.window?.makeFirstResponder(imageView)
        if sel.count > 1 { flash(L10n.f("msg.picked", "已选 %d 张", sel.count), seconds: 1.2) }
    }

    /// 从缩略图栏拖出去的文件：按在多选里就是整组，连同藏起来的同名 RAW / JPG
    private func filmstripDragURLs(from i: Int) -> [URL] {
        guard cleanup == nil, folder.items.indices.contains(i) else { return [] }
        let picked = stripPicked
        let urls = picked.contains(folder.items[i].url) ? picked : [folder.items[i].url]
        return folder.withHiddenPartners(urls)
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
        let urls = actionURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func trashCurrent(_ sender: Any?) {
        let picked = stripPicked
        if !picked.isEmpty { trashPicked(picked); return }
        exitCompare()
        guard let item = folder.current else { return }
        let gen = generation
        // 合并显示的那一对、实况照片的同名 MOV、设好的附属文件一起删
        var urls = folder.withHiddenPartners([item.url])
        for u in urls { for f in Self.companions(of: u) where !urls.contains(f) { urls.append(f) } }
        if Trash.usesLocalCopy(urls) { flash(L10n.t("trash.copying", "正在复制到本机废纸篓…"), seconds: 600) }
        Trash.trash(urls) { [weak self] out in
            // 记下来，⌘Z 或「放回刚才删掉的照片」能放回去
            if !out.moved.isEmpty { Self.lastTrash = TrashRecord(moved: out.moved, photo: item.url) }
            guard let self, self.generation == gen else { return }
            let gone = Set(out.moved.keys)
            for u in gone { self.loader.evict(url: u) }
            // 只有真挪走了的才从列表里拿掉：没挪动的（盘只读、没权限）留在原处，不能假装删了
            let currentGone = gone.contains(item.url)
            if currentGone { _ = self.folder.removeCurrent() }
            let others = gone.subtracting([item.url])
            if !others.isEmpty { self.folder.remove(urls: others) }
            if currentGone {
                if self.folder.count > 0 {
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
            } else {
                self.filmstrip.collectionView.reloadData()
            }
            self.flash(Trash.summary(out, count: gone.count), seconds: 3)
        }
    }

    /// 多选的几张一起移到废纸篓，同名搭档和附属文件跟着走；⌘Z 能一起放回
    private func trashPicked(_ picked: [URL]) {
        let gen = generation
        var urls = folder.withHiddenPartners(picked)
        for u in urls { for f in Self.companions(of: u) where !urls.contains(f) { urls.append(f) } }
        if Trash.usesLocalCopy(urls) { flash(L10n.t("trash.copying", "正在复制到本机废纸篓…"), seconds: 600) }
        Trash.trash(urls) { [weak self] out in
            if !out.moved.isEmpty { Self.lastTrash = TrashRecord(moved: out.moved, photo: nil) }
            guard let self, self.generation == gen else { return }
            let gone = Set(out.moved.keys)
            for u in gone { self.loader.evict(url: u) }
            if !gone.isEmpty { self.folder.remove(urls: gone) }
            self.filmstrip.collectionView.reloadData()
            if self.folder.count > 0 {
                self.showImage(resetToFit: false)
            } else {
                self.imageView.set(image: nil, resetToFit: true, isNew: true)
                self.emptyState.isHidden = false
                self.updateControlsPresence()
                self.emptyHint.stringValue = L10n.t("ui.noMore", "文件夹里没有更多图片了")
                self.updateHUD()
            }
            self.flash(Trash.summary(out, count: gone.count), seconds: 3)
        }
    }

    // MARK: - 放回刚才删掉的照片

    /// 一次删除：原位置 → 废纸篓里的位置。photo 是单张删除时删掉的那张，放回后显示它；批量删除时为 nil
    struct TrashRecord {
        let moved: [URL: URL]
        let photo: URL?
    }

    private static var storedTrash: TrashRecord?

    /// 最近一次删除。单张删除和 Pro 的批量删除共用这一份，新的删除覆盖旧的；所有看图窗口共用。
    /// 同时存一份到磁盘：退出重开、装上更新以后，「放回」和「在 Finder 中显示」还能用
    static var lastTrash: TrashRecord? {
        get { storedTrash }
        set {
            storedTrash = newValue
            TrashLedger.save(newValue)
        }
    }

    static var canRestoreTrash: Bool { lastTrash != nil }

    /// 文件菜单「放回刚才删掉的照片」：文件挪回原处，重新打开那个文件夹
    @objc func restoreLastTrash(_ sender: Any?) {
        guard let rec = Self.lastTrash, let dir = (rec.photo ?? rec.moved.keys.first)?.deletingLastPathComponent() else { return }
        Self.lastTrash = nil
        let fm = FileManager.default
        var back: [URL] = []
        for (orig, trashed) in rec.moved where !fm.fileExists(atPath: orig.path) {
            if (try? fm.moveItem(at: trashed, to: orig)) != nil { back.append(orig) }
        }
        // 单张：显示放回来的那张；批量：留在原来看的那张，它也不在了就打开文件夹
        let cur = folder.current?.url
        let show = rec.photo.flatMap { back.contains($0) ? $0 : nil }
            ?? cur.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? dir
        open(url: show)
        flash(L10n.f("pro.restored", "已放回 %d 个文件", back.count), seconds: 2.5)
    }

    /// 编辑菜单的「撤销」（⌘Z）：在输入框里时照常撤销文字，否则放回刚才删掉的照片
    @objc func undo(_ sender: Any?) {
        if let w = view.window, w.firstResponder is NSText { w.undoManager?.undo(); return }
        restoreLastTrash(sender)
    }

    /// 文件菜单「在 Finder 中显示刚才删掉的照片」：外置盘的照片进的是那块盘自己的废纸篓，
    /// 本机废纸篓里翻不到，用这个直接跳到它们现在待的地方
    @objc func revealLastTrash(_ sender: Any?) {
        guard let rec = Self.lastTrash else { return }
        Trash.revealInFinder(rec.moved.values.sorted { $0.path < $1.path })
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
        // 看视频时自己按了 T：以用户为准，离开视频时不再自动放回来
        filmstripHiddenForVideo = false
        let show = filmstrip.isHidden
        filmstrip.isHidden = !show
        filmstripHeight.constant = show ? FilmstripView.stripHeight : 0
    }

    @objc func toggleToolbar(_ sender: Any?) {
        Self.showToolbar.toggle()
        SettingsWindowController.notify("toolbar")
        if Self.showToolbar { pokeControls() }
    }

    /// 到头了：照片朝按的方向挪一点再弹回来，并提示已是第一张 / 最后一张
    private func bounceAtEnd(_ delta: Int) {
        imageView.bounce(direction: delta)
        flash(delta > 0 ? L10n.t("msg.atLast", "已是最后一张") : L10n.t("msg.atFirst", "已是第一张"), seconds: 1.0)
        if CommandLine.arguments.contains("--wraptest") { NSLog("WRAPTEST bounce delta=%d index=%d", delta, folder.index) }
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
    func perform(_ action: ShortcutAction) {
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
        case .pinWindow: togglePinned(nil)
        case .share: shareCurrent(nil)
        case .playLive: playLivePhoto(nil)
        case .copyText: copyAllText(nil)
        case .zoomEye:
            #if FLIPIC_PRO
            zoomToEye(nil)
            #endif
        #if FLIPIC_PRO
        case .beforeAfter: toggleBeforeAfter(nil)
        case .splitByRating: splitByRating(nil)
        case .switchPair: switchPairMember(nil)
        case .searchContent: searchContent(nil)
        #endif
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
            let hideTools = !Self.showToolbar || folder.current == nil || !controlsVisible
            toolbarView.isHidden = hideTools || video.isActive
            toolbarView.alphaValue = toolbarView.isHidden ? 0 : 1
            cornerBar.isHidden = hideTools
            cornerBar.alphaValue = hideTools ? 0 : 1
        case "videos":
            // 重新列一遍文件夹；正在看的视频被关掉了就回到文件夹开头
            guard let dir = folder.folderURL else { break }
            let cur = folder.current?.url
            open(url: cur.map { Video.isVideo($0) && !Video.enabled ? dir : $0 } ?? dir)
        case "fileName":
            fileNameBar.isHidden = !Self.showFileName || folder.current == nil || !controlsVisible
            fileNameBar.alphaValue = fileNameBar.isHidden ? 0 : 1
            ratingBadgeBottom.constant = ratingBadgeOffset(controls: controlsVisible)
        case "thumbs":
            // 缩略图大小变了：格子、栏高一起改，按新尺寸重新取缩略图
            filmstrip.applyThumbSize()
            if filmstripHeight.constant > 0 { filmstripHeight.constant = FilmstripView.stripHeight }
            ratingBadgeBottom.constant = ratingBadgeOffset(controls: controlsVisible)
            filmstrip.collectionView.reloadData()
            syncFilmstripSelection()
            if imageView.isFit { imageView.fit() }
        case "backdrop":
            applyBackdropStyle()
        case "liveText":
            scheduleLiveText(restart: true)
        case "hdr":
            // 解码方式变了，缓存里的图作废，当前这张重新解码
            loader.purge()
            showImage(resetToFit: false)
        default: break
        }
    }

    /// 工具条按钮的提示跟着自定义快捷键走
    private var shortcutTips: [(button: NSButton, base: String, action: ShortcutAction)] = []

    #if FLIPIC_PRO
    @objc func openWorkbench(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showWorkbench(opening: folder.current?.url, in: view.window)
    }
    #endif

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
        video.clear()
        if let cleanup {
            cleanup.finish(nil)
            return
        }
        guard let current = folder.current else { return }
        stopSlideshow()
        imageView.endPeek()
        if folder.markedOnly { toggleMarkedOnly(nil) }
        #if FLIPIC_PRO
        closeContentSearch()
        #endif
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

    func flash(_ msg: String, seconds: Double = 2) {
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

    // MARK: - 图中文字

    /// 停在一张照片上多久才分析：每翻一页都从头计时，连翻时一直往后推，不会分析
    private static let liveTextDwell: CFTimeInterval = 0.5

    /// restart：换了图（或旋转、改了设置），先收掉上一张的结果，从现在起重新计停留时间
    private func scheduleLiveText(restart: Bool = false) {
        guard let liveText else { return }
        if restart {
            liveText.reset()
            liveTextGen = -1
            liveTextStepAt = CFAbsoluteTimeGetCurrent()
        }
        liveTextWork?.cancel()
        liveTextWork = nil
        guard TextRecognition.autoAnalyze, liveTextGen != generation else { return }
        let wait = max(Self.liveTextDwell - (CFAbsoluteTimeGetCurrent() - liveTextStepAt), 0.05)
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            self.liveTextWork = nil
            self.startLiveTextIfSettled()
        }
        liveTextWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// 只分析停下来以后屏幕上的清晰图（预览；放大后已经换成原图就用原图），草图、动图、对比、清理、放映时都不分析
    private func startLiveTextIfSettled() {
        guard let liveText, TextRecognition.autoAnalyze, !currentIsVideo, liveTextGen != generation, shown == .sharp, !rapidPaging,
              mainViewerActive, cleanup == nil, slideshowTimer == nil, !imageView.isAnimated,
              let image = textSourceImage() else { return }
        liveTextGen = generation
        liveText.analyze(image)
    }

    /// 实测 7000 像素宽的图能分析，4500 万像素（8256 宽）的原图系统直接分析失败
    private static let textMaxPixel = 7000

    /// 识别文字用的图：屏幕上的图（放大后已经换成原图就是原图）；原图大到系统分析不了时，改用同一张的屏幕尺寸预览
    private func textSourceImage() -> CGImage? {
        guard let image = imageView.currentImage else { return nil }
        if max(image.width, image.height) <= Self.textMaxPixel { return image }
        guard let url = folder.current?.url, let pv = loader.cachedPreview(for: url, maxPixel: previewPixelTarget) else { return nil }
        let turns = imageView.rotationTurns
        return turns == 0 ? pv : ImageLoader.rotated(pv, quarterTurns: turns)
    }

    /// 测试用：最近一次「复制图中全部文字」用的是现成的分析结果还是重新识别
    private(set) var debugCopyTextSource = ""

    /// 照片菜单、右键菜单：把整张图的文字放到剪贴板。这张已经分析过就直接用，否则现场识别
    @objc func copyAllText(_ sender: Any?) {
        guard TextRecognition.isAvailable, mainViewerActive, cleanup == nil, let image = textSourceImage() else { return }
        if let t = liveText?.transcript {
            debugCopyTextSource = "analysis"
            finishCopyText(TextRecognition.lines(of: t))
            return
        }
        debugCopyTextSource = "vision"
        TextRecognition.recognizeLines(in: image) { [weak self] lines in self?.finishCopyText(lines) }
    }

    /// 「编辑 › 拷贝」（⌘C）：照片上选中了文字时拷贝选中的部分；否则拷贝照片文件（多选时是选中的那些），
    /// 到访达里粘贴就是复制过去，也能粘贴到聊天窗口
    @objc func copy(_ sender: Any?) {
        if liveText?.hasTextSelection == true {
            liveText?.copySelection()
            return
        }
        let picked = actionURLs
        guard cleanup == nil, !picked.isEmpty else { return }
        let files = folder.withHiddenPartners(picked)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files.map { $0 as NSURL })
        flash(L10n.f("msg.copiedPhotos", "已拷贝 %d 张照片，可以到访达里粘贴", picked.count), seconds: 2)
    }

    private func finishCopyText(_ lines: [String]) {
        guard !lines.isEmpty else {
            flash(L10n.t("ocr.none", "图中没有识别到文字"))
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
        flash(lines.count == 1 ? L10n.t("ocr.copied1", "已复制 1 行文字") : L10n.f("ocr.copied", "已复制 %d 行文字", lines.count))
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
    var slideshowActive: Bool { slideshowTimer != nil || slideshowPaused }

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

    func stopSlideshow() {
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
        applyBackdropStyle()
    }

    /// 进入全屏完成后再换底：在「将要进入」时换，进入失败（被取消）窗口就一直是不透明的
    @objc private func windowDidEnterFullScreen(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        applyBackdropStyle(fullScreen: true)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        stopSlideshow()
        #if FLIPIC_PRO
        contentSearchWindowWillClose()
        #endif
        // 贴合照片比例时关窗：先回到普通大小，记住的是普通窗口的位置和大小，不是那个照片形状的小窗
        if let saved = peekSaved { view.window?.setFrame(saved.frame, display: false) }
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

    static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// 交给后期软件的文件：当前是 JPG 等、同名 RAW 也在时用 RAW，后期一般修 RAW
    private func editTargetURL() -> URL? {
        folder.current.map { editTargetURL(for: $0.url) }
    }

    /// 多选时交给后期软件的那些文件
    private func editTargetURLs() -> [URL] {
        var out: [URL] = []
        for u in actionURLs.map(editTargetURL(for:)) where !out.contains(u) { out.append(u) }
        return out
    }

    private func editTargetURL(for url: URL) -> URL { Self.editTarget(for: url) }

    /// 工作台也用：同名 RAW 在就交 RAW
    static func editTarget(for url: URL) -> URL {
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

    /// 测试用：不真的打开后期软件，只记下要送过去的文件
    var debugOpenedFiles: [URL]?

    private func open(_ files: [URL], with app: URL) {
        guard let first = files.first else { return }
        if debugOpenedFiles != nil { debugOpenedFiles = files; return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.flash(L10n.f("msg.openFailed", "无法用 %1$@ 打开：%2$@", Self.appName(app), error.localizedDescription), seconds: 4)
                } else if files.count > 1 {
                    self?.flash(L10n.f("pro.openedAll", "已把 %1$d 张照片送进 %2$@", files.count, Self.appName(app)), seconds: 3)
                } else {
                    self?.flash(L10n.f("msg.openedIn", "已用 %1$@ 打开 %2$@", Self.appName(app), first.lastPathComponent))
                }
            }
        }
    }

    /// ⌘E：用设好的后期软件打开当前照片（多选时是选中的那些）；还没设就先选一个
    @objc func openInEditor(_ sender: Any?) {
        let files = editTargetURLs()
        guard !files.isEmpty else { return }
        if let app = editorAppURL {
            open(files, with: app)
        } else {
            pickApplication { [weak self] app in
                self?.editorAppURL = app
                self?.open(files, with: app)
            }
        }
    }

    @objc func chooseEditor(_ sender: Any?) {
        pickApplication { [weak self] app in
            self?.editorAppURL = app
            self?.flash(L10n.f("msg.editorSet", "后期软件：%@ · ⌘E 打开当前照片", Self.appName(app)), seconds: 3)
        }
    }

    func pickApplication(_ done: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        Self.pickApplication(in: window, done)
    }

    static func pickApplication(in window: NSWindow, _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L10n.t("panel.chooseEditor", "选择后期软件")
        panel.prompt = L10n.t("panel.choose", "选择")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
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
        guard let app = sender.representedObject as? URL else { return }
        open(editTargetURLs(), with: app)
    }

    @objc private func openWithOther(_ sender: Any?) {
        let files = editTargetURLs()
        guard !files.isEmpty else { return }
        pickApplication { [weak self] app in self?.open(files, with: app) }
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
        add(markMenuTitle, #selector(toggleMark(_:)))
        add(L10n.t("menu.markedOnly", "只看已标记"), #selector(toggleMarkedOnly(_:)))
        add(L10n.t("menu.exportFolder", "导出到文件夹…"), #selector(exportToFolder(_:)))
        add(L10n.t("menu.share", "分享…"), #selector(shareCurrent(_:)))
        if TextRecognition.isAvailable { add(L10n.t("menu.copyText", "复制图中全部文字"), #selector(copyAllText(_:))) }
        menu.addItem(.separator())
        add(L10n.t("menu.reveal", "在 Finder 中显示"), #selector(revealInFinder(_:)))
        add(L10n.t("menu.trash", "移到废纸篓"), #selector(trashCurrent(_:)))
        return menu
    }

    // MARK: - 评分

    /// 读过的评分；写入后同步更新，避免每次翻页都去读文件
    var ratingCache: [URL: Int] = [:]
    let ratingQueue = DispatchQueue(label: "flipic.rating", qos: .userInitiated)

    var currentRating: Int { folder.current.flatMap { ratingCache[$0.url] } ?? 0 }

    func loadRating(for url: URL) {
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
    func ratingTargets(for url: URL) -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        let siblings = folder.allItems.map(\.url).filter {
            $0 != url && $0.deletingLastPathComponent() == dir && $0.deletingPathExtension().lastPathComponent == base
        }
        return [url] + siblings
    }

    func setRating(_ stars: Int) {
        guard cleanup == nil, folder.current != nil else { return }
        var targets: [URL] = []
        for u in actionURLs { for t in ratingTargets(for: u) where !targets.contains(t) { targets.append(t) } }
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

    func updateRatingLabel() {
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

    /// 多选时菜单写明是几张
    private var markMenuTitle: String {
        let picked = stripPicked
        guard !picked.isEmpty else { return Self.markMenuTitle(folder.current?.marked ?? false) }
        return pickedAllMarked(picked) ? L10n.f("menu.unmarkPicked", "取消标记选中的 %d 张", picked.count)
            : L10n.f("menu.markPicked", "标记选中的 %d 张", picked.count)
    }

    private func pickedAllMarked(_ picked: [URL]) -> Bool {
        let set = Set(picked)
        return folder.items.filter { set.contains($0.url) }.allSatisfy(\.marked)
    }

    /// 标记 / 取消标记当前照片；多选时选中的几张有没标的就全标上，都标过就全取消；同名的 RAW 和 JPG 一起标
    @objc func toggleMark(_ sender: Any?) {
        guard cleanup == nil, let item = folder.current else { return }
        let picked = stripPicked
        let on = picked.isEmpty ? !item.marked : !pickedAllMarked(picked)
        var targets: [URL] = []
        for u in actionURLs { for t in ratingTargets(for: u) where !targets.contains(t) { targets.append(t) } }
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
        loadMissingRatings(finish)
    }

    /// 星级只在翻到某张时才读，要按星级处理整个文件夹前先把没读过的都读一遍（只读元数据，很快）
    func loadMissingRatings(_ then: @escaping () -> Void) {
        let missing = folder.urlsMissingRating
        guard !missing.isEmpty else { then(); return }
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
                then()
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

    func updateMarkedOnlyPill() {
        markedOnlyPill.isHidden = folder.filter == nil || cleanup != nil
        #if FLIPIC_PRO
        // 按内容查找时顶部是搜索框，不显示这一条
        contentSearchFilterDidChange()
        if case .content = folder.filter { markedOnlyPill.isHidden = true }
        #endif
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
        let picked = stripPicked
        exitCompare()
        let shown = picked.isEmpty ? folder.items.map(\.url) : picked
        let urls = folder.withHiddenPartners(shown)
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
        panel.message = picked.isEmpty ? exportSummary(count: folder.items.count)
            : L10n.f("exp.f.summaryPicked", "导出选中的 %d 张照片", picked.count)
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
        #if FLIPIC_PRO
        case .content(let m): return L10n.f("exp.f.summaryContent", "导出当前显示的 %1$d 张照片（按内容查找「%2$@」）", count, m.query)
        #endif
        }
    }

    /// 同名的一组文件（比如 RAW 的星级旁车 .xmp）一起走，用同一个新名字；目标里已有同名文件时加编号，不覆盖。
    /// 在后台线程跑；progress 收到已处理的张数
    /// 跟着照片一起复制、移动、删除的附属文件（Pro 里可以设扩展名）；nil 时只带星级用的 .xmp
    static var linkedFiles: ((URL) -> [URL])?

    /// 跟照片绑在一起的文件：实况照片的同名 .MOV，加上 Pro 里设的附属文件
    static func companions(of url: URL) -> [URL] {
        var out: [URL] = []
        if let mov = LivePhoto.movie(for: url) { out.append(mov) }
        for f in linkedFiles?(url) ?? [] where !out.contains(f) { out.append(f) }
        return out
    }

    /// 照片改了名，同名的 .MOV 和星级 .xmp 跟着改成同一个名字；目标已有同名文件就不动它
    static func renameCompanions(of old: URL, to new: URL) {
        let fm = FileManager.default
        var files = companions(of: old)
        let side = Rating.sidecarURL(for: old)
        if fm.fileExists(atPath: side.path), !files.contains(side) { files.append(side) }
        let base = new.deletingPathExtension()
        for f in files {
            let dest = base.appendingPathExtension(f.pathExtension)
            guard dest.path != f.path, !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.moveItem(at: f, to: dest)
        }
    }

    static func transfer(_ urls: [URL], to target: URL, move: Bool,
                         progress: ((Int) -> Void)? = nil) -> (done: Set<URL>, failed: Int) {
        let fm = FileManager.default
        var groups: [(base: String, files: [URL])] = []
        var groupIndex: [String: Int] = [:]
        for u in urls {
            let base = u.deletingPathExtension().lastPathComponent
            var files = [u]
            let side = Rating.sidecarURL(for: u)
            if fm.fileExists(atPath: side.path) { files.append(side) }
            for f in companions(of: u) where !files.contains(f) { files.append(f) }
            if let gi = groupIndex[base] {
                for f in files where !groups[gi].files.contains(f) { groups[gi].files.append(f) }
            } else {
                groupIndex[base] = groups.count
                groups.append((base, files))
            }
        }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
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
            progress?(processed)
        }
        return (done, failed)
    }

    /// 移走的照片从列表里拿掉，显示剩下的；全移走了就回到全部照片或空状态
    func removeTransferred(_ done: Set<URL>) {
        guard !done.isEmpty else { return }
        for u in done { loader.evict(url: u) }
        folder.remove(urls: done)
        prefetchedURLs.removeAll()
        filmstrip.collectionView.reloadData()
        if folder.count > 0 {
            showImage(resetToFit: true)
        } else if folder.filter != nil, folder.setFilter(nil), folder.count > 0 {
            // 筛出来的都移走了，回到剩下的全部照片
            filmstrip.collectionView.reloadData()
            showImage(resetToFit: true)
        } else {
            imageView.set(image: nil, resetToFit: true, isNew: true)
            emptyState.isHidden = false
            updateControlsPresence()
            emptyHint.stringValue = L10n.t("ui.noMore", "文件夹里没有更多图片了")
        }
        updateMarkedOnlyPill()
    }

    private func runFolderExport(_ urls: [URL], to target: URL, from source: URL, move: Bool) {
        guard target.standardizedFileURL.path != source.standardizedFileURL.path else {
            flash(L10n.t("msg.exportSameFolder", "目标就是当前文件夹，换一个文件夹"), seconds: 3)
            return
        }
        isProcessing = true
        let total = urls.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (done, failed) = Self.transfer(urls, to: target, move: move) { processed in
                guard total > 30, processed % 20 == 0 else { return }
                DispatchQueue.main.async { self?.flash(L10n.f("msg.batchProgress", "正在处理 %1$d / %2$d", processed, total), seconds: 5) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                let folderName = target.lastPathComponent
                var msg = move ? L10n.f("msg.exportedMove", "已移动 %1$d 张到「%2$@」", done.count, folderName)
                               : L10n.f("msg.exportedCopy", "已复制 %1$d 张到「%2$@」", done.count, folderName)
                if failed > 0 { msg += " · " + L10n.f("msg.batchFailed", "%d 个文件没能处理", failed) }
                if move { self.removeTransferred(done) }
                self.flash(msg, seconds: 3.5)
            }
        }
    }

    // MARK: - 并排对比

    /// 非 nil 时在并排对比：2 格或 4 格，各格缩放和位置同步，当前格的照片就是 folder.current
    var compareView: CompareView?
    #if FLIPIC_PRO
    /// 非 nil 时在修图前后对比
    var beforeAfter: BeforeAfterView?
    #endif
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
        video.clear()
        if let cv = compareView, cv.panes.count == 2 { exitCompare() } else { enterCompare(2) }
    }

    @objc func toggleCompare4(_ sender: Any?) {
        if let cv = compareView, cv.panes.count >= 3 { exitCompare() } else { enterCompare(4) }
    }

    private func enterCompare(_ want: Int) {
        #if FLIPIC_PRO
        exitBeforeAfter()
        #endif
        guard cleanup == nil, folder.count >= 2 else {
            flash(L10n.t("msg.compareNeedsTwo", "至少要两张照片才能并排对比"))
            return
        }
        if slideshowActive { stopSlideshow() }
        imageView.endPeek()
        // 缩略图栏里多选了几张：就对比选中的这几张（最多 4 张），不再从当前这张往后排
        let picked = compareView == nil
            ? filmstrip.collectionView.selectionIndexPaths.map(\.item).filter { folder.items.indices.contains($0) }.sorted()
            : []
        let usePicked = picked.count >= 2
        if usePicked, picked.count > 4 {
            flash(L10n.f("msg.compareFirstFour", "选了 %d 张，只对比前 4 张", picked.count))
        }
        let n = usePicked ? min(picked.count, 4) : min(want, folder.count)
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
        // 4 格时按 C 缩成 2 格：正在看的那格要是被去掉了，把它的照片挪进留下的最后一格
        let activePhoto = cv.panes.indices.contains(compareActive) ? cv.panes[compareActive].photoIndex : nil
        // 格数一变格子大小就变，放大中的格子会保持绝对像素比例，看起来一下放大好几倍。
        // 记下各格相对适应窗口的缩放和中心，布局完照原样摆回去
        let states = cv.panes.map { $0.imageView.debugHasImage ? $0.imageView.viewState : nil }
        let shared = compareState
        compareLoading = true   // 布局引起的缩放变化不回传成共享状态
        cv.setPaneCount(n)
        cv.layoutSubtreeIfNeeded()
        for (i, s) in states.prefix(n).enumerated() { if let s { cv.panes[i].imageView.applyViewState(s) } }
        compareLoading = false
        compareState = shared
        if n < startCount, compareActive >= n, let activePhoto {
            loadPane(cv.panes[n - 1], index: activePhoto)
            compareActive = n - 1
        }
        var next = startCount == 0 ? folder.index : (used.max() ?? folder.index) + 1
        for i in startCount..<max(startCount, n) {
            while used.contains(next % folder.count) { next += 1 }
            let idx = usePicked ? picked[i] : next % folder.count
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
        #if FLIPIC_PRO
        exitBeforeAfter()
        #endif
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
        // 删除键设成单个键（比如 ⌫）时对比里也能删，和 ⌘⌫ 走菜单一样
        iv.onTrash = { [weak self] in self?.trashCurrent(nil) }
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
            fileNameLabel.stringValue = url.lastPathComponent
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

    // MARK: - 背景

    override func viewWillAppear() {
        super.viewWillAppear()
        applyBackdropStyle()
    }

    /// 磨砂玻璃要窗口本身透明，纯黑和照片色磨砂用不透明的深色底。
    /// 全屏时窗口后面没有桌面可透，系统只会透出全屏空间的底色（常常发蓝），改成在窗口里渲染的中性深灰
    func applyBackdropStyle(fullScreen: Bool? = nil) {
        let style = ZoomableImageView.backdropStyle
        let isFull = fullScreen ?? (view.window?.styleMask.contains(.fullScreen) ?? false)
        glassView.blendingMode = isFull ? .withinWindow : .behindWindow
        let glass = style == .glass && !isFull
        // 全屏时系统材质没东西可透，换成照片明暗做的底，系统材质收起来
        glassView.isHidden = style != .glass || isFull
        glassDim.isHidden = glassView.isHidden
        grainView.isHidden = style == .black
        imageView.monoBackdrop = style == .glass && isFull
        imageView.backdropOverride = nil
        if style == .glass && isFull { loadWallpaperBackdrop() }
        // 全屏时底下是平的深灰，颗粒要明显一点才看得出来
        grainView.alphaValue = isFull ? 1 : 0.6
        view.layer?.backgroundColor = glass ? NSColor.clear.cgColor : NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        if let w = view.window {
            w.isOpaque = !glass
            w.backgroundColor = glass ? .clear : .black
        }
        imageView.refreshBackdrop()
    }

    /// 全屏时的磨砂玻璃：读当前桌面壁纸，缩小、模糊、压暗，和窗口模式下透出来的桌面看起来一样。
    /// 读不到（动态视频壁纸等）就保持照片明暗做的深色底
    private func loadWallpaperBackdrop() {
        guard let screen = view.window?.screen ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let size = screen.frame.size
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let img = Self.makeWallpaperBackdrop(url, aspect: size)
            DispatchQueue.main.async {
                guard let self, let img, ZoomableImageView.backdropStyle == .glass,
                      self.view.window?.styleMask.contains(.fullScreen) == true else { return }
                self.imageView.backdropOverride = img
            }
        }
    }

    private static func makeWallpaperBackdrop(_ url: URL, aspect: CGSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let input = CIImage(cgImage: thumb)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 9)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
            .cropped(to: input.extent)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        guard let cg = ctx.createCGImage(blurred, from: input.extent) else { return nil }
        // 和窗口模式一样压暗：系统深色材质加一层 38% 的黑
        let w = cg.width, h = cg.height
        guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        out.draw(cg, in: r)
        out.setFillColor(CGColor(gray: 0.12, alpha: 0.55))
        out.fill(r)
        return out.makeImage()
    }

    // MARK: - ⌘W：先回开始页，再关窗口

    /// 看着照片时按 ⌘W 回到开始页，换个文件夹不用关窗口；已经在开始页时才关窗口
    @objc func closePhotosOrWindow(_ sender: Any?) {
        guard let w = view.window else { return }
        if let cleanup {
            cleanup.finish(nil)
            return
        }
        guard folder.totalCount > 0 else {
            w.performClose(nil)
            return
        }
        showStartPage()
    }

    func showStartPage() {
        exitCompare()
        if slideshowActive { stopSlideshow() }
        imageView.endPeek()
        folderGeneration += 1
        generation += 1
        decodeQueue.cancelAllOperations()
        prefetchQueue.cancelAllOperations()
        draftQueue.cancelAllOperations()
        thumbQueue.cancelAllOperations()
        endRapidPaging()
        folder.clear()
        folderWatcher.stop()
        pendingRemovalCheck?.cancel()
        video.clear()
        prefetchedURLs.removeAll()
        imageView.set(image: nil, resetToFit: true, isNew: true)
        exifPanel.isHidden = true
        emptyHint.stringValue = L10n.t("ui.emptyHint", "把文件夹或图片拖进这个窗口，或点击「打开…」")
        emptyState.isHidden = false
        filmstrip.collectionView.reloadData()
        updateControlsPresence()
        updateHUD()
        updateRatingLabel()
        refreshMarks()
        updateMarkedOnlyPill()
        view.window?.title = AppInfo.name
    }

    // MARK: - 窗口置顶、分享

    /// 置顶：窗口浮在其他软件上面，切到别的桌面或别的软件全屏时也跟着；每个窗口单独设，关掉窗口就没了
    var isPinned: Bool { view.window?.level == .floating }

    @objc func togglePinned(_ sender: Any?) {
        guard let w = view.window else { return }
        let on = !isPinned
        w.level = on ? .floating : .normal
        if on {
            w.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            w.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        refreshPinButton()
        flash(on ? L10n.t("msg.pinned", "窗口已置顶，会浮在其他软件上面") : L10n.t("msg.unpinned", "已取消置顶"), seconds: 1.5)
    }

    private func refreshPinButton() {
        let on = isPinned
        pinButton?.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        pinButton?.contentTintColor = on ? .controlAccentColor : .labelColor
        pinButton?.toolTip = on ? L10n.t("tip.unpin", "取消置顶") : L10n.t("tip.pin", "窗口置顶：浮在其他软件上面")
    }

    /// --pintest <输出文件夹>：置顶开关、工具条截图
    func runPinTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func state(_ tag: String) {
            let w = view.window
            NSLog("PIN %@ level=%d allSpaces=%d fsAux=%d pinned=%d", tag, w?.level.rawValue ?? -1,
                  w?.collectionBehavior.contains(.canJoinAllSpaces) == true ? 1 : 0,
                  w?.collectionBehavior.contains(.fullScreenAuxiliary) == true ? 1 : 0, isPinned ? 1 : 0)
        }
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        state("start")
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "†",
                                  charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)
        let handled = ev.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
        state("after ⌥⌘T handled=\(handled ? 1 : 0)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.pokeControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.captureWindow(to: "\(outDir)/pinned.png", raw: true)
                self.togglePinned(nil)
                state("after toggle off")
                NSApp.terminate(nil)
            }
        }
    }

    /// 系统的分享菜单：隔空投送、信息、邮件，以及装了分享扩展的微信等
    @objc func shareCurrent(_ sender: Any?) {
        let urls = actionURLs
        guard cleanup == nil, !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let b = shareButton, !toolbarView.isHidden, toolbarView.alphaValue > 0, b.window != nil {
            controlsHideTimer?.invalidate()
            picker.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
        } else {
            let r = NSRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
            picker.show(relativeTo: r, of: view, preferredEdge: .minY)
        }
    }

    // MARK: - 设为桌面壁纸

    @objc func setWallpaper(_ sender: Any?) {
        guard let item = folder.current, !Video.isVideo(item.url), let screen = NSScreen.main else { return }
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
        let srcItems = folder.items.filter { !Video.isVideo($0.url) }
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
        renameCurrent(to: field.stringValue)
    }

    /// 把当前照片改名（不含扩展名）；同名的实况 MOV、星级 .xmp 跟着改
    func renameCurrent(to input: String) {
        guard let item = folder.current else { return }
        let ext = item.url.pathExtension
        let base = item.url.deletingPathExtension().lastPathComponent
        let newName = input.trimmingCharacters(in: .whitespaces)
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
            Self.renameCompanions(of: item.url, to: folderURL.appendingPathComponent(candidate))
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
        guard let item = folder.current, !Video.isVideo(item.url), !isProcessing, let window = view.window else { return }
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
        // 右上角「反馈建议…」，和标题同一行，跟着内容一起滚动
        let feedback = NSButton(title: L10n.t("menu.feedback", "反馈建议…"), target: NSApp.delegate,
                                action: #selector(AppDelegate.showFeedback(_:)))
        feedback.bezelStyle = .rounded
        feedback.sizeToFit()
        feedback.frame.origin = NSPoint(x: textView.frame.width - feedback.frame.width - 22, y: 24)
        feedback.autoresizingMask = [.minXMargin, .maxYMargin]
        textView.addSubview(feedback)
        window.contentView = scroll
        window.center()

        let wc = NSWindowController(window: window)
        aboutWindowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func aboutContent() -> NSAttributedString {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var body = L10n.t("about.body", "")
        // 中文界面在说明后面写上微信号
        body += "\n\n" + L10n.f("about.email", "邮件：%@", FeedbackWindowController.supportEmail)
        if let wechat = L10n.optional("about.wechat") { body += "\n" + wechat }
        let shortcuts = L10n.t("sc.body", "")
        let full = body + "\n\n■ " + L10n.t("about.shortcutsTitle", "快捷键") + "\n" + shortcuts

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = 6

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\(AppInfo.name) \(version)\n\n", attributes: [
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
            // 单按 ⌫ 现在是录下 ⌫；清除改用这一行右边的「清除」
            guard let rec = settings.debugRecorder(for: .info), let w = settings.window else { return }
            rec.performClick(nil)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                        context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
                rec.keyDown(with: e)
            }
            NSLog("SET R4-backspace recorded info=%@", Shortcuts.combo(for: .info)?.display ?? "nil")
            settings.debugClearButton(for: .info)?.performClick(nil)
            NSLog("SET R4b-clear button cleared info=%@", Shortcuts.combo(for: .info)?.display ?? "nil")
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

    /// --multiselecttest <截图目录> <文件夹>：用真的鼠标事件在缩略图栏里 ⇧ 点、⌘ 点、⌃ 点、拖出，
    /// 再对选中的几张拷贝、标记、评分、送进后期软件、导出、删除再放回；每步记录选中了哪几张和结果
    func runMultiSelectTest(outDir: String) {
        let cv = filmstrip.collectionView
        let out = URL(fileURLWithPath: outDir)
        let exportDir = out.appendingPathComponent("export")
        try? FileManager.default.removeItem(at: exportDir)
        func name(_ i: Int) -> String { folder.items.indices.contains(i) ? folder.items[i].url.lastPathComponent : "-" }
        func sel() -> String { cv.selectionIndexPaths.map(\.item).sorted().map { "\($0)" }.joined(separator: ",") }
        func click(_ i: Int, _ mods: NSEvent.ModifierFlags = []) {
            cv.scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .centeredHorizontally)
            let r = cv.frameForItem(at: i)
            let p = cv.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
            func ev(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let e = ev(.leftMouseDown, p) { cv.mouseDown(with: e) }
            if let e = ev(.leftMouseUp, p) { cv.mouseUp(with: e) }
        }
        func report(_ tag: String) {
            NSLog("MSEL %@ | sel=[%@] picked=%d current=%d:%@ shown=%d", tag, sel(), stripPicked.count, folder.index, name(folder.index), folder.count)
        }
        let pb = NSPasteboard.general
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.0) { self.goTo(0); self.pokeControls() }
        at(0.6) { click(2); report("1-plain click #2") }
        at(0.4) { click(5, .shift); report("2-shift click #5 -> 2..5") }
        at(0.4) { self.pokeControls() }
        at(0.5) { self.captureWindow(to: "\(outDir)/1-range.png", raw: true) }
        at(0.3) { click(3, .command); report("3-cmd click #3 -> drop it") }
        at(0.4) { click(7, .control); report("4-ctrl click #7 -> add it") }
        at(0.4) { click(9, [.shift, .command]); report("5-shift+cmd click #9 -> add 7..9") }
        at(0.4) { click(8); report("6-plain click inside selection keeps it until mouse up -> only #8") }
        at(0.4) { click(1); click(4, .shift); report("7-reselect 1..4") }
        at(0.4) {
            pb.clearContents()
            self.copy(nil)
            let urls = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
            NSLog("MSEL 8-copy files=[%@]", urls.map(\.lastPathComponent).joined(separator: ","))
        }
        at(0.3) {
            self.toggleMark(nil)
            NSLog("MSEL 9-mark model=%d menu=%@", self.folder.markedCount, self.markMenuTitle)
            self.setRating(3)
        }
        at(0.8) {
            let marked = self.folder.allItems.filter { Marks.isMarked(URL(fileURLWithPath: $0.url.path)) }.map(\.url.lastPathComponent)
            NSLog("MSEL 9b-mark disk=[%@]", marked.joined(separator: ","))
            let rated = self.folder.allItems.filter { Rating.read($0.url) == 3 }.map(\.url.lastPathComponent)
            NSLog("MSEL 10-rating3 disk=[%@]", rated.joined(separator: ","))
            self.debugOpenedFiles = []
            let it = NSMenuItem()
            it.representedObject = URL(fileURLWithPath: "/System/Applications/Preview.app")
            self.openWithMenuItem(it)
            NSLog("MSEL 11-open with files=[%@]", (self.debugOpenedFiles ?? []).map(\.lastPathComponent).joined(separator: ","))
            self.debugOpenedFiles = nil
            report("11b-still selected")
        }
        at(0.3) { self.captureWindow(to: "\(outDir)/2-marked.png", raw: true) }
        at(0.3) { self.debugExportTarget = exportDir; Self.exportFolderMoves = false; self.exportToFolder(nil) }
        at(1.5) {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            NSLog("MSEL 12-export copied=[%@]", files.joined(separator: ","))
            self.debugExportTarget = nil
        }
        at(0.3) { click(2); click(3, .shift); report("13-pick 2..3 to trash") }
        at(0.3) { self.trashCurrent(nil) }
        at(1.2) { report("14-after trash") }
        at(0.3) { self.restoreLastTrash(nil) }
        at(1.5) { report("15-restored") }
        at(0.3) { click(0); click(2, .shift) }
        at(0.3) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                        windowNumber: self.view.window?.windowNumber ?? 0, context: nil,
                                        characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
                                        charactersIgnoringModifiers: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
                                        isARepeat: false, keyCode: 124) {
                self.imageView.keyDown(with: e)
            }
        }
        at(0.4) { report("16-arrow key collapses selection") }
        at(0.3) {
            click(4); click(6, .shift)
            NSLog("MSEL 17-drag from #5 (in selection)=[%@] from #0 (outside)=[%@]",
                  self.filmstripDragURLs(from: 5).map(\.lastPathComponent).joined(separator: ","),
                  self.filmstripDragURLs(from: 0).map(\.lastPathComponent).joined(separator: ","))
        }
        at(0.5) { NSApp.terminate(nil) }
    }

    #if FLIPIC_PRO
    /// --wbentrytest <截图目录> <文件夹>：看到第 5 张时点右上角的工作台按钮，工作台应打开这个文件夹并选中第 5 张；
    /// 回看图窗口翻到第 8 张再点，同一个项目里改选第 8 张。设 FLIPIC_WORKBENCH_FILE 用临时项目列表
    func runWorkbenchEntryTest(outDir: String) {
        func button() -> NSButton? {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.action == #selector(openWorkbench(_:)) { return b }
                for sv in v.subviews { if let b = find(sv) { return b } }
                return nil
            }
            return find(cornerBar)
        }
        func report(_ tag: String) {
            let wb = WorkbenchWindowController.shared?.workbench
            let sel = wb.flatMap { $0.photos.indices.contains($0.selected) ? $0.photos[$0.selected].url.lastPathComponent : nil } ?? "-"
            NSLog("WBENTRY %@ | viewer=%@ button=%d unlocked=%d | project=%@ photos=%d selected=%@ projects=%d", tag,
                  folder.current?.url.lastPathComponent ?? "-", button() != nil ? 1 : 0, License.isUnlocked ? 1 : 0,
                  wb?.currentProject?.path ?? "-", wb?.photos.count ?? 0, sel, WorkbenchStore.shared.projects.count)
        }
        func shot(_ name: String) {
            guard let w = WorkbenchWindowController.shared?.window,
                  let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.0) { self.goTo(4); self.pokeControls() }
        at(0.6) { report("0-before"); self.view.window?.makeKeyAndOrderFront(nil); button()?.performClick(nil) }
        at(2.5) { report("1-clicked at #5"); shot("wb-1") }
        at(0.3) {
            let wb = WorkbenchWindowController.shared?.workbench
            NSLog("WBENTRY 1b-layout middle=%d preview=%.0f grid=%.0f frames=%@", wb?.previewInMiddle == true ? 1 : 0,
                  wb?.previewWidth ?? 0, wb?.gridWidth ?? 0, wb?.debugSplitFrames ?? "-")
            wb?.togglePreviewSide()
        }
        at(0.8) {
            let wb = WorkbenchWindowController.shared?.workbench
            NSLog("WBENTRY 1c-swapped middle=%d preview=%.0f grid=%.0f frames=%@", wb?.previewInMiddle == true ? 1 : 0,
                  wb?.previewWidth ?? 0, wb?.gridWidth ?? 0, wb?.debugSplitFrames ?? "-")
            shot("wb-right")
            wb?.togglePreviewSide()
        }
        at(0.8) {
            let wb = WorkbenchWindowController.shared?.workbench
            NSLog("WBENTRY 1d-back middle=%d preview=%.0f grid=%.0f", wb?.previewInMiddle == true ? 1 : 0, wb?.previewWidth ?? 0, wb?.gridWidth ?? 0)
        }
        // 工作台里的看图功能：宫格里按 R、=，大图跟着转、放大；⌘C、打开方式、导出、右键菜单、拖出、保存旋转
        func wbKey(_ chars: String, _ code: UInt16) {
            guard let wbc = WorkbenchWindowController.shared, let wb = wbc.workbench,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wbc.window?.windowNumber ?? 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            wb.center.grid.keyDown(with: e)
        }
        at(0.3) {
            guard let wb = WorkbenchWindowController.shared?.workbench else { return }
            wbKey("r", 15)
            wbKey("=", 24); wbKey("=", 24)
            let v = wb.inspector.preview
            NSLog("WBENTRY 5-grid R and == : turns=%d fit=%d zoom=%.2f", v.rotationTurns, v.isFit ? 1 : 0, v.viewState.zoom)
        }
        at(0.6) { shot("wb-rotated-zoomed") }
        at(0.3) {
            guard let wb = WorkbenchWindowController.shared?.workbench else { return }
            NSPasteboard.general.clearContents()
            wb.copy(nil)
            let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
            WorkbenchViewController.debugOpened = []
            let it = NSMenuItem(); it.representedObject = URL(fileURLWithPath: "/System/Applications/Preview.app")
            wb.openWithApp(it)
            let menu = wb.contextMenu().items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ",")
            let drag = (wb.center.collectionView(wb.center.grid, pasteboardWriterForItemAt: IndexPath(item: 2, section: 0)) as? NSURL)?.lastPathComponent ?? "-"
            NSLog("WBENTRY 6-copy=[%@] openWith=[%@] drag#3=%@ menu=[%@]", urls.map(\.lastPathComponent).joined(separator: ","),
                  (WorkbenchViewController.debugOpened ?? []).map(\.lastPathComponent).joined(separator: ","), drag, menu)
            WorkbenchViewController.debugOpened = nil
            let exp = URL(fileURLWithPath: outDir).appendingPathComponent("wb-export")
            try? FileManager.default.removeItem(at: exp)
            WorkbenchViewController.debugExportTarget = exp
            wb.exportToFolder(nil)
        }
        at(1.2) {
            let exp = URL(fileURLWithPath: outDir).appendingPathComponent("wb-export")
            NSLog("WBENTRY 7-export=[%@]", ((try? FileManager.default.contentsOfDirectory(atPath: exp.path)) ?? []).sorted().joined(separator: ","))
            WorkbenchViewController.debugExportTarget = nil
            guard let wb = WorkbenchWindowController.shared?.workbench, let u = wb.selectedPhotoURL else { return }
            let before = ImageLoader.shared.info(for: u)?.pixelSize ?? .zero
            NSLog("WBENTRY 8-before save %@ %.0fx%.0f", u.lastPathComponent, before.width, before.height)
            wb.saveRotation(nil)
        }
        at(0.1) {
            // 工具条：鼠标在大图上动就出现，按钮点了作用在大图上
            guard let wb = WorkbenchWindowController.shared?.workbench else { return }
            wb.inspector.toolbar.reveal()
        }
        at(0.5) {
            guard let wb = WorkbenchWindowController.shared?.workbench else { return }
            NSLog("WBENTRY 8b-toolbar visible=%d alpha=%.1f", wb.inspector.toolbar.isHidden ? 0 : 1, wb.inspector.toolbar.alphaValue)
            shot("wb-toolbar")
        }
        at(1.4) {
            guard let wb = WorkbenchWindowController.shared?.workbench, let u = wb.selectedPhotoURL else { return }
            ImageLoader.shared.evict(url: u)
            let after = ImageLoader.shared.info(for: u)?.pixelSize ?? .zero
            NSLog("WBENTRY 9-after save %@ %.0fx%.0f turns now=%d", u.lastPathComponent, after.width, after.height, wb.inspector.preview.rotationTurns)
            shot("wb-saved")
        }
        at(0.3) { self.view.window?.makeKeyAndOrderFront(nil); self.goTo(7) }
        at(0.6) { self.view.window?.makeKeyAndOrderFront(nil); button()?.performClick(nil) }
        at(1.5) { report("2-clicked at #8 (same project)"); shot("wb-2") }
        at(0.3) {
            guard let wbc = WorkbenchWindowController.shared, let wb = wbc.workbench else { return }
            if let c = wb.cellIndex(of: 10) { wb.select(cell: c) }
            wbc.window?.makeKeyAndOrderFront(nil)
            NSLog("WBENTRY 3-workbench picked %@, key=%d", wb.selectedPhotoURL?.lastPathComponent ?? "-", NSApp.keyWindow === wbc.window ? 1 : 0)
            (NSApp.delegate as? AppDelegate)?.backToViewer(from: wbc)
        }
        at(0.8) { report("4-back to viewer (shows workbench pick, no reload)"); self.captureWindow(to: "\(outDir)/viewer-back.png", raw: true) }
        at(0.5) { NSApp.terminate(nil) }
    }

    /// --wbviewertest <截图目录> <文件夹>：工作台里的实况照片、复制图中文字、重命名（连同 MOV）、壁纸（不真换）、幻灯片、右键菜单
    func runWorkbenchViewerTest(outDir: String) {
        func shot(_ name: String) {
            guard let w = WorkbenchWindowController.shared?.window,
                  let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        var wb: WorkbenchViewController? { WorkbenchWindowController.shared?.workbench }
        func pick(_ name: String) {
            guard let wb, let p = wb.photos.firstIndex(where: { $0.url.lastPathComponent == name }), let c = wb.cellIndex(of: p) else { NSLog("WBVIEW pick %@ missing", name); return }
            wb.select(cell: c)
        }
        let dir = folder.current?.url.deletingLastPathComponent()
        func files() -> String { ((try? FileManager.default.contentsOfDirectory(atPath: dir?.path ?? "")) ?? []).sorted().joined(separator: ",") }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        WorkbenchViewController.debugSkipWallpaper = true
        WorkbenchViewController.debugNoFullScreen = true
        at(0.0) { (NSApp.delegate as? AppDelegate)?.showWorkbench(opening: self.folder.current?.url, in: self.view.window) }
        at(2.5) { NSLog("WBVIEW 0 photos=%d mode=%@ files=%@", wb?.photos.count ?? 0, "\(wb?.mode as Any)", files()); pick("LIVE_0001.JPG") }
        at(1.0) { wb?.playLivePhoto(nil) }
        at(0.8) {
            NSLog("WBVIEW 1-live played=%@ viewShown=%d host=%@", WorkbenchViewController.debugLivePlayed?.lastPathComponent ?? "-",
                  wb?.liveView?.isHidden == false ? 1 : 0, wb?.liveView?.superview.map { "\(type(of: $0))" } ?? "-")
            shot("p2-live")
        }
        at(0.3) { pick("PLAIN_0003.jpg"); wb?.playLivePhoto(nil) }
        at(0.6) { NSLog("WBVIEW 1b-plain liveHidden=%d (expect 1, flash 不是实况)", wb?.liveView?.isHidden != false ? 1 : 0); shot("p2-notlive") }
        at(0.3) { pick("text.png"); wb?.copyAllText(nil) }
        at(4.0) { NSLog("WBVIEW 2-text=[%@]", (WorkbenchViewController.debugCopiedText ?? "-").replacingOccurrences(of: "\n", with: " | ")) }
        at(0.3) { pick("LIVE_0002.JPG"); wb?.renameSelected(to: "Trip 01") }
        at(1.5) { NSLog("WBVIEW 3-rename selected=%@ files=%@", wb?.selectedPhotoURL?.lastPathComponent ?? "-", files()); shot("p2-renamed") }
        at(0.3) { wb?.renameSelected(to: "LIVE_0001") }
        at(1.5) { NSLog("WBVIEW 3b-clash selected=%@", wb?.selectedPhotoURL?.lastPathComponent ?? "-") }
        at(0.3) { wb?.setWallpaper(nil) }
        at(0.3) { NSLog("WBVIEW 4-wallpaper=%@", WorkbenchViewController.debugWallpaper?.lastPathComponent ?? "-") }
        at(0.3) {
            guard let wb else { return }
            NSLog("WBVIEW 5-menu=[%@]", wb.contextMenu().items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ","))
            pick("PLAIN_0003.jpg")
            _ = wb.perform(.slideshow)
            NSLog("WBVIEW 6-slideshow on=%d mode=%@ at=%@", wb.slideshowActive ? 1 : 0, "\(wb.mode)", wb.selectedPhotoURL?.lastPathComponent ?? "-")
        }
        at(3.4) { NSLog("WBVIEW 6b +3s at=%@", wb?.selectedPhotoURL?.lastPathComponent ?? "-"); shot("p2-slide") }
        at(3.1) { NSLog("WBVIEW 6c +6s at=%@", wb?.selectedPhotoURL?.lastPathComponent ?? "-"); wb?.leaveSingle() }
        at(0.5) { NSLog("WBVIEW 7-stopped on=%d mode=%@", wb?.slideshowActive == true ? 1 : 0, "\(wb?.mode as Any)") }
        at(0.5) { NSApp.terminate(nil) }
    }

    /// --themeshot <截图目录> <文件夹>：浅色、深色外观下工作台（宫格 + 大图、单张）、设置、关于各截一张；用户原来的外观设置最后写回
    func runThemeShots(outDir: String) {
        var wb: WorkbenchViewController? { WorkbenchWindowController.shared?.workbench }
        let saved = UserDefaults.standard.object(forKey: "appearanceMode")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func shot(_ w: NSWindow?, _ name: String) {
            guard let w, let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL, "public.png" as CFString, 1, nil) else {
                NSLog("THEMESHOT %@ failed", name); return
            }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            NSLog("THEMESHOT %@ saved", name)
        }
        func about() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == L10n.t("menu.about", "关于 Flipic") } }
        at(0.0) { (NSApp.delegate as? AppDelegate)?.showWorkbench(opening: self.folder.current?.url, in: self.view.window) }
        for mode in [Theme.Mode.light, .dark] {
            let tag = mode == .light ? "light" : "dark"
            at(3.0) { Theme.mode = mode; wb?.setMode(.gridPreview); wb?.select(cell: 1); WorkbenchWindowController.shared?.window?.orderFrontRegardless() }
            at(1.5) { shot(WorkbenchWindowController.shared?.window, "\(tag)-workbench") }
            at(0.2) { wb?.setMode(.single) }
            at(1.2) { shot(WorkbenchWindowController.shared?.window, "\(tag)-single"); wb?.setMode(.compare) }
            at(1.2) { shot(WorkbenchWindowController.shared?.window, "\(tag)-compare"); wb?.setMode(.gridPreview) }
            at(0.3) { SettingsWindowController.shared.show(.general); SettingsWindowController.shared.window?.orderFrontRegardless() }
            at(1.0) { shot(SettingsWindowController.shared.window, "\(tag)-settings"); SettingsWindowController.shared.show(.shortcuts) }
            at(0.8) { shot(SettingsWindowController.shared.window, "\(tag)-shortcuts"); SettingsWindowController.shared.window?.orderOut(nil); self.showAbout(nil) }
            at(1.0) { shot(about(), "\(tag)-about"); about()?.orderOut(nil); shot(self.view.window, "\(tag)-viewer"); self.view.window?.orderFrontRegardless(); self.toggleCompare(nil) }
            at(1.2) { shot(self.view.window, "\(tag)-viewer-compare"); self.toggleCompare(nil) }
        }
        at(0.5) {
            if let saved { UserDefaults.standard.set(saved, forKey: "appearanceMode") } else { UserDefaults.standard.removeObject(forKey: "appearanceMode") }
            NSApp.terminate(nil)
        }
    }

    /// --wbnoviewertest <输出目录> <文件夹>：开着工作台把看图窗口关掉，之后菜单里哪些项没人接（灰掉），
    /// 双击宫格进单张、⌥⌘B 回看图还管不管用
    func runWorkbenchNoViewerTest(outDir: String) {
        var wb: WorkbenchViewController? { WorkbenchWindowController.shared?.workbench }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func dead(_ tag: String) {
            var out: [String] = []
            func walk(_ m: NSMenu, _ path: String) {
                m.update()
                for it in m.items {
                    if let sub = it.submenu { walk(sub, path + it.title + ">"); continue }
                    guard let a = it.action, !it.isSeparatorItem else { continue }
                    // 工作台窗口是 key 时 nil target 的菜单项交给谁：第一响应者一路往上、窗口代理、NSApp、AppDelegate
                    var target: AnyObject? = it.target
                    if target == nil, let w = WorkbenchWindowController.shared?.window {
                        var r: NSResponder? = w.firstResponder
                        while let x = r, target == nil { if x.responds(to: a) { target = x }; r = x.nextResponder }
                        if target == nil, let d = w.delegate as AnyObject?, d.responds(to: a) { target = d }
                        if target == nil, NSApp.responds(to: a) { target = NSApp }
                        if target == nil, let d = NSApp.delegate as AnyObject?, d.responds(to: a) { target = d }
                    }
                    if target == nil { out.append("\(path)\(it.title)[\(NSStringFromSelector(a))]\(target == nil ? " no-target" : " disabled")") }
                }
            }
            if let m = NSApp.mainMenu { walk(m, "") }
            NSLog("WBNOVIEW %@ key=%@ dead=%d", tag, NSApp.keyWindow.map { "\(type(of: $0.windowController as Any))" } ?? "-", out.count)
            for l in out { NSLog("WBNOVIEW   %@", l) }
        }
        at(0.0) { (NSApp.delegate as? AppDelegate)?.showWorkbench(opening: self.folder.current?.url, in: self.view.window) }
        at(3.0) { wb?.setMode(.grid); wb?.select(cell: 0); WorkbenchWindowController.shared?.window?.makeKeyAndOrderFront(nil); dead("1-viewer open") }
        at(0.5) { self.view.window?.performClose(nil) }
        at(0.8) {
            WorkbenchWindowController.shared?.window?.makeKeyAndOrderFront(nil)
            NSLog("WBNOVIEW viewer windows visible=%d", NSApp.windows.filter { $0.windowController is ViewerWindowController && $0.isVisible }.count)
            dead("2-viewer closed")
        }
        at(0.3) {
            if let g = wb?.center.grid, let v = g.item(at: IndexPath(item: 2, section: 0))?.view, let w = g.window {
                let wp = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                for n in [1, 2] { for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) { w.sendEvent(e) }
                } }
            }
        }
        at(0.8) { NSLog("WBNOVIEW 3-double-click mode=%@ selected=%@", "\(wb?.mode as Any)", wb?.selectedPhotoURL?.lastPathComponent ?? "-") }
        at(0.3) {
            let ok = NSApp.sendAction(#selector(ViewerViewController.showShortcuts(_:)), to: nil, from: nil)
            NSLog("WBNOVIEW 3b-快捷键说明 handled=%d settingsVisible=%d", ok ? 1 : 0, SettingsWindowController.shared.window?.isVisible == true ? 1 : 0)
            SettingsWindowController.shared.window?.orderOut(nil)
        }
        at(0.3) {
            let ok = NSApp.sendAction(#selector(ViewerViewController.showAbout(_:)), to: nil, from: nil)
            let about = NSApp.windows.filter { $0.isVisible && $0.title == L10n.t("menu.about", "关于 Flipic") }
            NSLog("WBNOVIEW 3c-关于 handled=%d aboutVisible=%d", ok ? 1 : 0, about.count)
            about.forEach { $0.orderOut(nil) }
        }
        at(0.3) { if let wb = WorkbenchWindowController.shared { (NSApp.delegate as? AppDelegate)?.backToViewer(from: wb) } }
        at(1.0) {
            let viewers = NSApp.windows.filter { $0.windowController is ViewerWindowController && $0.isVisible }
            NSLog("WBNOVIEW 4-⌥⌘B viewer windows visible=%d key=%@ shown=%@", viewers.count,
                  NSApp.keyWindow.map { "\(type(of: $0.windowController as Any))" } ?? "-",
                  (viewers.first?.windowController as? ViewerWindowController)?.currentPhotoURL?.lastPathComponent ?? "-")
        }
        at(0.5) { NSApp.terminate(nil) }
    }

    /// --wbtrashracetest <输出目录> <文件夹>：回到工作台窗口时会在后台对一遍磁盘，这时连着删照片，
    /// 对完的旧结果不能把刚删掉的照片放回列表；之后接着删下一张要能删掉
    func runWorkbenchTrashRaceTest(outDir: String) {
        var wb: WorkbenchViewController? { WorkbenchWindowController.shared?.workbench }
        let fm = FileManager.default
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        var deleted: [URL] = []
        func report(_ tag: String) {
            guard let wb else { return }
            let ghosts = deleted.filter { u in wb.photos.contains { $0.url == u } }
            NSLog("WBRACE %@ photos=%d selected=%@ selectedExists=%d ghosts=%d undo=%d last=[%@]", tag, wb.photos.count,
                  wb.selectedPhotoURL?.lastPathComponent ?? "-", wb.selectedPhotoURL.map { fm.fileExists(atPath: $0.path) ? 1 : 0 } ?? -1,
                  ghosts.count, wb.trashStack.count, wb.lastTrashLog.joined(separator: ","))
        }
        at(0.0) { (NSApp.delegate as? AppDelegate)?.showWorkbench(opening: self.folder.current?.url, in: self.view.window) }
        at(4.0) { wb?.setMode(.grid); wb?.select(cell: 0); report("0-start") }
        for i in 1...3 {
            // 和切回 App 时一样：窗口变成 key，后台开始对磁盘；紧接着按删除
            at(1.5) {
                if let u = wb?.selectedPhotoURL { deleted.append(u) }
                if let w = WorkbenchWindowController.shared?.window { WorkbenchWindowController.shared?.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: w)) }
                wb?.trashSelection()
            }
            at(3.0) { report("\(i)-after reload+trash") }
        }
        at(0.5) { if let u = wb?.selectedPhotoURL { deleted.append(u) }; wb?.trashSelection() }
        at(2.0) { report("4-plain trash after") }
        at(0.5) { NSApp.terminate(nil) }
    }

    /// --wbfocustest <截图目录> <文件夹>：宫格 + 大图里，先点大图、再点宫格另一格，之后 → 和 = 还管不管用（事件走窗口，和真鼠标键盘一样）
    func runWorkbenchFocusTest(outDir: String) {
        func shot(_ name: String) {
            guard let w = WorkbenchWindowController.shared?.window,
                  let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        var wb: WorkbenchViewController? { WorkbenchWindowController.shared?.workbench }
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func click(_ v: NSView, _ p: NSPoint? = nil, count: Int = 1) {
            guard let w = v.window else { return }
            let wp = v.convert(p ?? NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) { w.sendEvent(e) }
            }
        }
        func key(_ chars: String, _ code: UInt16) {
            guard let w = wb?.view.window,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code >= 123 ? [.numericPad, .function] : [], timestamp: 0,
                                           windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            w.sendEvent(e)
        }
        // ⌘ 快捷键走主菜单，和真按键一样：菜单项灰掉时什么都不做
        func cmd(_ chars: String, _ code: UInt16) {
            guard let w = wb?.view.window,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: e) != true { w.sendEvent(e) }
        }
        func report(_ tag: String) {
            guard let wb else { return }
            let fr = wb.view.window?.firstResponder.map { "\(type(of: $0))" } ?? "-"
            let s = wb.inspector.preview.viewState
            NSLog("WBFOCUS %@ responder=%@ selected=%@ preview=%@", tag, fr, wb.selectedPhotoURL?.lastPathComponent ?? "-",
                  s.fit ? "fit" : String(format: "x%.2f", s.zoom))
        }
        func cell(_ c: Int) -> NSView? { wb?.center.grid.item(at: IndexPath(item: c, section: 0))?.view }
        at(0.0) { (NSApp.delegate as? AppDelegate)?.showWorkbench(opening: self.folder.current?.url, in: self.view.window) }
        at(2.5) { wb?.setMode(.gridPreview); wb?.select(cell: 0) }
        at(1.0) { report("0-start"); shot("f0") }
        at(0.1) { if let p = wb?.inspector.preview { click(p) }; report("1-clickPreview") }
        at(0.3) { key("=", 24); report("2-zoomKey") }
        at(0.5) { if let c = cell(2) { click(c) }; report("3-clickCell2") }
        at(0.5) { key("=", 24); report("4-zoomKey") }
        at(0.5) { key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124); report("5-right") }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!), left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        func rating() -> Int { wb?.selectedPhoto?.rating ?? 0 }
        // 宫格 + 大图，宫格有焦点：方向键和 0 按看图窗口的设置
        at(0.5) { if let c = cell(1) { click(c) }; NSLog("WBFOCUS hint=%@", wb?.center.debugHint ?? "-"); report("A0-gridPreview clickCell1") }
        at(0.5) { key(up, 126); report("A1-up (expect zoom, same photo)") }
        at(0.5) { key(up, 126); report("A2-up (expect more zoom)") }
        at(0.5) { key(down, 125); report("A3-down (expect zoom out)") }
        at(0.5) { key(right, 124); report("A4-right (expect next)") }
        at(0.5) { key(left, 124 - 1); report("A5-left (expect prev)") }
        at(0.3) { wb?.rate(3) }
        at(0.3) { key("0", 29); report("A6-0 rating=\(rating()) (expect zoom at pointer, rating stays 3)") }
        at(0.3) { wb?.rate(0) }
        at(0.3) { cmd("=", 24); report("A7-cmdEquals") }
        // 只有宫格：方向键在宫格里移动，0 清除星级
        at(0.5) { wb?.setMode(.grid) }
        at(0.5) { if let c = cell(3) { click(c) }; NSLog("WBFOCUS hint=%@", wb?.center.debugHint ?? "-"); report("B0-grid clickCell3") }
        at(0.5) { key(up, 126); report("B1-up (expect cell1, row up)") }
        at(0.3) { wb?.rate(4) }
        at(0.3) { key("0", 29); report("B2-0 rating=\(rating()) (expect 0)") }
        at(0.5) { key(right, 124); report("B3-right (expect next)") }
        // 自定义：放大改成 Z，宫格 + 大图里 Z 放大，↑ 没分配给别的就回到换行
        let saved = [ShortcutAction.zoomIn].map { ($0, Shortcuts.isCustomized($0), Shortcuts.combo(for: $0)) }
        at(0.5) { wb?.setMode(.gridPreview); Shortcuts.set(KeyCombo(keyCode: 6, chars: "z"), for: .zoomIn) }
        at(0.5) { if let c = cell(3) { click(c) }; NSLog("WBFOCUS hint=%@", wb?.center.debugHint ?? "-"); report("C0-custom clickCell3") }
        at(0.5) { key("z", 6); report("C1-Z (expect zoom)") }
        at(0.5) { key(up, 126); report("C2-up unassigned (expect row up -> cell1)") }
        at(0.5) {
            for (a, was, c) in saved { Shortcuts.set(was ? c : a.defaultCombo, for: a) }
            NSLog("WBFOCUS restored zoomIn customized=%d", Shortcuts.isCustomized(.zoomIn) ? 1 : 0)
        }
        // 滚轮跟着鼠标：先在宫格上滚，紧接着在大图上滚，再回宫格；系统分发和按鼠标分发各跑一遍
        func wheel(over v: NSView, _ dy: Int32, phase: Int64) {
            guard let w = v.window else { return }
            let wp = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            let sp = w.convertPoint(toScreen: wp)
            let flipped = CGPoint(x: sp.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - sp.y)
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            cg.location = flipped
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
            guard let e = NSEvent(cgEvent: cg) else { return }
            w.sendEvent(e)
        }
        func gridY() -> Int { Int(wb?.center.gridScrollView.contentView.bounds.origin.y ?? -1) }
        func wheelReport(_ tag: String) {
            let s = wb?.inspector.preview.viewState
            NSLog("WBFOCUS %@ gridY=%d preview=%@", tag, gridY(), s.map { $0.fit ? "fit" : String(format: "x%.2f", $0.zoom) } ?? "-")
        }
        for system in [true, false] {
            let tag = system ? "W-system" : "W-routed"
            at(0.5) { WorkbenchWindow.debugSystemRouting = system; wb?.setMode(.gridPreview); wb?.select(cell: 0)
                      wb?.center.gridScrollView.contentView.scroll(to: .zero); wb?.inspector.preview.fit(animate: false) }
            at(0.5) {
                wheelReport("\(tag) 0-start")
                if let g = wb?.center.gridScrollView {
                    NSLog("WBFOCUS grid photos=%d docH=%d clipH=%d target(grid)=%@ target(preview)=%@", wb?.photos.count ?? 0,
                          Int(g.documentView?.frame.height ?? 0), Int(g.contentView.bounds.height),
                          wb?.scrollTarget(at: g.convert(NSPoint(x: g.bounds.midX, y: g.bounds.midY), to: nil)).map { "\(type(of: $0))" } ?? "nil",
                          wb.flatMap { w in w.scrollTarget(at: w.inspector.preview.convert(NSPoint(x: w.inspector.preview.bounds.midX, y: w.inspector.preview.bounds.midY), to: nil)) }.map { "\(type(of: $0))" } ?? "nil")
                }
            }
            at(0.1) { if let g = wb?.center.gridScrollView { wheel(over: g, -20, phase: 1); wheel(over: g, -20, phase: 2); wheel(over: g, -20, phase: 2) } }
            at(0.1) { wheelReport("\(tag) 1-gridScrolled (expect gridY>0)") }
            at(0.05) { if let p = wb?.inspector.preview { wheel(over: p, -20, phase: 2); wheel(over: p, -20, phase: 2) } }
            at(0.1) { wheelReport("\(tag) 2-overPreview same gesture (want: preview zooms, gridY same)") }
            at(0.05) { if let g = wb?.center.gridScrollView { wheel(over: g, -20, phase: 4) } }
            at(0.6) { if let p = wb?.inspector.preview { wheel(over: p, -20, phase: 1); wheel(over: p, -20, phase: 2) } }
            at(0.1) { wheelReport("\(tag) 3-newGestureOverPreview") }
            at(0.05) { if let g = wb?.center.gridScrollView { wheel(over: g, -20, phase: 2); wheel(over: g, -20, phase: 2) } }
            at(0.1) { wheelReport("\(tag) 4-overGrid same gesture (want: preview same; routed drops rest of photo gesture)") }
            at(0.05) { if let p = wb?.inspector.preview { wheel(over: p, 0, phase: 4) } }
        }
        at(0.3) { WorkbenchWindow.debugSystemRouting = false }
        // 单张不变：↑ 放大
        at(0.5) { wb?.setMode(.single) }
        at(0.8) { key(up, 126); NSLog("WBFOCUS D1-single up: %@ selected=%@", wb?.center.debugSingleState ?? "-", wb?.selectedPhotoURL?.lastPathComponent ?? "-") }
        at(0.5) { NSApp.terminate(nil) }
    }
    #endif

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
        // 用户报的崩溃：四格时按 C。先 Tab 到第 4 格，缩成两格后它那张要留在第 2 格
        at(0.2) { while self.compareActive < (self.compareView?.panes.count ?? 1) - 1 { key("\t", 48) } }
        at(0.3) { report("5a-active on last pane") }
        at(0.2) { key("c", 8) }
        at(1.2) { report("5b-C in four panes: shrinks to two, keeps active photo"); self.captureWindow(to: "\(outDir)/3b-four-to-two.png", raw: true) }
        at(0.2) { key("c", 8) }
        at(1.0) { report("5c-C again: exits") }
        at(0.2) { key("C", 8, .shift) }
        at(1.2) { report("5d-shift-C from single: four panes") }
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

    /// --livetest <输出目录> <文件夹>：识别实况（带标记的才算）、悬停/快捷键播放、改名和删除时同名 MOV 跟着走
    func runLiveTest(outDir: String) {
        let fm = FileManager.default
        let dir = folder.current?.url.deletingLastPathComponent()
        func files() -> String { ((try? fm.contentsOfDirectory(atPath: dir?.path ?? "")) ?? []).sorted().joined(separator: ",") }
        func log(_ s: String) { NSLog("LIVETEST %@", s) }
        var names: [String] = []
        var i = 0
        func step() {
            guard i < folder.count else { return finish() }
            jump(i)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                names.append("\(self.folder.current?.url.lastPathComponent ?? "-")=\(self.liveMovie == nil ? "plain" : "live")")
                i += 1; step()
            }
        }
        func jump(_ n: Int) { folder.jump(to: n); showImage(resetToFit: true) }
        func finish() {
            log("detect: " + names.joined(separator: " "))
            guard let idx = folder.items.firstIndex(where: { $0.url.lastPathComponent == "LIVE_0001.JPG" }) else { return log("no LIVE_0001") }
            jump(idx)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.pokeControls()
                log("badge visible=\(self.liveBadge.isHidden ? 0 : 1)")
                self.liveBadge.onHover?(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let v = self.liveView
                    log("playing: view=\(v != nil ? 1 : 0) hidden=\(v?.isHidden ?? true ? 1 : 0) livePhoto=\(v?.livePhoto != nil ? 1 : 0) frameMatchesImage=\(v?.frame == self.imageView.frame ? 1 : 0)")
                    self.captureWindow(to: outDir + "/live-playing.png", raw: true)
                    self.liveBadge.onHover?(false)
                    log("after hover out hidden=\(self.liveView?.isHidden ?? true ? 1 : 0)")
                    self.renameCurrent(to: "Renamed")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        log("after rename: " + files())
                        self.trashCurrent(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            log("after trash: " + files())
                            let out = URL(fileURLWithPath: outDir).appendingPathComponent("copied")
                            try? fm.removeItem(at: out)
                            let src = dir!.appendingPathComponent("LIVE_0002.JPG")
                            _ = Self.transfer([src], to: out, move: false)
                            log("copied: " + (((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).sorted().joined(separator: ",")))
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        step()
    }

    /// --deletetest <文件夹> [截图目录]：删除键设成单个 ⌫（走设置页录制按钮同一条路），在看图界面按 ⌫ 删一张
    /// （实况 MOV、附属文件一起走），⌘Z 放回；换回默认的 ⌘⌫ 再删一张，用「放回刚才删掉的照片」放回；
    /// 再确认重命名框里按 ⌫ / ⌘⌫ 只删字、不删照片。用户原来的快捷键设置最后原样写回
    func runDeleteTest(outDir: String?) {
        let fm = FileManager.default
        let savedShortcuts = UserDefaults.standard.data(forKey: "customShortcuts")
        guard let w = view.window, let dir = folder.current?.url.deletingLastPathComponent() else { NSLog("DELTEST no folder"); return }
        let settings = SettingsWindowController.shared
        #if FLIPIC_PRO
        let savedMerge = UserDefaults.standard.object(forKey: "mergeRawJpg")
        #endif
        func log(_ s: String) { NSLog("DELTEST %@", s) }
        func files() -> String {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted().joined(separator: ",")
        }
        func state(_ tag: String) {
            log("\(tag): shown=\(folder.current?.url.lastPathComponent ?? "-") count=\(folder.count) files=[\(files())]")
        }
        func record() -> String {
            guard let r = Self.lastTrash else { return "none" }
            return r.moved.sorted { $0.key.path < $1.key.path }.map { k, v in
                "\(k.lastPathComponent)→\(v.deletingLastPathComponent().lastPathComponent)/\(v.lastPathComponent)(inTrash=\(fm.fileExists(atPath: v.path) ? 1 : 0))"
            }.joined(separator: " ") + " photo=\(r.photo?.lastPathComponent ?? "-")"
        }
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
        /// 菜单项此刻能不能点：问看图界面的 validateMenuItem（菜单在这个窗口是 key 时问的就是它）
        func enabled(_ sel: Selector) -> Int {
            guard let it = menuItem(sel) ?? (sel == Selector(("undo:")) ? NSMenuItem(title: "", action: sel, keyEquivalent: "") : nil) else { return -1 }
            return validateMenuItem(it) ? 1 : 0
        }
        func event(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags, _ win: NSWindow) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: win.windowNumber,
                             context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)
        }
        /// 和真按键一样交给 NSApp：带 ⌘ 的先过菜单，其余送到 key 窗口的第一响应者。
        /// 测试时别的软件在前面、这个窗口当不了 key 时，菜单认不出目标：带 ⌘ 的改成把菜单项的 action 顺着第一响应者往上送
        func press(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags, in win: NSWindow, menuAction: Selector? = nil) {
            guard let e = event(code, ch, mods, win) else { return }
            if NSApp.keyWindow === win {
                log("(key window: NSApp.sendEvent)")
                NSApp.sendEvent(e)
            } else if mods.contains(.command), let menuAction {
                log("(window not key: \(menuAction) up the responder chain from \(win.firstResponder.map { String(describing: type(of: $0)) } ?? "-"))")
                _ = win.firstResponder?.tryToPerform(menuAction, with: nil)
            } else {
                log("(window not key: window.sendEvent / menu key equivalent)")
                if mods.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
                win.sendEvent(e)
            }
        }
        /// 设置页里点「移到废纸篓」的录制按钮，再按下这个键
        func recordTrash(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags) {
            guard let rec = settings.debugRecorder(for: .trash), let sw = settings.window, let e = event(code, ch, mods, sw) else {
                log("recorder missing"); return
            }
            rec.performClick(nil)
            if !rec.performKeyEquivalent(with: e) { rec.keyDown(with: e) }
        }
        func trashState(_ tag: String) {
            let it = menuItem(#selector(trashCurrent(_:)))
            let tip = shortcutTips.first { $0.action == .trash }?.button.toolTip ?? "-"
            log("\(tag): trash shortcut=\(Shortcuts.combo(for: .trash)?.display ?? "none") customized=\(Shortcuts.isCustomized(.trash) ? 1 : 0) "
                + "menu key=\"\(it?.keyEquivalent == "\u{8}" ? "⌫" : it?.keyEquivalent ?? "-")\" mods=\(it?.keyEquivalentModifierMask.rawValue ?? 0) tooltip=\(tip)")
        }
        func shot(_ win: NSWindow?, _ name: String) {
            guard let outDir, let win, let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(win.windowNumber),
                                                                          [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL,
                                                             "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            log("screenshot \(outDir)/\(name).png")
        }
        func focusViewer() {
            settings.window?.orderOut(nil)
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(imageView)
        }
        func show(_ name: String) {
            if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == name }) { goTo(i) }
        }
        if let outDir { try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }

        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        at(0.2) { [self] in
            #if FLIPIC_PRO
            // 有同名 RAW 时合并显示，删 JPG 连 RAW 一起走（Pro 功能，没激活时跳过）
            if License.isUnlocked {
                Pairs.merge = true
                applyMergePairs()
                filmstrip.collectionView.reloadData()
            }
            log("pro unlocked=\(License.isUnlocked ? 1 : 0) merge=\(Pairs.merge ? 1 : 0) hidden=[\(folder.hidden.map(\.lastPathComponent).sorted().joined(separator: ","))]")
            #endif
            log("saved customShortcuts=\(savedShortcuts.map { "\($0.count) bytes" } ?? "none")")
            show("DSC_2042.jpg")
            state("0-start")
            trashState("0-default")
            settings.show(.shortcuts)
        }
        at(0.8) {
            recordTrash(2, "d", [])
            trashState("1a-recorded letter D")
            recordTrash(51, "\u{7F}", [])
            trashState("1b-recorded plain ⌫")
            recordTrash(53, "\u{1B}", [])
            trashState("1c-Esc while recording cancels (still ⌫)")
            log("1d-clear button on trash row: present=\(settings.debugClearButton(for: .trash) != nil ? 1 : 0) hidden=\(settings.debugClearButton(for: .trash)?.isHidden ?? true ? 1 : 0) title=\(settings.debugClearButton(for: .trash)?.title ?? "-")")
            _ = settings.debugRecorder(for: .trash)
        }
        at(0.6) { shot(settings.window, "shortcuts-backspace") }
        at(0.3) { focusViewer() }
        at(0.5) { [self] in
            focusViewer()
            log("2-viewer key=\(NSApp.keyWindow === w ? 1 : 0) firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "-") restore menu enabled=\(enabled(#selector(restoreLastTrash(_:))))")
            press(51, "\u{7F}", [], in: w)
        }
        at(1.5) {
            state("3-after plain ⌫")
            log("3-trash record: \(record())")
            log("3-restore menu enabled=\(enabled(#selector(self.restoreLastTrash(_:)))) undo menu enabled=\(enabled(Selector(("undo:"))))")
            press(6, "z", .command, in: w, menuAction: Selector(("undo:")))
        }
        at(1.5) {
            state("4-after ⌘Z")
            log("4-record after undo: \(record()) restore menu enabled=\(enabled(#selector(self.restoreLastTrash(_:))))")
            settings.show(.shortcuts)
        }
        at(0.6) {
            recordTrash(51, "\u{7F}", .command)
            trashState("5-recorded ⌘⌫ (back to default)")
            focusViewer()
            show("DSC_2043.jpg")
        }
        at(0.6) {
            state("6-before ⌘⌫")
            press(51, "\u{7F}", .command, in: w, menuAction: #selector(self.trashCurrent(_:)))
        }
        at(1.5) {
            state("7-after ⌘⌫")
            log("7-trash record: \(record())")
            guard let it = menuItem(#selector(self.restoreLastTrash(_:))) else { return log("restore item missing") }
            log("7-menu \"\(it.title)\" in [\(it.menu?.title ?? "-")] enabled=\(enabled(#selector(self.restoreLastTrash(_:))))")
            // 菜单项被点时发出的就是这个 action；窗口不是 key 时直接发给看图界面
            if !NSApp.sendAction(#selector(self.restoreLastTrash(_:)), to: NSApp.keyWindow === w ? nil : self, from: it) { log("7-sendAction not handled") }
        }
        at(1.5) {
            state("8-after 放回刚才删掉的照片")
            log("8-restore menu enabled=\(enabled(#selector(self.restoreLastTrash(_:))))")
        }
        // 重命名框（模态）里按 ⌫ 和 ⌘⌫：只删输入框里的字，照片不动
        for (n, combo) in [(9, KeyCombo(keyCode: 51, chars: "\u{7F}")), (10, KeyCombo(keyCode: 51, mods: .command, chars: "\u{7F}"))] {
            at(0.4) { [self] in
                Shortcuts.set(combo, for: .trash)
                trashState("\(n)-rename field test with trash=\(combo.display)")
                state("\(n)a-before rename")
                let tick = Timer(timeInterval: 0.6, repeats: false) { _ in
                    // 重命名框弹出时输入框就是第一响应者（光标在里面）；还没轮到时手动点进去
                    let mw = NSApp.modalWindow ?? NSApp.keyWindow
                    func findField(_ v: NSView?) -> NSTextField? {
                        guard let v else { return nil }
                        if let f = v as? NSTextField, f.isEditable { return f }
                        for sub in v.subviews { if let f = findField(sub) { return f } }
                        return nil
                    }
                    mw?.makeKeyAndOrderFront(nil)
                    if let mw, !(mw.firstResponder is NSTextView), let f = findField(mw.contentView) { mw.makeFirstResponder(f) }
                    guard let mw, let field = mw.firstResponder as? NSTextView else {
                        log("\(n) no modal field (modalWindow=\(NSApp.modalWindow != nil ? 1 : 0) firstResponder=\(String(describing: NSApp.keyWindow?.firstResponder)))")
                        NSApp.abortModal(); return
                    }
                    // 光标放到末尾（弹出时是全选），⌫ 应只删最后一个字
                    field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
                    log("\(n)b-modal key=\(NSApp.keyWindow === mw ? 1 : 0) field before=\"\(field.string)\"")
                    press(51, "\u{7F}", combo.modifiers, in: mw)
                    log("\(n)c-field after \(combo.display)=\"\(field.string)\"")
                    NSApp.abortModal()
                }
                RunLoop.main.add(tick, forMode: .modalPanel)
                renameCurrent(nil)
            }
            at(1.2) { state("\(n)d-after rename dialog closed (photo must still be there)") }
        }
        at(0.3) { [self] in
            // 中途失败留在废纸篓里的测试文件放回去
            if Self.lastTrash != nil { log("cleanup: putting back leftover \(record())"); restoreLastTrash(nil) }
            if let savedShortcuts { UserDefaults.standard.set(savedShortcuts, forKey: "customShortcuts") }
            else { UserDefaults.standard.removeObject(forKey: "customShortcuts") }
            #if FLIPIC_PRO
            if let savedMerge { UserDefaults.standard.set(savedMerge, forKey: "mergeRawJpg") }
            else { UserDefaults.standard.removeObject(forKey: "mergeRawJpg") }
            #endif
            log("11-restored customShortcuts identical=\(UserDefaults.standard.data(forKey: "customShortcuts") == savedShortcuts ? 1 : 0)")
            log("done")
            NSApp.terminate(nil)
        }
    }

    /// --peekkeeptest <文件夹>：贴合预览里把窗口挪开再翻页，开关打开时窗口中心留在挪到的位置，关掉时回到进入预览前的中心
    /// --wraptest <文件夹>：最后一张再往后翻应停住；打开「回到第一张」后才绕回去
    func runWrapTest() {
        let saved = Self.wrapAround
        goTo(folder.count - 1)
        Self.wrapAround = false
        navigate(1)
        NSLog("WRAPTEST wrap=off after → index=%d of %d", folder.index, folder.count)
        goTo(0)
        navigate(-1)
        NSLog("WRAPTEST wrap=off at first, after ← index=%d", folder.index)
        goTo(folder.count - 1)
        Self.wrapAround = true
        navigate(1)
        NSLog("WRAPTEST wrap=on after → index=%d", folder.index)
        // 再停在最后一张按一次，截回弹中途和提示
        goTo(folder.count - 1)
        Self.wrapAround = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            navigate(1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [self] in
                if let i = CommandLine.arguments.firstIndex(of: "--wraptest-shot"), i + 1 < CommandLine.arguments.count {
                    captureWindow(to: CommandLine.arguments[i + 1], raw: true)
                }
                Self.wrapAround = saved
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }

    /// --ocrtest <输出目录> <文件夹>：图中文字。每张图的识别结果、经菜单复制再读剪贴板、叠加层在适应窗口 / 放大 / 平移时
    /// 是否对齐、连翻时有没有分析、关掉设置后不再自动分析、叠加层拿到焦点时方向键照常翻页；截图带文字高亮
    func runOCRTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func log(_ s: String) { NSLog("OCRTEST %@", s) }
        let savedAuto = TextRecognition.autoAnalyze, savedWrap = Self.wrapAround
        // 测试会动剪贴板：先存下用户原来的内容，结束时放回去
        let pb = NSPasteboard.general
        let savedPB: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { old in
            let item = NSPasteboardItem()
            for t in old.types { if let d = old.data(forType: t) { item.setData(d, forType: t) } }
            return item
        }
        log("supported liveText=\(TextRecognition.liveTextSupported ? 1 : 0) vision=\(TextRecognition.canRecognize ? 1 : 0) locales=\(TextRecognition.analyzerLocales.prefix(6).joined(separator: ","))")
        let photoMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.items.contains { $0.action == #selector(toggleCompare(_:)) } }
        let menuItem = photoMenu?.items.first { $0.action == #selector(copyAllText(_:)) }
        log("menu item=\(menuItem?.title ?? "nil") key=\(menuItem.map { ($0.keyEquivalentModifierMask.contains(.option) ? "⌥" : "") + "⌘" + $0.keyEquivalent } ?? "-") context=\(imageView.menu?.items.contains { $0.action == #selector(copyAllText(_:)) } == true ? 1 : 0)")
        TextRecognition.autoAnalyze = true
        guard let lt = liveText else { log("no liveText"); NSApp.terminate(nil); return }
        let overlay = lt.debugOverlay
        var boxes: [String: CGRect] = [:]
        if let txt = try? String(contentsOfFile: folder.items.first?.url.deletingLastPathComponent().appendingPathComponent("boxes.txt").path ?? "", encoding: .utf8) {
            for line in txt.split(separator: "\n") {
                let p = line.split(separator: " ")
                if p.count == 6, let x = Double(p[2]), let y = Double(p[3]), let w = Double(p[4]), let h = Double(p[5]) {
                    boxes[String(p[1])] = CGRect(x: x, y: y, width: w, height: h)
                }
            }
        }
        func index(of name: String) -> Int? { folder.items.firstIndex { $0.url.lastPathComponent == name } }
        /// 照片像素坐标（左上原点）→ 照片视图里的点
        func viewPoint(_ px: CGPoint) -> CGPoint {
            let f = imageView.imageFrame, size = imageView.pixelSize
            return CGPoint(x: f.minX + px.x / size.width * f.width, y: f.minY + px.y / size.height * f.height)
        }
        func align(_ tag: String, textKey: String, offPx: CGPoint) {
            let f = imageView.imageFrame, b = imageView.bounds
            let cr = overlay.contentsRect
            let mapped = CGRect(x: cr.minX * b.width, y: cr.minY * b.height, width: cr.width * b.width, height: cr.height * b.height)
            let err = max(abs(mapped.minX - f.minX), abs(mapped.minY - f.minY), abs(mapped.maxX - f.maxX), abs(mapped.maxY - f.maxY))
            var hits = "-"
            if let box = boxes[textKey] {
                // 取第一行文字靠左五分之一处（正中可能落在两个词之间的空格上）
                let c = viewPoint(CGPoint(x: box.minX + box.width * 0.2, y: box.midY))
                let off = viewPoint(offPx)
                let inC = b.contains(c), inOff = b.contains(off)
                let hitOn = inC ? lt.hasInteractiveItem(at: c) : false
                let hitOff = inOff ? lt.hasInteractiveItem(at: off) : false
                // 窗口层面的命中：文字上落到叠加层，别处落到照片视图（拖动、平移、双击缩放照常）
                let winHit = view.window?.contentView?.hitTest(imageView.convert(c, to: view.window?.contentView?.superview))
                let winOff = view.window?.contentView?.hitTest(imageView.convert(off, to: view.window?.contentView?.superview))
                hits = String(format: "textCenter=(%.0f,%.0f) visible=%d hasText=%d | off=(%.0f,%.0f) visible=%d hasText=%d | hit text→%@ off→%@ | dblClickIgnored text=%d off=%d",
                              c.x, c.y, inC ? 1 : 0, hitOn ? 1 : 0, off.x, off.y, inOff ? 1 : 0, hitOff ? 1 : 0,
                              winHit.map { String(describing: type(of: $0)) } ?? "nil", winOff.map { String(describing: type(of: $0)) } ?? "nil",
                              (imageView.ignoresDoubleClick?(c) ?? false) ? 1 : 0, (imageView.ignoresDoubleClick?(off) ?? false) ? 1 : 0)
            }
            // 文字可点的范围（叠加层自己报的）和这行字在照片上的位置比：按 2pt 网格扫出命中区域的外框
            if let box = boxes[textKey] {
                let a = viewPoint(box.origin), z = viewPoint(CGPoint(x: box.maxX, y: box.maxY))
                let expect = CGRect(x: a.x, y: a.y, width: z.x - a.x, height: z.y - a.y)
                let search = expect.insetBy(dx: -30, dy: -16 * imageView.displayedScale).intersection(b)
                var hitBox = CGRect.null
                for y in stride(from: search.minY, to: search.maxY, by: 2) {
                    for x in stride(from: search.minX, to: search.maxX, by: 2) where lt.hasInteractiveItem(at: CGPoint(x: x, y: y)) {
                        hitBox = hitBox.union(CGRect(x: x, y: y, width: 0.01, height: 0.01))
                    }
                }
                let vis = expect.intersection(b)
                hits += hitBox.isNull ? " | hitBox=none" : String(format: " | textBox(visible)=(%.0f,%.0f %.0fx%.0f) hitBox=(%.0f,%.0f %.0fx%.0f) centerDelta=(%.1f,%.1f)",
                                                                   vis.minX, vis.minY, vis.width, vis.height, hitBox.minX, hitBox.minY, hitBox.width, hitBox.height,
                                                                   hitBox.midX - vis.midX, hitBox.midY - vis.midY)
            }
            log(String(format: "ALIGN %@ scale=%.3f imageRect=(%.1f,%.1f %.1fx%.1f) overlayContents=(%.1f,%.1f %.1fx%.1f) maxErr=%.2fpt | %@",
                       tag, imageView.displayedScale, f.minX, f.minY, f.width, f.height, mapped.minX, mapped.minY, mapped.width, mapped.height, err, hits))
        }
        var steps: [(Double, () -> Void)] = []
        func step(_ delay: Double, _ f: @escaping () -> Void) { steps.append((delay, f)) }
        func run() {
            guard !steps.isEmpty else { return }
            let (d, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { f(); run() }
        }
        func copyViaMenu(_ tag: String, then: @escaping () -> Void) {
            pb.clearContents()
            let enabled = menuItem.map { validateMenuItem($0) } ?? false
            let sent = NSApp.sendAction(#selector(copyAllText(_:)), to: nil, from: menuItem)
            if !sent { copyAllText(menuItem) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                let text = pb.string(forType: .string) ?? ""
                log("COPY \(tag) enabled=\(enabled ? 1 : 0) sentViaResponderChain=\(sent ? 1 : 0) source=\(debugCopyTextSource) flash=\"\(hudNameLabel.stringValue)\" pasteboard=\(text.isEmpty ? "(empty)" : text.replacingOccurrences(of: "\n", with: " | "))")
                then()
            }
        }
        let names = ["01-sign.jpg", "02-screenshot.png", "03-notext.jpg"]
        // 1. 每张图：停下来以后自动分析的结果，以及直接用 Vision 识别的结果
        for name in names {
            step(0) { [self] in if let i = index(of: name) { goTo(i) } }
            step(0.3) { log("\(name) 0.3s after paging: analyses=\(lt.analysisCount) visible=\(lt.debugVisible ? 1 : 0) (dwell not reached yet)") }
            step(2.2) { [self] in
                log("\(name) LIVETEXT analyses=\(lt.analysisCount) visible=\(lt.debugVisible ? 1 : 0) lines=\(TextRecognition.lines(of: lt.transcript ?? "").joined(separator: " | "))")
                if let img = imageView.currentImage {
                    log("\(name) analyzed image \(img.width)x\(img.height) of original \(Int(imageView.pixelSize.width))x\(Int(imageView.pixelSize.height))")
                    TextRecognition.recognizeLines(in: img) { lines in log("\(name) VISION lines=\(lines.joined(separator: " | "))") }
                }
            }
            step(1.5) {}
        }
        // 2. 路牌：适应窗口 / 放大 / 平移时叠加层和照片对齐；高亮截图
        step(0) { [self] in if let i = index(of: "01-sign.jpg") { goTo(i) } }
        step(2.0) {
            align("fit", textKey: "人民路_出口", offPx: CGPoint(x: 1505, y: 655))
            overlay.selectableItemsHighlighted = true
            log("countBeforeZoom=\(lt.analysisCount)")
        }
        step(0.8) { [self] in
            captureWindow(to: outDir + "/sign-fit-highlight.png", raw: true)
            imageView.zoomActual(centeredOn: CGPoint(x: 0.47, y: 0.33), animated: false)
        }
        step(1.5) { [self] in
            align("zoomed", textKey: "人民路_出口", offPx: CGPoint(x: 1505, y: 655))
            captureWindow(to: outDir + "/sign-zoomed-highlight.png", raw: true)
            imageView.debugPan(dx: -260, dy: 140)
        }
        step(0.6) { [self] in
            align("panned", textKey: "人民路_出口", offPx: CGPoint(x: 1505, y: 655))
            log("afterZoomPan analyses=\(lt.analysisCount) (full-res swap must not re-analyze) shown image width=\(imageView.currentImage?.width ?? 0)")
            captureWindow(to: outDir + "/sign-panned-highlight.png", raw: true)
            imageView.fit()
        }
        step(0.5) {
            align("fit-again", textKey: "人民路_出口", offPx: CGPoint(x: 1505, y: 655))
            overlay.selectableItemsHighlighted = false
        }
        // 3. 菜单复制（有现成分析结果）
        step(0.2) { copyViaMenu("sign", then: {}) }
        step(3.0) {}
        // 4. 截图风格的图：高亮截图 + 菜单复制
        step(0) { [self] in if let i = index(of: "02-screenshot.png") { goTo(i) } }
        step(2.0) { [self] in
            align("shot-fit", textKey: "电话_010-6253-8899", offPx: CGPoint(x: 1400, y: 800))
            overlay.selectableItemsHighlighted = true
        }
        step(0.8) { [self] in
            captureWindow(to: outDir + "/screenshot-highlight.png", raw: true)
            overlay.selectableItemsHighlighted = false
            copyViaMenu("screenshot", then: {})
        }
        step(3.0) {}
        // 5. 没有文字
        step(0) { [self] in if let i = index(of: "03-notext.jpg") { goTo(i) } }
        step(2.0) { copyViaMenu("notext", then: {}) }
        step(3.0) {}
        // 6. 叠加层拿到键盘焦点（选中过文字）时，方向键照常翻页，翻页后焦点交回照片视图
        step(0) { [self] in if let i = index(of: "01-sign.jpg") { goTo(i) } }
        step(2.0) { [self] in
            guard let w = view.window else { return }
            // 真实使用时拖选文字后，第一响应者是叠加层里选文字的那个视图
            let took = w.makeFirstResponder(lt.selectionView ?? overlay)
            // 「编辑 › 拷贝」（⌘C）这时沿响应链找到的是谁：选中文字后 ⌘C 要落到叠加层上
            var r: NSResponder? = w.firstResponder, copyTarget: NSResponder?
            while let cur = r, copyTarget == nil { if cur.responds(to: #selector(NSText.copy(_:))) { copyTarget = cur }; r = cur.nextResponder }
            log("KEYS copy: firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") copyTarget=\(copyTarget.map { String(describing: type(of: $0)) } ?? "nil")")
            let before = folder.index
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                        characters: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
                                        charactersIgnoringModifiers: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), isARepeat: false, keyCode: 124) {
                w.sendEvent(e)
            }
            log("KEYS overlayTookFocus=\(took ? 1 : 0) index \(before)→\(folder.index) firstResponderAfter=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        // 6b. 选中文字后「编辑 › 拷贝」：macOS 14 起用 selectedText；再试 macOS 13 的做法（⌘C 交给叠加层）
        step(0) { [self] in if let i = index(of: "01-sign.jpg") { goTo(i) } }
        step(2.0) { [self] in
            guard #available(macOS 14, *) else { log("SELCOPY skipped (macOS 13)"); return }
            let copyItem = NSMenuItem(title: "", action: #selector(copy(_:)), keyEquivalent: "")
            let enabledBefore = validateMenuItem(copyItem)
            let full = overlay.text
            if let r = full.range(of: "People Road") { overlay.selectedRanges = [r] }
            let enabledAfter = validateMenuItem(copyItem)
            pb.clearContents()
            copy(copyItem)
            log("SELCOPY selected=\"\(overlay.selectedText)\" copyEnabled before=\(enabledBefore ? 1 : 0) after=\(enabledAfter ? 1 : 0) pasteboard=\(pb.string(forType: .string) ?? "(empty)")")
            pb.clearContents()
            lt.copySelection(legacy: true)
        }
        step(0.5) {
            log("SELCOPY legacy(selection view copies itself) pasteboard=\(pb.string(forType: .string) ?? "(empty)")")
        }
        // 6c. 放大后原图已经换上来时用原图分析（4500 万像素）：看分析能不能出结果、花多久
        if index(of: "16-big.jpg") != nil {
            var t0: CFAbsoluteTime = 0
            step(0) { [self] in if let i = index(of: "16-big.jpg") { goTo(i) } }
            step(2.0) { [self] in
                log("BIG preview analysis visible=\(lt.debugVisible ? 1 : 0) image=\(imageView.currentImage?.width ?? 0)")
                imageView.zoomActual(centeredOn: CGPoint(x: 0.5, y: 0.5), animated: false)
            }
            step(3.0) { [self] in
                guard let img = imageView.currentImage else { return }
                t0 = CFAbsoluteTimeGetCurrent()
                lt.analyze(img)
                log("BIG analyzing full-res directly \(img.width)x\(img.height)")
            }
            step(6.0) { [self] in
                log(String(format: "BIG full-res direct: hasAnalysis=%d after %.1fs (system fails on images this large)", lt.transcript != nil ? 1 : 0, CFAbsoluteTimeGetCurrent() - t0))
                // 走正常入口：重新计停留时间，到时候按大小挑图
                scheduleLiveText(restart: true)
            }
            step(3.0) { [self] in log("BIG via viewer: shown=\(imageView.currentImage?.width ?? 0) analyzed=\(lt.analyzedImage?.width ?? 0) hasAnalysis=\(lt.transcript != nil ? 1 : 0) visible=\(lt.debugVisible ? 1 : 0)") }
            // 路牌原图 4000×3000：放大后换上来的原图直接分析
            step(0) { [self] in if let i = index(of: "01-sign.jpg") { goTo(i) } }
            step(1.5) { [self] in imageView.zoomActual(centeredOn: CGPoint(x: 0.5, y: 0.5), animated: false) }
            step(2.5) { [self] in
                guard let img = imageView.currentImage else { return }
                lt.analyze(img)
                log("BIG sign full-res \(img.width)x\(img.height) bpc=\(img.bitsPerComponent) alpha=\(img.alphaInfo.rawValue)")
            }
            step(4.0) { log("BIG sign full-res hasAnalysis=\(lt.transcript != nil ? 1 : 0) lines=\(TextRecognition.lines(of: lt.transcript ?? "").joined(separator: " | "))") }
        }
        // 7. 关掉设置：不再自动分析；菜单命令照常可用（走 Vision）
        step(1.0) { [self] in
            TextRecognition.autoAnalyze = false
            SettingsWindowController.notify("liveText")
            log("SETTING off visibleAfterOff=\(lt.debugVisible ? 1 : 0)")
            if let i = index(of: "02-screenshot.png") { goTo(i) }
        }
        var countAtOff = 0
        step(0.01) { countAtOff = lt.analysisCount }
        step(2.0) { [self] in
            log("SETTING off: analyses \(countAtOff)→\(lt.analysisCount) visible=\(lt.debugVisible ? 1 : 0)")
            copyViaMenu("screenshot-settingOff", then: {})
        }
        step(3.0) {
            TextRecognition.autoAnalyze = true
            SettingsWindowController.notify("liveText")
        }
        step(2.0) { log("SETTING on again: analyses \(countAtOff)→\(lt.analysisCount) visible=\(lt.debugVisible ? 1 : 0)") }
        // 8. 连翻：30ms 一张连翻 40 张，期间不应开始任何分析；停下来半秒后只分析停住的那一张
        var burstStart = 0, maxDuringBurst = 0, rapidSeen = false
        step(0.5) { [self] in
            Self.wrapAround = true
            burstStart = lt.analysisCount
            var n = 0
            let timer = Timer(timeInterval: 0.03, repeats: true) { [self] t in
                navigate(1)
                rapidSeen = rapidSeen || rapidPaging
                maxDuringBurst = max(maxDuringBurst, lt.analysisCount - burstStart)
                n += 1
                if n >= 40 {
                    t.invalidate()
                    log("BURST done steps=\(n) rapidPagingSeen=\(rapidSeen ? 1 : 0) analysesDuringBurst=\(maxDuringBurst) analyzing=\(lt.isAnalyzing ? 1 : 0)")
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        step(1.6) { log("BURST at end (+0.4s) analyses=\(lt.analysisCount - burstStart)") }
        step(0.25) { log("BURST after dwell analyses=\(lt.analysisCount - burstStart) (expect 1, only the photo it stopped on)") }
        step(2.0) { [self] in
            log("BURST settled analyses=\(lt.analysisCount - burstStart) visible=\(lt.debugVisible ? 1 : 0) on=\(folder.current?.url.lastPathComponent ?? "-")")
            TextRecognition.autoAnalyze = savedAuto
            Self.wrapAround = savedWrap
            pb.clearContents()
            if !savedPB.isEmpty { pb.writeObjects(savedPB) }
            log("done")
            NSApp.terminate(nil)
        }
        run()
    }

    func runPeekKeepTest() {
        guard let w = view.window else { return }
        let saved = ViewerViewController.peekKeepsPosition
        func center() -> String { String(format: "(%.0f,%.0f) size=%.0fx%.0f", w.frame.midX, w.frame.midY, w.frame.width, w.frame.height) }
        _ = beginPeek()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSLog("PEEKKEEP entered: %@", center())
            w.setFrameOrigin(CGPoint(x: w.frame.minX + 200, y: w.frame.minY - 100))
            NSLog("PEEKKEEP moved +200,-100: %@", center())
            ViewerViewController.peekKeepsPosition = true
            self.goTo(self.folder.index + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NSLog("PEEKKEEP next (keep on): %@", center())
                ViewerViewController.peekKeepsPosition = false
                self.goTo(self.folder.index + 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSLog("PEEKKEEP next (keep off): %@", center())
                    ViewerViewController.peekKeepsPosition = saved
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// --windragtest <文件夹>：适应窗口时拖照片移动窗口、照片不动；放大后拖动平移照片、窗口不动；单击、双击照旧
    func runWindowDragTest() {
        guard let w = view.window else { return }
        ZoomableImageView.debugManualWindowDrag = true
        let center = imageView.convert(NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: imageView.mouseDown(with: e)
            case .leftMouseDragged: imageView.mouseDragged(with: e)
            default: imageView.mouseUp(with: e)
            }
        }
        // 窗口移动后，同一个屏幕位置在窗口里的坐标会变；按屏幕坐标模拟真实拖动
        func drag(by d: CGVector) {
            let startScreen = w.convertPoint(toScreen: center)
            mouse(.leftMouseDown, center)
            for k in 1...10 {
                let target = CGPoint(x: startScreen.x + d.dx * CGFloat(k) / 10, y: startScreen.y + d.dy * CGFloat(k) / 10)
                mouse(.leftMouseDragged, w.convertPoint(fromScreen: target))
            }
            mouse(.leftMouseUp, w.convertPoint(fromScreen: CGPoint(x: startScreen.x + d.dx, y: startScreen.y + d.dy)))
        }
        func state() -> String {
            let v = imageView.viewState
            return String(format: "win=(%.0f,%.0f) fit=%d zoom=%.2f center=(%.3f,%.3f)", w.frame.minX, w.frame.minY, v.fit ? 1 : 0, v.zoom, v.center.x, v.center.y)
        }
        NSLog("WINDRAG before: %@", state())
        drag(by: CGVector(dx: 120, dy: -80))
        NSLog("WINDRAG after fit drag (+120,-80): %@", state())
        imageView.toggleFitActual(at: imageView.convert(center, from: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSLog("WINDRAG zoomed: %@", state())
            drag(by: CGVector(dx: 120, dy: -80))
            NSLog("WINDRAG after zoomed drag (+120,-80): %@", state())
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
        // --no-strip：收起缩略图栏，照片和窗口一样大，截出来没有黑边
        if CommandLine.arguments.contains("--no-strip"), filmstripHeight.constant > 0 { toggleFilmstrip(nil) }
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
        // --idle：最后一张停着不动，等控件自己隐藏后再截一张（宣传片里「工具条自己让开」用）
        let idle = CommandLine.arguments.contains("--idle")
        let end = 0.4 + Double(total) * 1.6 + 0.5
        if idle {
            DispatchQueue.main.asyncAfter(deadline: .now() + end + 4.5) { [weak self] in
                self?.captureWindow(to: URL(fileURLWithPath: outDir)
                    .appendingPathComponent(String(format: "browse-%02d-idle.png", total)).path)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + end + (idle ? 5.5 : 0)) { NSApp.terminate(nil) }
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
    func captureWindow(to path: String, includePanel: NSWindow? = nil, raw: Bool = false) {
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
                    Self.renameCompanions(of: item.url, to: folderURL.appendingPathComponent(candidate))
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
        let isVideo = Video.isVideo(url)
        item.setDuration(isVideo ? Video.cachedMeta(url)?.duration : nil)
        if let cached = loader.cachedThumb(for: url) {
            item.setThumbnail(cached)
        } else {
            item.setThumbnail(nil)
            thumbQueue.addOperation { [loader] in
                let t = loader.thumb(for: url)
                // 视频出缩略图时顺带读过文件头，时长已经在缓存里
                let d = isVideo ? Video.cachedMeta(url)?.duration : nil
                DispatchQueue.main.async {
                    if item.itemIndex == idx {
                        item.setThumbnail(t)
                        if isVideo { item.setDuration(d) }
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

final class ToolbarButton: NSButton {
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
                || menuItem.action == #selector(closePhotosOrWindow(_:))
                || menuItem.action == #selector(showAbout(_:)) || menuItem.action == #selector(showShortcuts(_:))
        }
        if menuItem.action == #selector(toggleCleanup(_:)) {
            menuItem.state = .off
            return folder.count > 0
        }
        if menuItem.action == #selector(restoreLastTrash(_:)) {
            return Self.canRestoreTrash && !isProcessing
        }
        if menuItem.action == #selector(revealLastTrash(_:)) {
            return Self.canRestoreTrash
        }
        if menuItem.action == #selector(undo(_:)) {
            if let w = view.window, w.firstResponder is NSText { return w.undoManager?.canUndo ?? false }
            return Self.canRestoreTrash && !isProcessing
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
        } else if menuItem.action == #selector(closePhotosOrWindow(_:)) {
            menuItem.title = folder.totalCount > 0 ? L10n.t("menu.closePhotos", "关闭照片") : L10n.t("menu.close", "关闭窗口")
        } else if menuItem.action == #selector(togglePinned(_:)) {
            menuItem.state = isPinned ? .on : .off
        } else if menuItem.action == #selector(shareCurrent(_:)) {
            return folder.current != nil && cleanup == nil
        } else if menuItem.action == #selector(toggleToolbar(_:)) {
            menuItem.state = Self.showToolbar ? .on : .off
        } else if menuItem.action == #selector(toggleMark(_:)) {
            menuItem.title = markMenuTitle
            return folder.current != nil
        } else if menuItem.action == #selector(toggleMarkedOnly(_:)) {
            menuItem.state = folder.markedOnly ? .on : .off
            return folder.current != nil
        } else if menuItem.action == #selector(copy(_:)) {
            return liveText?.hasTextSelection == true || (cleanup == nil && folder.current != nil)
        } else if menuItem.action == #selector(copyAllText(_:)) {
            return folder.current != nil && imageView.debugHasImage && mainViewerActive
        }
        #if FLIPIC_PRO
        if menuItem.action == #selector(toggleBeforeAfter(_:)) {
            menuItem.state = beforeAfter != nil ? .on : .off
            return folder.current != nil
        } else if menuItem.action == #selector(sendToSlot(_:)) {
            menuItem.title = SendTo.menuTitle(menuItem.tag)
            return folder.current != nil && !isProcessing
        } else if menuItem.action == #selector(toggleSendToMoves(_:)) {
            menuItem.state = SendTo.moves ? .on : .off
        } else if menuItem.action == #selector(splitByRating(_:)) {
            return folder.totalCount > 0 && !isProcessing
        } else if menuItem.action == #selector(toggleMergePairs(_:)) {
            menuItem.state = Pairs.merge ? .on : .off
        } else if menuItem.action == #selector(switchPairMember(_:)) {
            return Pairs.merge && folder.current != nil
        } else if menuItem.action == #selector(trashUnpicked(_:)) {
            return folder.totalCount > 0 && !isProcessing
        } else if menuItem.action == #selector(openAllInEditor(_:)) {
            return folder.count > 0
        } else if menuItem.action == #selector(searchContent(_:)) {
            menuItem.state = contentSearch?.isOpen == true ? .on : .off
            return folder.totalCount > 0
        }
        #endif
        return true
    }
}

// MARK: - 右键「打开方式」子菜单

extension ViewerViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { populateOpenWithMenu(menu) }
}

extension ViewerViewController: PHLivePhotoViewDelegate {
    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        livePhotoView.isHidden = true
    }
}

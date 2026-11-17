import AppKit
import MapKit

/// 照片信息面板里的位置小地图。地图图块来自 Apple 的服务器，请求里带着照片的大概位置，
/// 所以默认不自动加载：先给一个「显示地图」按钮，点了才联网。没有位置的照片、面板收起时不发任何请求
enum LocationMap {
    static let autoKey = "infoMapAuto"
    static let didChange = Notification.Name("FlipicInfoMapSettingDidChange")

    /// 设置里的「在信息面板里显示位置地图」，存在偏好设置里
    static var autoShow: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set {
            guard newValue != autoShow else { return }
            UserDefaults.standard.set(newValue, forKey: autoKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// 点过一次「显示地图」之后，本次运行里每张照片都自动加载；不写进偏好设置，下次启动还是先问
    static var sessionAuto = false

    static var shouldLoad: Bool { autoShow || sessionAuto }

    /// 翻页后等这么久还停在这一张才发请求，快速翻过去的照片不会每张都请求
    static var debounce: TimeInterval = 0.25

    /// 地图范围：左右约 2 公里
    static let spanMeters: Double = 2000

    struct Request {
        let latitude: Double
        let longitude: Double
        /// 点
        let size: CGSize
        let scale: CGFloat
        let appearance: NSAppearance
    }

    /// 取一张地图图片；在主线程回调，失败给 nil。返回的闭包用来取消
    typealias Provider = (Request, @escaping (NSImage?) -> Void) -> (() -> Void)

    /// 自测时换成假的，不联网
    static var provider: Provider = appleSnapshot
    /// 点地图时怎么打开网址；自测时换掉
    static var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 30
        return c
    }()

    /// 坐标取到小数点后 4 位（约 10 米）+ 尺寸 + 深浅色
    static func cacheKey(latitude: Double, longitude: Double, size: CGSize, dark: Bool) -> String {
        String(format: "%.4f,%.4f|%.0fx%.0f|%@", latitude, longitude, size.width, size.height, dark ? "dark" : "light")
    }

    private static func appleSnapshot(_ r: Request, _ completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
        let options = MKMapSnapshotter.Options()
        let height = r.size.width > 0 ? spanMeters * Double(r.size.height / r.size.width) : spanMeters
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
                                            latitudinalMeters: height, longitudinalMeters: spanMeters)
        options.size = r.size
        options.appearance = r.appearance
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start(with: .global(qos: .userInitiated)) { snapshot, _ in
            let image = snapshot?.image
            DispatchQueue.main.async { completion(image) }
        }
        return { snapshotter.cancel() }
    }
}

final class LocationMapView: NSView {
    static let height: CGFloat = 140

    enum State { case idle, placeholder, loading, loaded, failed }
    private(set) var state = State.idle

    private let size: CGSize
    private var targetKey: String?
    private var link: URL?
    private var latitude = 0.0, longitude = 0.0
    /// 每换一个目标、每发一次请求加一：晚回来的结果对不上号就丢掉
    private var token = 0
    private var debounceItem: DispatchWorkItem?
    private var cancelRequest: (() -> Void)?
    /// 现在显示的这张图是哪个坐标的（自测用）
    private(set) var shownCoordinateKey: String?

    private let imageView = NSImageView()
    private let pin = PinView()
    private let spinner = NSProgressIndicator()
    private let failedLabel = NSTextField(labelWithString: L10n.t("info.map.failed", "地图加载不了"))
    private let showButton = NSButton(title: L10n.t("info.map.show", "显示地图"), target: nil, action: nil)
    private let noteLabel = NSTextField(wrappingLabelWithString: L10n.t("info.map.note", "地图来自 Apple 地图，需要联网加载"))
    private let alwaysButton = NSButton(title: L10n.t("info.map.always", "以后自动显示"), target: nil, action: nil)
    private let placeholder = NSStackView()

    init(width: CGFloat) {
        size = CGSize(width: width, height: Self.height)
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityElement(false)
        pin.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        failedLabel.font = .systemFont(ofSize: 11)
        failedLabel.textColor = .secondaryLabelColor
        failedLabel.translatesAutoresizingMaskIntoConstraints = false

        showButton.bezelStyle = .rounded
        showButton.controlSize = .small
        showButton.font = .systemFont(ofSize: 11)
        showButton.target = self
        showButton.action = #selector(showClicked)
        showButton.refusesFirstResponder = true

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.alignment = .center
        noteLabel.isSelectable = false
        noteLabel.preferredMaxLayoutWidth = width - 32

        alwaysButton.isBordered = false
        alwaysButton.font = .systemFont(ofSize: 10)
        alwaysButton.contentTintColor = .linkColor
        alwaysButton.target = self
        alwaysButton.action = #selector(alwaysClicked)
        alwaysButton.refusesFirstResponder = true

        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 6
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.setViews([showButton, noteLabel, alwaysButton], in: .top)
        placeholder.setCustomSpacing(2, after: noteLabel)

        addSubview(imageView)
        addSubview(pin)
        addSubview(spinner)
        addSubview(failedLabel)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pin.centerXAnchor.constraint(equalTo: centerXAnchor),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            failedLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            failedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: width - 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.t("info.map.label", "拍摄地点地图"))
        applyState()
        applyColors()
        NotificationCenter.default.addObserver(self, selector: #selector(settingChanged), name: LocationMap.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { cancelWork() }

    // MARK: - 目标

    /// 面板里排到了一张有位置的照片。同一个位置重复调用（面板重排）什么也不做
    func show(latitude: Double, longitude: Double, link: URL?) {
        let key = Self.coordinateKey(latitude, longitude)
        self.link = link
        guard key != targetKey || state == .idle else {
            // 别的窗口里点过「显示地图」：这里还在占位的也跟着加载
            if state == .placeholder, LocationMap.shouldLoad { startLoading(after: 0) }
            return
        }
        cancelWork()
        targetKey = key
        shownCoordinateKey = nil
        self.latitude = latitude
        self.longitude = longitude
        if LocationMap.shouldLoad {
            // 看过的地方直接用缓存，不再请求；没有再等一会儿发请求
            if let cached = LocationMap.cache.object(forKey: cacheKey() as NSString) {
                display(cached)
            } else {
                startLoading(after: LocationMap.debounce)
            }
        } else {
            state = .placeholder
            applyState()
        }
    }

    /// 这张照片没有位置、翻到了别处、面板收起：取消还在排队和还在路上的请求
    func reset() {
        cancelWork()
        targetKey = nil
        link = nil
        shownCoordinateKey = nil
        imageView.image = nil
        state = .idle
        applyState()
    }

    private static func coordinateKey(_ lat: Double, _ lon: Double) -> String { String(format: "%.4f,%.4f", lat, lon) }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func cacheKey() -> String {
        LocationMap.cacheKey(latitude: latitude, longitude: longitude, size: size, dark: isDark)
    }

    private func cancelWork() {
        token += 1
        debounceItem?.cancel()
        debounceItem = nil
        cancelRequest?()
        cancelRequest = nil
    }

    // MARK: - 加载

    private func startLoading(after delay: TimeInterval) {
        cancelWork()
        state = .loading
        applyState()
        let t = token
        if delay <= 0 { fire(t); return }
        let item = DispatchWorkItem { [weak self] in self?.fire(t) }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func fire(_ t: Int) {
        guard t == token, let key = targetKey else { return }
        debounceItem = nil
        let cacheKey = cacheKey()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let request = LocationMap.Request(latitude: latitude, longitude: longitude, size: size, scale: scale, appearance: effectiveAppearance)
        cancelRequest = LocationMap.provider(request) { [weak self] image in
            // 这期间翻到了别的照片、换了深浅色：结果作废
            guard let self, t == self.token, key == self.targetKey else { return }
            self.cancelRequest = nil
            if let image {
                LocationMap.cache.setObject(image, forKey: cacheKey as NSString)
                self.display(image)
            } else {
                self.state = .failed
                self.applyState()
            }
        }
    }

    private func display(_ image: NSImage) {
        imageView.image = image
        shownCoordinateKey = targetKey
        state = .loaded
        applyState()
    }

    private func applyState() {
        imageView.isHidden = state != .loaded
        pin.isHidden = state != .loaded
        failedLabel.isHidden = state != .failed
        placeholder.isHidden = state != .placeholder
        if state == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        toolTip = state == .loaded ? L10n.t("exif.openMaps", "在「地图」中打开") : nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - 操作

    @objc private func showClicked() {
        LocationMap.sessionAuto = true
        guard state == .placeholder else { return }
        startLoading(after: 0)
    }

    @objc private func alwaysClicked() {
        // 打开设置里的开关；通知到了会让所有还在占位的地图加载
        LocationMap.autoShow = true
        if state == .placeholder { startLoading(after: 0) }
    }

    @objc private func settingChanged() {
        if state == .placeholder, LocationMap.shouldLoad { startLoading(after: 0) }
    }

    private func open() {
        guard state == .loaded, let link else { return }
        LocationMap.opener(link)
    }

    override func mouseDown(with event: NSEvent) {
        if state == .loaded { open() } else { super.mouseDown(with: event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if state == .loaded { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard state == .loaded else { return false }
        open()
        return true
    }

    // MARK: - 外观

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        // 深浅色换了：地图也要换一张；还在占位的不用管
        guard window != nil, targetKey != nil, state == .loaded || state == .loading || state == .failed else { return }
        if let cached = LocationMap.cache.object(forKey: cacheKey() as NSString) {
            cancelWork()
            display(cached)
        } else if state != .loading || debounceItem == nil {
            startLoading(after: 0)
        }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.overlay(0.07).cgColor
            layer?.borderColor = Theme.overlay(0.2).cgColor
        }
    }

    // MARK: - 自测

    var debugButton: NSButton { showButton }
    var debugAlwaysButton: NSButton { alwaysButton }
    var debugFailedText: String? { failedLabel.isHidden ? nil : failedLabel.stringValue }
    var debugNoteText: String { noteLabel.stringValue }
    var debugSpinning: Bool { !spinner.isHidden && state == .loading }
    var debugImage: NSImage? { imageView.image }
    func debugClick() { open() }
    func debugShowClicked() { showClicked() }
    func debugAlwaysClicked() { alwaysClicked() }

    /// 圆点：白边、红心，压在地图正中
    private final class PinView: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let r = bounds.insetBy(dx: 3, dy: 3)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor(white: 0, alpha: 0.4).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fillEllipse(in: r.insetBy(dx: 2.5, dy: 2.5))
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

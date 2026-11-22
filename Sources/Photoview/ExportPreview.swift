import AppKit
import ImageIO

/// 导出窗口（⌘S 面板、批量转换）里的预览：照片按现在的选项（长边、胶片、水印、sRGB）导出后的样子。
/// 共用代码，免费功能；胶片只通过 ExportOptions.effect 和 ExportEffect 的钩子带进来，这里不认识任何胶片类型。
/// 从缩小的底图渲染（长边不超过 maxBase），水印的字号按长边的比例算，所以预览和真正导出的看上去一样大

/// 小小的加锁计数：后台渲染线程用它看自己是不是已经过期
private final class Counter {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

enum ExportPreviewRender {
    /// 预览底图的长边上限
    static let maxBase = 1400

    /// 这些选项里只有和画面有关的几项会影响预览；别的（元数据、文件大小）变了不用重画
    static func key(_ o: ExportOptions) -> ExportOptions {
        var k = o
        k.keepMetadata = true
        k.stripGPS = false
        k.stripSerial = false
        k.maxBytes = nil
        return k
    }

    /// 和 ImageExporter.encode 同一个顺序：缩小/加边框 → 胶片 → 水印 → 转 sRGB。base 已经是缩小过的底图
    static func image(base: CGImage, options: ExportOptions, fileName: String?, source: URL?) -> CGImage {
        let hasStage = options.effect != nil || options.watermark != nil
        var img = base
        if !hasStage, options.toSRGB, let s = ImageExporter.converted(img) { img = s }
        if let b = options.border {
            let exif = b.showExif ? (source.map(BorderExif.read) ?? BorderExif.sample) : nil
            let previewEdge = min(maxBase, options.maxLongEdge ?? maxBase)
            if let r = b.render(img, choice: .preset(previewEdge), exif: exif) { img = r }
        } else if let edge = options.maxLongEdge, edge < max(img.width, img.height), let s = ImageExporter.scaled(img, longEdge: edge) { img = s }
        guard hasStage else { return img }
        return ImageExporter.applyStages(img, options: options, source: source, fileName: fileName).image
    }

    /// 真正导出的像素尺寸（按底图的比例换算到原图，再套长边限制）
    static func outputSize(base: CGSize, fullScale: Double, maxLongEdge: Int?) -> (w: Int, h: Int) {
        var w = (Double(base.width) * fullScale).rounded(), h = (Double(base.height) * fullScale).rounded()
        if let edge = maxLongEdge, Double(edge) < max(w, h) {
            let s = Double(edge) / max(w, h)
            w = (w * s).rounded(); h = (h * s).rounded()
        }
        return (max(1, Int(w)), max(1, Int(h)))
    }

    /// 没有照片时的底图（和水印编辑窗口一样的示意图）
    static var placeholder: CGImage { WatermarkEditor.placeholderImage() }
}

final class ExportPreviewPane: NSView {
    private let canvas = WatermarkPreviewView()
    private let caption = NSTextField(labelWithString: "")
    private let queue = DispatchQueue(label: "app.flipic.export.preview", qos: .userInitiated)
    private let generation = Counter()
    private var debounce: DispatchWorkItem?

    /// 现在要用的选项（每次渲染前取）
    var optionsProvider: () -> ExportOptions = { ExportOptions() }
    /// 防抖
    var delay: TimeInterval = 0.1
    /// 照片的底图（缩小过、转好、裁好）；nil = 还在读，或者没有照片（用示意图）
    private var base: CGImage?
    private var fullScale = 1.0
    private var sourceURL: URL?
    private var hasSource = false
    private var lastKey: ExportOptions?
    private var pending = false
    private var sourceToken = 0
    private var inflight = 0
    private var debounceScheduled = false

    // 自测用
    private(set) var lastImage: CGImage?
    private(set) var lastMillis: Double = 0
    private(set) var deliveredCount = 0
    private(set) var droppedCount = 0
    var renderHook: (() -> Void)?
    var onDelivered: (() -> Void)?
    var debugCaption: String { caption.stringValue }
    var debugCanvas: NSView { canvas }
    var debugBaseReady: Bool { base != nil }
    var debugOutputSize: (w: Int, h: Int)?

    /// height：预览区固定高度（nil = 随所在那一列的高度伸缩）
    init(width: CGFloat, height: CGFloat? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.plain = true
        canvas.setAccessibilityLabel(L10n.t("wm.preview", "预览"))
        canvas.setAccessibilityRole(.image)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.stringValue = L10n.t("wm.preview", "预览")
        addSubview(canvas)
        addSubview(caption)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            // 「预览」两个字在上面当小标题，照片紧跟在下面靠上放
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let height { canvas.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 底图

    /// 设预览用的照片：旋转、拉直、裁剪按「导出为…」会用的那一份。在后台读，读完自动画一次
    func setSource(url: URL, turns: Int = 0, degrees: Double = 0, crop: Straighten.CropSpec? = nil) {
        hasSource = true
        sourceURL = url
        base = nil
        pending = true
        sourceToken += 1
        let token = sourceToken
        _ = generation.next()
        queue.async { [weak self] in
            let props = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            let fullLong = max(props?["PixelWidth"] as? Int ?? 0, props?["PixelHeight"] as? Int ?? 0)
            let decoded = ImageLoader.decodedFull(url: url, maxPixel: CGFloat(ExportPreviewRender.maxBase))
            let img = decoded.flatMap { Straighten.applied(to: $0, turns: turns, degrees: degrees, crop: crop) }
            let decodedLong = decoded.map { max($0.width, $0.height) } ?? 1
            let scale = fullLong > 0 ? Double(fullLong) / Double(decodedLong) : 1
            DispatchQueue.main.async {
                guard let self, self.sourceToken == token else { return }
                self.base = img
                self.fullScale = max(1, scale)
                if img == nil { self.hasSource = false }
                self.pending = false
                self.lastKey = nil
                self.render()
            }
        }
    }

    // MARK: - 渲染

    /// 选项变了：防抖之后重画
    func scheduleUpdate() {
        debounce?.cancel()
        debounceScheduled = true
        let work = DispatchWorkItem { [weak self] in self?.render() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 马上画一次（跳过防抖）。画面相关的选项没变就什么都不做
    func render(force: Bool = false) {
        debounce?.cancel()
        debounceScheduled = false
        if pending { return }
        let opts = optionsProvider()
        let key = ExportPreviewRender.key(opts)
        if !force, key == lastKey, lastImage != nil { return }
        lastKey = key
        let source = base ?? ExportPreviewRender.placeholder
        let name = hasSource ? sourceURL?.deletingPathExtension().lastPathComponent : "IMG_0421"
        let url = hasSource ? sourceURL : nil
        let scale = hasSource ? fullScale : 1
        let gen = generation.next()
        let counter = generation
        inflight += 1
        queue.async { [weak self] in
            self?.renderHook?()
            // 排在后面的已经有新的了：这一张不用画
            guard counter.current == gen else {
                DispatchQueue.main.async { self?.droppedCount += 1; self?.inflight -= 1 }
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = ExportPreviewRender.image(base: source, options: opts, fileName: name, source: url)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight -= 1
                guard counter.current == gen else { self.droppedCount += 1; return }
                self.lastImage = out
                self.lastMillis = ms
                self.deliveredCount += 1
                self.canvas.image = NSImage(cgImage: out, size: .zero)
                self.updateCaption(opts, base: source, scale: scale)
                self.onDelivered?()
            }
        }
    }

    private func updateCaption(_ o: ExportOptions, base: CGImage, scale: Double) {
        var text = L10n.t("wm.preview", "预览")
        debugOutputSize = nil
        if hasSource, o.maxLongEdge != nil {
            let s = ExportPreviewRender.outputSize(base: CGSize(width: base.width, height: base.height), fullScale: scale, maxLongEdge: o.maxLongEdge)
            debugOutputSize = s
            text += " · \(s.w) × \(s.h) " + L10n.t("exp.pixels", "像素")
        }
        caption.stringValue = text
    }

    /// 自测用：等到底图读完、防抖到点、排队的渲染都送到
    func debugFlush(timeout: Double = 8) {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        } while Date() < end && (pending || debounceScheduled || inflight > 0)
    }
}

// MARK: - 多行文字框

/// 导出窗口里「本次文字」用的多行输入：约三行高，再多就滚动。回车是换行（不会触发面板上的默认按钮），Tab 跳到下一个控件
final class MultilineTextField: NSScrollView, NSTextViewDelegate {
    let textView = PlainTextView()
    /// 用户打字（或粘贴、撤销）改了内容。程序设值不触发
    var onTextChange: (() -> Void)?

    var stringValue: String {
        get { textView.string }
        set { textView.string = newValue; textView.needsDisplay = true }
    }
    var placeholderString: String? {
        get { textView.placeholder }
        set { textView.placeholder = newValue; textView.needsDisplay = true }
    }

    init(font: NSFont = .systemFont(ofSize: 13), visibleLines: Int = 3, width: CGFloat) {
        super.init(frame: .zero)
        textView.font = font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let height = ceil(lineHeight * CGFloat(visibleLines)) + 8 + 4
        textView.minSize = NSSize(width: 0, height: height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentView = textView
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        textView.setAccessibilityLabel(label)
    }

    /// 自测用：当作用户打了这些字
    func debugType(_ s: String) {
        textView.string = s
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    func textDidChange(_ notification: Notification) {
        textView.needsDisplay = true
        onTextChange?()
    }
}

final class PlainTextView: NSTextView {
    var placeholder: String?
    private var savedDefault: NSButtonCell?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let placeholder, !placeholder.isEmpty else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        let rect = NSRect(x: x, y: textContainerInset.height, width: max(0, bounds.width - 2 * x), height: max(0, bounds.height - textContainerInset.height))
        NSAttributedString(string: placeholder, attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]).draw(in: rect)
    }

    // 回车插入换行：它是文字输入，不是「确定」
    private func isPlainReturn(_ e: NSEvent) -> Bool {
        (e.keyCode == 36 || e.keyCode == 76) && e.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isPlainReturn(event) {
            insertNewline(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) { insertNewlineIgnoringFieldEditor(sender) }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    // 编辑时让窗口暂时没有默认按钮，回车只会换行；离开再还回去
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let w = window, let cell = w.defaultButtonCell {
            savedDefault = cell
            w.defaultButtonCell = nil
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let cell = savedDefault {
            window?.defaultButtonCell = cell
            savedDefault = nil
        }
        return ok
    }
}

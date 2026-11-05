import AppKit
import Vision
import VisionKit

/// 图中文字：停在一张照片上时用系统的实况文本识别，文字可以直接选中、拷贝、查询、翻译（和「预览」一样）；
/// 「复制图中全部文字」把整张图的文字放到剪贴板。系统不支持时菜单、设置、叠加层都不出现
enum TextRecognition {
    /// 测试用：-forceNoLiveText YES 当作系统不支持，看菜单和设置是否都藏起来
    private static let forcedOff = UserDefaults.standard.bool(forKey: "forceNoLiveText")

    /// 照片上直接选文字（VisionKit 实况文本），启动后只查一次
    static let liveTextSupported: Bool = !forcedOff && ImageAnalyzer.isSupported

    /// 复制全部文字：系统的文字识别至少支持一种语言
    static let canRecognize: Bool = !forcedOff && !visionLanguages.isEmpty

    /// 菜单项「复制图中全部文字」出不出现
    static var isAvailable: Bool { liveTextSupported || canRecognize }

    /// 设置 › 看图 › 自动识别图中文字，默认开；关掉后不再自动识别，菜单命令照常可用
    static var autoAnalyze: Bool {
        get { UserDefaults.standard.object(forKey: "autoLiveText") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoLiveText") }
    }

    /// 系统文字识别支持的语言，用户的首选语言排前面（语言列表全部来自系统）
    private static let visionLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let all = (try? request.supportedRecognitionLanguages()) ?? []
        return preferredFirst(all)
    }()

    /// 实况文本用的语言：同样按首选语言排序
    static var analyzerLocales: [String] { preferredFirst(ImageAnalyzer.supportedTextRecognitionLanguages) }

    /// 按系统首选语言（只看语种，zh-Hans 也要区分简繁）把支持的语言排到前面，其余保持系统给的顺序
    private static func preferredFirst(_ supported: [String]) -> [String] {
        func key(_ id: String) -> String {
            let parts = id.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let lang = parts.first?.lowercased() else { return id }
            if lang == "zh" {
                let rest = parts.dropFirst().joined(separator: "-")
                return rest.contains("Hant") || rest.contains("TW") || rest.contains("HK") ? "zh-Hant" : "zh-Hans"
            }
            return lang
        }
        var out: [String] = []
        for pref in Locale.preferredLanguages {
            for s in supported where key(s) == key(pref) && !out.contains(s) { out.append(s) }
        }
        return out + supported.filter { !out.contains($0) }
    }

    /// 整张图的文字，一行一项；在后台识别，回到主线程交结果
    static func recognizeLines(in image: CGImage, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = visionLanguages
            try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            DispatchQueue.main.async { completion(lines) }
        }
    }

    /// 实况文本的结果拆成行
    static func lines(of transcript: String) -> [String] {
        transcript.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// 叠在照片视图上的实况文本层。只分析当前这张、而且是停下来以后（由看图界面决定什么时候调 analyze）；
/// 叠加层铺满照片视图，照片在里面的位置由 contentsRect 告诉系统，缩放、平移时跟着走。
/// 没有文字的地方鼠标事件照常落到照片视图上：拖动移动窗口、放大后平移、双击缩放都不受影响
final class LiveTextController: NSObject, ImageAnalysisOverlayViewDelegate {
    private static let analyzer = ImageAnalyzer()

    private weak var imageView: ZoomableImageView?
    private let overlay = ImageAnalysisOverlayView()
    private let host = LiveTextHost()
    private var task: Task<Void, Never>?
    /// 已经分析过（或正在分析）的那张图；换图、旋转后清掉
    private(set) var analyzedImage: CGImage?
    private(set) var analysis: ImageAnalysis?
    /// 测试用：一共开始过几次分析
    private(set) var analysisCount = 0

    init(imageView: ZoomableImageView) {
        self.imageView = imageView
        super.init()
        overlay.delegate = self
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        // 不要右下角的「实况文本」按钮：会挡住工具条，照片上直接选文字就够了
        overlay.isSupplementaryInterfaceHidden = true
        host.frame = imageView.bounds
        host.autoresizingMask = [.width, .height]
        host.isHidden = true
        host.overlay = overlay
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        imageView.addSubview(host)
    }

    var isAnalyzing: Bool { task != nil }
    var debugOverlay: ImageAnalysisOverlayView { overlay }
    var debugVisible: Bool { !host.isHidden }

    /// 分析这张图；同一张已经分析过或正在分析就不重复
    func analyze(_ image: CGImage) {
        guard analyzedImage !== image else { return }
        reset()
        analyzedImage = image
        analysisCount += 1
        var config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        config.locales = TextRecognition.analyzerLocales
        BenchProbe.log("livetext analyze \(image.width)x\(image.height)")
        task = Task { @MainActor [weak self] in
            let result = try? await Self.analyzer.analyze(image, orientation: .up, configuration: config)
            guard let self, !Task.isCancelled, self.analyzedImage === image else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            self.task = nil
            self.analysis = result
            self.overlay.analysis = result
            self.host.isHidden = result == nil
            self.overlay.setContentsRectNeedsUpdate()
            BenchProbe.log("livetext shown \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        }
    }

    /// 换图、旋转、关掉设置：取消进行中的分析，收掉叠加层（选中的文字一起清掉，键盘交回照片视图）
    func reset() {
        task?.cancel()
        task = nil
        analyzedImage = nil
        analysis = nil
        if let w = host.window, let r = w.firstResponder as? NSView, r.isDescendant(of: host), let iv = imageView {
            w.makeFirstResponder(iv)
        }
        if overlay.analysis != nil {
            overlay.resetSelection()
            overlay.analysis = nil
        }
        host.isHidden = true
    }

    /// 照片视图里的这一点（翻转坐标）上有没有可选的文字或数据检测项
    func hasInteractiveItem(at point: CGPoint) -> Bool {
        guard !host.isHidden, overlay.analysis != nil, let iv = imageView else { return false }
        return overlay.hasInteractiveItem(at: Self.itemPoint(point, in: overlay, from: iv))
    }

    /// hasInteractiveItem 要的点：叠加层里左上原点的坐标（实测和叠加层自己的 isFlipped 无关，
    /// 直接用 convert 换成左下原点会上下颠倒，适应窗口时点在文字上反而落空）
    static func itemPoint(_ point: CGPoint, in overlay: NSView, from view: NSView) -> CGPoint {
        let p = overlay.convert(point, from: view)
        return overlay.isFlipped ? p : CGPoint(x: p.x, y: overlay.bounds.height - p.y)
    }

    /// 在照片上别处按下鼠标：选中的文字取消（和「预览」一样）
    func clearSelection() {
        if overlay.hasActiveTextSelection { overlay.resetSelection() }
    }

    /// 照片上选中了文字
    var hasTextSelection: Bool { !host.isHidden && overlay.hasActiveTextSelection }

    /// 「编辑 › 拷贝」（⌘C）：把选中的文字放到剪贴板。系统叠加层自己不接 copy:，菜单的 ⌘C 到不了它；
    /// macOS 13 没有取选中文字的接口，就让叠加层里选文字的视图自己拷贝（legacy 测试用）
    func copySelection(legacy: Bool = false) {
        guard hasTextSelection else { return }
        if #available(macOS 14, *), !legacy {
            let text = overlay.selectedText
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if let v = selectionView {
            _ = v.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        }
    }

    /// 叠加层里负责选文字的那个视图（系统内部的，能当第一响应者、自己会拷贝）
    var selectionView: NSView? {
        func find(_ v: NSView) -> NSView? {
            if v !== overlay, v.acceptsFirstResponder, v.responds(to: #selector(NSText.copy(_:))) { return v }
            for sv in v.subviews { if let f = find(sv) { return f } }
            return nil
        }
        return find(overlay)
    }

    /// 照片缩放、平移、窗口变大小后调用
    func imageFrameChanged() {
        guard !host.isHidden else { return }
        overlay.setContentsRectNeedsUpdate()
    }

    /// 当前这张分析完的文字（换图、旋转时已经清掉，有就是当前这张的）
    var transcript: String? { analysis?.transcript }

    // MARK: - ImageAnalysisOverlayViewDelegate

    /// 照片在叠加层里的位置，按叠加层尺寸归一化（叠加层铺满照片视图）
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        guard let iv = imageView, iv.bounds.width > 0, iv.bounds.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let f = iv.imageFrame, b = iv.bounds
        return CGRect(x: f.minX / b.width, y: f.minY / b.height, width: f.width / b.width, height: f.height / b.height)
    }

    /// 只在选中了文字时接 ⌘C、⌘A 这类按键，其余（方向键、空格、评星……）都交给照片视图
    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        overlayView.hasActiveTextSelection && event.modifierFlags.contains(.command)
    }

    // 下面六个是 macOS 14 才加的要求。不自己写的话，用的是系统扩展里的默认实现，
    // 那几个符号 macOS 13 的 VisionKit 里没有，App 一启动就被 dyld 杀掉（1.0.8 在 13.7 上的崩溃）。
    // 行为和系统默认一样：不改菜单、不处理事件
    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {}
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent, at point: CGPoint) -> NSMenu { menu }
    func overlayView(_ overlayView: ImageAnalysisOverlayView, needsUpdate menu: NSMenu) {}
    func overlayView(_ overlayView: ImageAnalysisOverlayView, willOpen menu: NSMenu) {}
    func overlayView(_ overlayView: ImageAnalysisOverlayView, didClose menu: NSMenu) {}
    func overlayView(_ overlayView: ImageAnalysisOverlayView, menu: NSMenu, willHighlight menuItem: NSMenuItem?) {}
}

/// 叠加层的外壳：只在文字、数据检测项上接鼠标，其他地方让给下面的照片视图（系统的叠加层不能继承，只能包一层）
final class LiveTextHost: NSView {
    weak var overlay: ImageAnalysisOverlayView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let overlay, overlay.analysis != nil, let superview else { return nil }
        guard overlay.hasInteractiveItem(at: LiveTextController.itemPoint(point, in: overlay, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

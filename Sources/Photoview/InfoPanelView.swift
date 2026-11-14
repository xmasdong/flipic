import AppKit

/// 照片信息面板显示多少：常用只放挑片时要看的，全部按组列出文件里能读到的各项
enum InfoLevel: Int {
    case common, all

    private static let key = "infoPanelLevel"
    static let didChange = Notification.Name("FlipicInfoLevelDidChange")

    static var current: InfoLevel {
        get { InfoLevel(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .common }
        set {
            guard newValue != current else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// 右上角的照片信息面板：标题栏（常用 | 全部）固定，下面的内容比窗口高时可以滚
final class InfoPanelView: NSVisualEffectView {
    static let width: CGFloat = 300
    private static let inset: CGFloat = 16
    private static var contentWidth: CGFloat { width - inset * 2 }
    /// 说明超过这么多行就先收起
    private static let collapsedLines = 8

    /// 说明里的字被选中时焦点在面板上；重排或按 Esc 时把焦点还给照片，方向键才继续翻页
    var onReleaseFocus: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let levelControl = NSSegmentedControl(labels: [L10n.t("info.level.common", "常用"), L10n.t("info.level.all", "全部")],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()

    private var info = PhotoInfo()
    private var rating = 0
    private var isVideo = false
    private var captionExpanded = false
    /// 面板里现在排的是哪个文件的信息；nil 是空的
    private(set) var shownURL: URL?

    /// 说明的翻译走到哪一步了。none = 不出现「翻译」按钮（系统不支持、认不出语言、已经是界面语言、这对语言翻不了）
    private enum TranslationPhase {
        case none
        case idle(installed: Bool)
        case running
        case shown([String])
        case failed(String, installed: Bool)
    }
    /// 现在这段说明（标题、正文）和目标语言；换了照片就换，翻译状态跟着清掉
    private var translationKey: CaptionTranslation.Key?
    private var translationSource: String?
    private var translationPhase = TranslationPhase.none
    private var translationJob: CaptionTranslation.Job?
    /// 每换一段说明加一：晚回来的结果对不上号就丢掉，译文不会排到别的照片下面
    private var translationToken = 0

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.lineBreakMode = .byTruncatingTail

        levelControl.controlSize = .small
        levelControl.font = .systemFont(ofSize: 11)
        levelControl.target = self
        levelControl.action = #selector(levelPicked(_:))
        levelControl.refusesFirstResponder = true
        levelControl.translatesAutoresizingMaskIntoConstraints = false
        levelControl.setContentHuggingPriority(.required, for: .horizontal)
        levelControl.setAccessibilityLabel(L10n.t("menu.infoLevel", "显示全部照片信息"))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 14, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        addSubview(titleLabel)
        addSubview(levelControl)
        addSubview(scroll)

        // 内容多高面板就多高；外面把面板底边限制在窗口里，放不下时这一条让步，内容改成滚动
        let fit = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        // 优先级要低于窗口保持自身大小的 500，不然内容一长会把窗口撑高
        fit.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            levelControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            levelControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            levelControl.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            fit,
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(levelChanged), name: InfoLevel.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(autoTranslateChanged), name: CaptionTranslation.didChange, object: nil)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 内容

    func show(_ info: PhotoInfo, url: URL, rating: Int, isVideo: Bool) {
        let sameFile = shownURL == url
        if !sameFile { captionExpanded = false }
        self.info = info
        self.rating = rating
        self.isVideo = isVideo
        shownURL = url
        syncTranslation()
        rebuild(keepScroll: sameFile)
    }

    /// 换了一张、新的信息还没读出来：先清空，不留着上一张的字
    func clear(isVideo: Bool) {
        guard shownURL != nil else { return }
        info = PhotoInfo()
        rating = 0
        self.isVideo = isVideo
        shownURL = nil
        captionExpanded = false
        syncTranslation()
        rebuild()
    }

    @objc private func levelPicked(_ sender: NSSegmentedControl) {
        InfoLevel.current = sender.selectedSegment == 1 ? .all : .common
    }

    @objc private func levelChanged() {
        rebuild()
    }

    private func rebuild(keepScroll: Bool = false) {
        if let w = window, let r = w.firstResponder as? NSView, r.isDescendant(of: self) { onReleaseFocus?() }
        let offset = scroll.contentView.bounds.origin
        for v in stack.arrangedSubviews { v.removeFromSuperview() }

        titleLabel.stringValue = isVideo ? L10n.t("ui.videoInfoTitle", "视频信息") : L10n.t("ui.exifTitle", "照片信息")
        let level = InfoLevel.current
        levelControl.selectedSegment = level == .all ? 1 : 0
        levelControl.isHidden = isVideo || info.isFlat

        if shownURL != nil {
            if info.isFlat || level == .common { buildCommon() } else { buildAll() }
        }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: keepScroll ? offset : .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func buildCommon() {
        let hasCaption = addCaptionBlock(showBoilerplate: false)
        addRating()
        if info.common.isEmpty && !hasCaption {
            let none = NSTextField(labelWithString: L10n.t("ui.noExif", "此文件没有 EXIF 信息"))
            none.font = .systemFont(ofSize: 12)
            none.textColor = .secondaryLabelColor
            stack.addArrangedSubview(none)
        }
        info.common.forEach(addRow)
    }

    private func buildAll() {
        measureLabelColumn()
        let hasCaptionText = info.title != nil || info.caption != nil
        if hasCaptionText || !info.captionRows.isEmpty || rating > 0 {
            addSectionHeader(L10n.t("exif.sec.caption", "说明"))
            addCaptionBlock(showBoilerplate: true)
            info.captionRows.forEach(addPairRow)
            if rating > 0 {
                let v = NSTextField(labelWithString: Rating.stars(rating))
                v.font = .systemFont(ofSize: 12)
                v.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.25, alpha: 1)
                addPair(label: L10n.t("menu.rating", "评分"), value: v)
            }
        }
        for s in info.sections {
            addSectionHeader(s.title)
            s.rows.forEach(addPairRow)
        }
        if stack.arrangedSubviews.isEmpty {
            let none = NSTextField(labelWithString: L10n.t("ui.noExif", "此文件没有 EXIF 信息"))
            none.font = .systemFont(ofSize: 12)
            none.textColor = .secondaryLabelColor
            stack.addArrangedSubview(none)
        }
    }

    /// 标题粗体，说明占满面板宽度；都可以选中拷贝，说明里的网址可以点。返回有没有排出东西
    @discardableResult
    private func addCaptionBlock(showBoilerplate: Bool) -> Bool {
        let caption = info.caption.flatMap { showBoilerplate || !info.captionIsBoilerplate ? $0 : nil }
        guard info.title != nil || caption != nil else { return false }
        let block = CaptionBlockView(width: Self.contentWidth)
        captionIsLong = false
        if let t = info.title {
            let title = InfoTextView(text: t, font: .boldSystemFont(ofSize: 13), width: Self.contentWidth, linkify: false)
            title.setAccessibilityLabel(L10n.t("exif.title", "标题"))
            wire(title)
            block.text.addArrangedSubview(title)
        }
        if let c = caption {
            let font = NSFont.systemFont(ofSize: 12)
            let body = InfoTextView(text: c, font: font, width: Self.contentWidth, linkify: true)
            body.setAccessibilityLabel(L10n.t("exif.sec.caption", "说明"))
            wire(body)
            // 只多出一两行就不折叠了：点一下「展开」才多看到一行，不值得
            let long = body.lineCount(limit: 0) > Self.collapsedLines + 2
            if long && !captionExpanded { body.maxLines = Self.collapsedLines }
            block.text.addArrangedSubview(body)
            captionIsLong = long
            if long {
                let b = NSButton(title: captionExpanded ? L10n.t("info.collapse", "收起") : L10n.t("info.expand", "展开"),
                                 target: self, action: #selector(toggleCaption(_:)))
                b.isBordered = false
                b.font = .systemFont(ofSize: 11)
                b.contentTintColor = .linkColor
                b.refusesFirstResponder = true
                block.addAction(b)
            }
        }
        addTranslation(to: block, showsCaption: caption != nil)
        stack.addArrangedSubview(block)
        stack.setCustomSpacing(10, after: block)
        return true
    }

    // MARK: - 翻译

    private var captionIsLong = false
    /// 译文的颜色：比原文淡一级。NSTextView 里的 secondaryLabelColor 在磨砂面板上没有提亮，淡得看不清，所以自己定
    private static let translationColor = Theme.gray(dark: 0.74, light: 0.32)

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = .systemFont(ofSize: 11)
        b.contentTintColor = .linkColor
        b.refusesFirstResponder = true
        return b
    }

    private func quietLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    /// 说明下面的「翻译」按钮和译文。译文排在原文下面，字小一号、颜色淡一级，原文一直在
    private func addTranslation(to block: CaptionBlockView, showsCaption: Bool) {
        switch translationPhase {
        case .none:
            return
        case .idle(let installed):
            let b = smallButton(L10n.t("info.translate", "翻译"), #selector(translateClicked(_:)))
            if !installed { b.toolTip = L10n.t("info.translateNeedsDownload", "需要先下载翻译语言，点击后由系统询问") }
            block.addAction(b)
        case .running:
            block.addAction(quietLabel(L10n.t("info.translating", "正在翻译…")))
        case .failed(let reason, _):
            block.addAction(smallButton(L10n.t("info.translate", "翻译"), #selector(translateClicked(_:))))
            let l = quietLabel(L10n.f("info.translateFailed", "没能翻译：%@", reason))
            l.toolTip = reason
            block.addAction(l)
        case .shown(let texts):
            block.addAction(smallButton(L10n.t("info.hideTranslation", "隐藏译文"), #selector(translateClicked(_:))))
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 5
            box.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            box.addArrangedSubview(line)
            line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            let tag = NSTextField(labelWithString: L10n.t("info.translationLabel", "译文"))
            tag.font = .systemFont(ofSize: 10, weight: .semibold)
            tag.textColor = .tertiaryLabelColor
            box.addArrangedSubview(tag)
            let hasTitle = info.title != nil
            if hasTitle, let t = texts.first, !t.isEmpty {
                let v = InfoTextView(text: t, font: .systemFont(ofSize: 12, weight: .semibold), width: Self.contentWidth, linkify: false, color: Self.translationColor)
                v.setAccessibilityLabel(L10n.t("info.translationLabel", "译文"))
                wire(v)
                box.addArrangedSubview(v)
            }
            if showsCaption, let c = texts.last, !c.isEmpty, texts.count == (hasTitle ? 2 : 1) {
                let v = InfoTextView(text: c, font: .systemFont(ofSize: 11.5), width: Self.contentWidth, linkify: true, color: Self.translationColor)
                v.setAccessibilityLabel(L10n.t("info.translationLabel", "译文"))
                wire(v)
                // 原文收着的时候译文也只露出开头几行，跟着同一个「展开」
                if captionIsLong && !captionExpanded { v.maxLines = Self.collapsedLines }
                box.addArrangedSubview(v)
            }
            block.addExtra(box)
        }
    }

    /// 现在排的这段说明该不该有「翻译」：换了说明就重新判断；缓存里有的直接显示
    private func syncTranslation() {
        var texts: [String] = []
        if shownURL != nil, CaptionTranslation.isAvailable {
            if let t = info.title { texts.append(t) }
            if let c = info.caption, !info.captionIsBoilerplate { texts.append(c) }
        }
        let key = texts.isEmpty ? nil : CaptionTranslation.Key(texts: texts, target: CaptionTranslation.targetLanguage)
        guard key != translationKey else { return }
        translationJob?.cancel()
        translationJob = nil
        translationToken += 1
        translationKey = key
        translationSource = nil
        translationPhase = .none
        guard let key else { return }
        if let done = CaptionTranslation.cached(key) {
            translationPhase = CaptionTranslation.isHidden(key) ? .idle(installed: true) : .shown(done)
            return
        }
        guard let source = CaptionTranslation.detectLanguage(texts), !CaptionTranslation.sameLanguage(source, key.target) else { return }
        translationSource = source
        let token = translationToken
        CaptionTranslation.readiness(from: source, to: key.target) { [weak self] r in
            guard let self, self.translationToken == token else { return }
            switch r {
            case .unavailable: return
            case .needsDownload: self.translationPhase = .idle(installed: false)
            case .installed:
                self.translationPhase = .idle(installed: true)
                // 自动翻译只在语言已经装好时做，不会自己弹出下载询问。稍等一下再开始：按住方向键连翻时不用每张都翻
                if CaptionTranslation.autoTranslate { self.startTranslation(installed: true, delay: 0.2) }
            }
            self.rebuild(keepScroll: true)
        }
    }

    private func startTranslation(installed: Bool, delay: TimeInterval = 0) {
        guard let key = translationKey, let source = translationSource else { return }
        let token = translationToken
        translationPhase = .running
        translationJob?.cancel()
        translationJob = CaptionTranslation.translate(key, from: source, installed: installed, delay: delay, anchor: self) { [weak self] outcome in
            guard let self, self.translationToken == token, self.translationKey == key else { return }
            self.translationJob = nil
            switch outcome {
            case .success(let texts): self.translationPhase = .shown(texts)
            case .declined: self.translationPhase = .idle(installed: false)
            case .failed(let reason): self.translationPhase = .failed(reason, installed: installed)
            }
            self.rebuild(keepScroll: true)
        }
    }

    @objc private func translateClicked(_ sender: Any?) {
        guard let key = translationKey else { return }
        switch translationPhase {
        case .shown:
            CaptionTranslation.setHidden(key, true)
            translationPhase = .idle(installed: true)
        case .idle(let installed), .failed(_, let installed):
            CaptionTranslation.setHidden(key, false)
            if let done = CaptionTranslation.cached(key) {
                translationPhase = .shown(done)
            } else {
                startTranslation(installed: installed)
            }
        case .none, .running:
            return
        }
        rebuild(keepScroll: true)
    }

    /// 设置里开了自动翻译：现在这张语言已经装好、还没翻的，马上翻
    @objc private func autoTranslateChanged() {
        guard CaptionTranslation.autoTranslate, case .idle(true) = translationPhase, let key = translationKey, !CaptionTranslation.isHidden(key) else { return }
        if let done = CaptionTranslation.cached(key) { translationPhase = .shown(done) } else { startTranslation(installed: true) }
        rebuild(keepScroll: true)
    }

    private func wire(_ v: InfoTextView) {
        v.onEscape = { [weak self] in self?.onReleaseFocus?() }
        // 选了字以后再按方向键、I 这些：焦点还给照片，按键照常起作用
        v.onKey = { [weak self] event in
            guard let self else { return }
            self.onReleaseFocus?()
            if let r = self.window?.firstResponder, !(r is InfoTextView) { r.keyDown(with: event) }
        }
    }

    @objc private func toggleCaption(_ sender: Any?) {
        captionExpanded.toggle()
        rebuild(keepScroll: captionExpanded)
    }

    private func addRating() {
        guard rating > 0 else { return }
        let l = NSTextField(labelWithString: L10n.t("menu.rating", "评分"))
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        let v = NSTextField(labelWithString: Rating.stars(rating))
        v.font = .systemFont(ofSize: 12)
        v.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.25, alpha: 1)
        stack.addArrangedSubview(l)
        stack.addArrangedSubview(v)
    }

    /// 「全部」里每组上面的小标题；除了第一组，上面加一条细线
    private func addSectionHeader(_ title: String) {
        if let last = stack.arrangedSubviews.last {
            let line = NSBox()
            line.boxType = .separator
            stack.setCustomSpacing(12, after: last)
            addFullWidth(line)
            stack.setCustomSpacing(10, after: line)
        }
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        l.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(l)
        stack.setCustomSpacing(8, after: l)
    }

    private func addRow(_ e: ExifEntry) {
        let l = NSTextField(labelWithString: e.label)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        stack.addArrangedSubview(l)
        if let link = e.link {
            // 拍摄地点：点击在「地图」里打开
            let b = NSButton(title: e.value + "  ↗", target: self, action: #selector(openLink(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 12)
            b.contentTintColor = .linkColor
            b.alignment = .left
            b.toolTip = L10n.t("exif.openMaps", "在「地图」中打开")
            b.identifier = NSUserInterfaceItemIdentifier(link.absoluteString)
            b.refusesFirstResponder = true
            b.setAccessibilityLabel(e.label)
            stack.addArrangedSubview(b)
            return
        }
        let v = NSTextField(labelWithString: e.value)
        v.font = .systemFont(ofSize: 12)
        v.textColor = .labelColor
        v.maximumNumberOfLines = e.lines
        v.lineBreakMode = .byWordWrapping
        v.cell?.truncatesLastVisibleLine = true
        v.setAccessibilityLabel(e.label)
        v.preferredMaxLayoutWidth = 260
        // 排不下被截断的，鼠标停上去看全
        if Self.lineCount(e.value, font: v.font!, width: 256) > e.lines { v.toolTip = e.value }
        stack.addArrangedSubview(v)
    }

    // MARK: - 「全部」：两列，标签在左、值在右

    /// 标签那一列的宽度：按这张照片在当前语言下最长的标签定，最多占面板的四成；再长的标签折成两行
    private var labelColumn: CGFloat = 60
    private static let columnGap: CGFloat = 10
    private var valueColumn: CGFloat { Self.contentWidth - labelColumn - Self.columnGap }

    private func measureLabelColumn() {
        var labels = info.captionRows.map(\.label) + info.sections.flatMap { $0.rows.map(\.label) }
        if rating > 0 { labels.append(L10n.t("menu.rating", "评分")) }
        let font = NSFont.systemFont(ofSize: 11)
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) + 2 }
        let widest = labels.map(width).max() ?? 0
        labelColumn = min(max(widest, 40), floor(Self.contentWidth * 0.4))
        // 一个词就比这一列宽的（德语 Belichtungskorrektur）会从词中间折断：给它让到刚好放下，最多到面板的一半
        let longestWord = labels.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: " -")) }.map(width).max() ?? 0
        if longestWord > labelColumn { labelColumn = min(longestWord, floor(Self.contentWidth * 0.5)) }
    }

    private func addPair(label: String, value: NSView) {
        let l = NSTextField(wrappingLabelWithString: label)
        l.isSelectable = false
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = labelColumn
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: labelColumn).isActive = true
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        let row = NSStackView(views: [l, value])
        row.orientation = .horizontal
        // 标签和值的第一行对齐
        row.alignment = .firstBaseline
        row.spacing = Self.columnGap
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    /// 值在右边那一列里折行，可以选中拷贝；里面的网址、拍摄地点可以点
    private func addPairRow(_ e: ExifEntry) {
        let v = InfoTextView(text: e.value + (e.link != nil ? "  ↗" : ""), font: .systemFont(ofSize: 12), width: valueColumn, linkify: e.link == nil)
        if let link = e.link {
            v.setLink(link)
            v.toolTip = L10n.t("exif.openMaps", "在「地图」中打开")
        } else {
            // 特别长的（几十个关键词、整段使用条款）先露出一部分，鼠标停上去看全
            let limit = max(e.lines * 3, 8)
            if v.lineCount(limit: 0) > limit {
                v.maxLines = limit
                v.toolTip = e.value
            }
        }
        v.setAccessibilityLabel(e.label)
        wire(v)
        addPair(label: e.label, value: v)
    }

    private func addFullWidth(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    @objc private func openLink(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// 按给定宽度排版要占几行
    private static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines = 0
        var index = 0
        let glyphs = manager.numberOfGlyphs
        var range = NSRange()
        while index < glyphs {
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            lines += 1
        }
        return lines
    }

    // MARK: - 诊断

    /// 面板里现在排出来的所有文字，自测用
    var debugText: String {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let t = v as? InfoTextView {
                out.append(t.string + (t.debugLinks.isEmpty ? "" : " [links: " + t.debugLinks.joined(separator: " ") + "]"))
            } else if let t = v as? NSTextField { out.append(t.stringValue) } else if let b = v as? NSButton { out.append(b.title) } else {
                (v as? NSStackView)?.arrangedSubviews.filter { !$0.isHidden }.forEach(walk)
            }
        }
        walk(stack)
        return out.joined(separator: " | ")
    }

    var debugOverflow: (content: CGFloat, visible: CGFloat) { (document.frame.height, scroll.contentView.bounds.height) }

    func debugScrollToBottom() {
        let y = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 滚到第几屏（从 1 数）；没有那么多屏返回 false
    func debugScroll(toPage page: Int) -> Bool {
        let visible = scroll.contentView.bounds.height
        let y = CGFloat(page - 1) * (visible - 20)
        guard visible > 0, y < document.frame.height - visible + (visible - 20) - 1, y < document.frame.height else { return false }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, document.frame.height - visible))))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    var debugFirstText: InfoTextView? {
        func find(_ v: NSView) -> InfoTextView? { (v as? InfoTextView) ?? v.subviews.lazy.compactMap(find).first }
        return find(stack)
    }

    func debugToggleCaption() { toggleCaption(nil) }

    /// 翻译走到哪一步：none / idle / idle-download / running / shown / failed:原因
    var debugTranslationState: String {
        switch translationPhase {
        case .none: return "none"
        case .idle(let installed): return installed ? "idle" : "idle-download"
        case .running: return "running"
        case .shown: return "shown"
        case .failed(let reason, _): return "failed:" + reason
        }
    }

    /// 面板里正排着的译文（没排出来是 nil）和它对应的原文
    var debugTranslation: (source: [String], shown: [String])? {
        guard case .shown(let texts) = translationPhase, let key = translationKey else { return nil }
        return (key.texts, texts)
    }

    var debugTranslationSource: String { translationSource ?? "-" }

    /// 按一下「翻译」/「隐藏译文」
    func debugClickTranslate() { translateClicked(nil) }
}

/// 面板最上面的说明块：标题、说明正文，下面一行小按钮（展开 / 收起），再下面留给以后附加的段落。
/// 以后加「翻译」：按钮用 addAction 放进按钮行，译文用 addExtra 放到最下面，其余排版不用动
final class CaptionBlockView: NSStackView {
    /// 标题和说明正文
    let text = NSStackView()
    private let actions = NSStackView()
    private let extras = NSStackView()
    private let blockWidth: CGFloat

    init(width: CGFloat) {
        blockWidth = width
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        for s in [text, extras] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 6
        }
        actions.orientation = .horizontal
        actions.spacing = 12
        // 没东西的那一行不占地方
        actions.isHidden = true
        extras.isHidden = true
        addArrangedSubview(text)
        addArrangedSubview(actions)
        addArrangedSubview(extras)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 说明下面的小按钮，从左往右排
    func addAction(_ button: NSView) {
        actions.addArrangedSubview(button)
        actions.isHidden = false
    }

    /// 说明下面附加的整段内容（宽度同说明）
    func addExtra(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        extras.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: blockWidth).isActive = true
        extras.isHidden = false
    }
}

/// 说明块里的文字：不能改，可以选中拷贝，http(s) 网址可以点；高度跟着内容走。
/// 文字原样显示，连着的空格、弯引号都不动
final class InfoTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// 不带 ⌘ 的按键不归它管，交回去
    var onKey: ((NSEvent) -> Void)?
    /// 最多显示几行，0 不限
    var maxLines = 0 {
        didSet {
            textContainer?.maximumNumberOfLines = maxLines
            textContainer?.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
            invalidateIntrinsicContentSize()
        }
    }
    private let fixedWidth: CGFloat

    init(text: String, font: NSFont, width: CGFloat, linkify: Bool, color: NSColor = .labelColor) {
        fixedWidth = width
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 16), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        if linkify {
            for (range, url) in Self.links(in: text) { s.addAttribute(.link, value: url, range: range) }
        }
        storage.setAttributedString(s)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 文字里的 http / https 网址；句尾跟着的标点不算在内
    static func links(in text: String) -> [(NSRange, URL)] {
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s<>\"“”‘’（）()\\[\\]，。；、]+", options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var r = m.range
            while r.length > 0, ".,;:!?'".contains(ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1))) { r.length -= 1 }
            guard let url = URL(string: ns.substring(with: r)), url.host != nil else { return nil }
            return (r, url)
        }
    }

    /// 整段文字是一个链接（拍摄地点）
    func setLink(_ url: URL) {
        guard let storage = textStorage else { return }
        storage.addAttribute(.link, value: url, range: NSRange(location: 0, length: storage.length))
    }

    /// 和旁边的标签按第一行的基线对齐
    override var firstBaselineOffsetFromTop: CGFloat {
        guard let manager = layoutManager, let storage = textStorage, storage.length > 0,
              let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return super.firstBaselineOffsetFromTop }
        return manager.defaultBaselineOffset(for: font)
    }

    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        return NSSize(width: fixedWidth, height: ceil(manager.usedRect(for: container).height))
    }

    /// 排出来有几行；limit 是先临时按几行上限排（0 不限）
    func lineCount(limit: Int) -> Int {
        guard let manager = layoutManager, let container = textContainer else { return 0 }
        let saved = container.maximumNumberOfLines
        container.maximumNumberOfLines = limit
        defer { container.maximumNumberOfLines = saved }
        manager.ensureLayout(for: container)
        var lines = 0, index = 0
        var range = NSRange()
        let glyphs = manager.numberOfGlyphs
        while index < glyphs {
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            lines += 1
        }
        return lines
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        onKey?(event)
    }

    var debugLinks: [String] {
        var out: [String] = []
        guard let storage = textStorage else { return out }
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let u = v as? URL { out.append(u.absoluteString) }
        }
        return out
    }
}

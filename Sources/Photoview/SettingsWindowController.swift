import AppKit
import UniformTypeIdentifiers

/// 设置窗口（⌘,）：通用 / 鼠标与触控板 / 快捷键。改动直接写进 UserDefaults，
/// 需要看图界面跟着变的（排序、幻灯片间隔）通过通知告诉它
final class SettingsWindowController: NSWindowController {
    static let didChange = Notification.Name("FlipicSettingsDidChange")
    static let shared = SettingsWindowController()

    enum Pane: Int { case general, mouse, shortcuts }

    private let root = SettingsRoot()

    private init() {
        // 和看图窗口一个样子：深色、标题栏透明、内容铺满
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
        window.isMovableByWindowBackground = true
        window.title = L10n.t("menu.settings", "设置…").replacingOccurrences(of: "…", with: "")
        super.init(window: window)
        root.panes = [
            (L10n.t("set.tab.general", "通用"), "gearshape", GeneralSettingsPane()),
            (L10n.t("set.tab.mouse", "鼠标与触控板"), "computermouse", MouseSettingsPane()),
            (L10n.t("set.tab.shortcuts", "快捷键"), "keyboard", ShortcutSettingsPane()),
        ]
        window.contentViewController = root
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: Pane? = nil) {
        root.select(pane?.rawValue ?? root.selected)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 测试用：在快捷键页找到某一项的录制按钮
    func debugRecorder(for action: ShortcutAction) -> ShortcutRecorder? {
        func find(_ v: NSView) -> ShortcutRecorder? {
            if let r = v as? ShortcutRecorder, r.shortcut == action { return r }
            for sub in v.subviews { if let r = find(sub) { return r } }
            return nil
        }
        func table(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for sub in v.subviews { if let t = table(sub) { return t } }
            return nil
        }
        // 表格只给可见行建视图，先把目标行滚进来
        if let t = window?.contentView.flatMap(table) {
            for row in 0..<t.numberOfRows {
                if let v = t.view(atColumn: 0, row: row, makeIfNecessary: true), let r = find(v) {
                    t.scrollRowToVisible(row)
                    return t.view(atColumn: 0, row: row, makeIfNecessary: false).flatMap(find) ?? r
                }
            }
        }
        return window?.contentView.flatMap(find)
    }

    func debugStatus() -> String {
        func find(_ v: NSView) -> String? {
            if let t = v as? NSTextField, t.font?.pointSize == NSFont.smallSystemFontSize, t.lineBreakMode == .byTruncatingTail { return t.stringValue }
            for sub in v.subviews { if let r = find(sub) { return r } }
            return nil
        }
        return window?.contentView.flatMap(find) ?? ""
    }

    static func notify(_ what: String) {
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["what": what])
    }
}

protocol SettingsPane: AnyObject { func reload() }

/// 默认看图软件：按常见图片格式逐个改，相机 RAW 每家的类型都要单独设
enum DefaultViewer {
    static let types: [UTType] = [
        "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif",
        "org.webmproject.webp", "com.microsoft.bmp", "public.avif", "public.jpeg-xl",
        "public.camera-raw-image", "com.adobe.raw-image", "com.sony.arw-raw-image", "com.canon.cr2-raw-image",
        "com.canon.cr3-raw-image", "com.nikon.raw-image", "com.nikon.nrw-raw-image", "com.fuji.raw-image",
        "com.panasonic.rw2-raw-image", "com.olympus.or-raw-image",
    ].compactMap { UTType($0) }

    /// 按 bundle id 比：同一个 App 装了几份时，系统打开的可能是另一份
    static func isFlipic(_ type: UTType) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var isDefault: Bool { isFlipic(.jpeg) }

    static var currentName: String {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .jpeg) else { return "-" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func make(_ done: @escaping () -> Void) {
        let group = DispatchGroup()
        for t in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: t) { err in
                if let err { NSLog("DefaultViewer %@: %@", t.identifier, "\(err)") }
                group.leave()
            }
        }
        group.notify(queue: .main, execute: done)
    }
}

/// 顶部一排分页按钮 + 下方当前页；切页时窗口高度跟着内容走，左上角不动
private final class SettingsRoot: NSViewController {
    var panes: [(title: String, symbol: String, vc: NSViewController)] = []
    private(set) var selected = 0
    private var buttons: [SettingsTabButton] = []
    private let container = NSView()
    private var current: NSView?

    override func loadView() {
        let v = NSView()
        let bar = NSStackView()
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false
        for (i, p) in panes.enumerated() {
            let b = SettingsTabButton(title: p.title, symbol: p.symbol)
            b.target = self
            b.action = #selector(tabClicked(_:))
            b.tag = i
            buttons.append(b)
            bar.addArrangedSubview(b)
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bar)
        v.addSubview(container)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 600),
            bar.topAnchor.constraint(equalTo: v.topAnchor, constant: 34),
            bar.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            container.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            container.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }

    @objc private func tabClicked(_ sender: NSButton) { select(sender.tag) }

    func select(_ index: Int) {
        _ = view
        selected = index
        for b in buttons { b.isSelected = b.tag == index }
        let pane = panes[index].vc
        current?.removeFromSuperview()
        let pv = pane.view
        pv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: container.topAnchor),
            pv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        current = pv
        (pane as? SettingsPane)?.reload()
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true, animate: false)
    }
}

/// 分页按钮：图标在上、文字在下，选中时垫一块浅色圆角底，悬停略亮（同看图工具条）
private final class SettingsTabButton: NSButton {
    var isSelected = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    private var trackingArea: NSTrackingArea?

    convenience init(title: String, symbol: String) {
        self.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        image = img
        imagePosition = .imageAbove
        self.title = title
        font = .systemFont(ofSize: 11.5, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 54).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        restyle()
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 24
        return s
    }

    override var acceptsFirstResponder: Bool { false }

    private func restyle() {
        let color: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color, .font: font ?? .systemFont(ofSize: 11.5)])
        layer?.backgroundColor = isSelected ? NSColor(white: 1, alpha: 0.12).cgColor
            : hovering ? NSColor(white: 1, alpha: 0.06).cgColor : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// 无边框按钮：浅色圆角底，悬停略亮，同看图工具条
private final class PillButton: NSButton {
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 22
        s.height = 26
        return s
    }
}

private func pillButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = PillButton(title: title, target: target, action: action)
    b.isBordered = false
    b.wantsLayer = true
    b.layer?.cornerRadius = 7
    b.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
    b.attributedTitle = NSAttributedString(string: title, attributes: [
        .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
    return b
}

/// 圆角半透明面板，同看图界面右上角的照片信息
private func settingsPanel() -> NSVisualEffectView {
    let p = NSVisualEffectView()
    p.material = .hudWindow
    p.blendingMode = .withinWindow
    p.state = .active
    p.wantsLayer = true
    p.layer?.cornerRadius = 12
    p.layer?.masksToBounds = true
    p.layer?.borderWidth = 1
    p.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
}

// MARK: - 共用的小控件

private func label(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.alignment = .right
    return l
}

private func note(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    l.textColor = .secondaryLabelColor
    l.preferredMaxLayoutWidth = 340
    return l
}

private func grid(_ rows: [[NSView]]) -> NSGridView {
    let g = NSGridView(views: rows)
    g.translatesAutoresizingMaskIntoConstraints = false
    g.rowSpacing = 10
    g.columnSpacing = 10
    g.column(at: 0).xPlacement = .trailing
    g.rowAlignment = .firstBaseline
    return g
}

private func host(_ g: NSGridView, width: CGFloat = 600) -> NSView {
    let v = NSView()
    let p = settingsPanel()
    v.addSubview(p)
    p.addSubview(g)
    NSLayoutConstraint.activate([
        v.widthAnchor.constraint(equalToConstant: width),
        p.topAnchor.constraint(equalTo: v.topAnchor),
        p.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -24),
        p.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
        p.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
        g.topAnchor.constraint(equalTo: p.topAnchor, constant: 22),
        g.bottomAnchor.constraint(equalTo: p.bottomAnchor, constant: -22),
        g.centerXAnchor.constraint(equalTo: p.centerXAnchor),
    ])
    return v
}

/// 网格里给说明文字留的空行（第一列空着）
private func spacerRow(_ v: NSView) -> [NSView] { [NSGridCell.emptyContentView, v] }

// MARK: - 通用

private final class GeneralSettingsPane: NSViewController, SettingsPane {
    private let sortPopup = NSPopUpButton()
    private let descending = NSButton(checkboxWithTitle: L10n.t("sort.descending", "倒序"), target: nil, action: nil)
    private let fade = NSButton(checkboxWithTitle: L10n.t("menu.fadeTransition", "翻页渐变"), target: nil, action: nil)
    private let intervalPopup = NSPopUpButton()
    private let thumbPopup = NSPopUpButton()
    private let slideFade = NSButton(checkboxWithTitle: L10n.t("set.slideFade", "切换时渐变"), target: nil, action: nil)
    private let fadePopup = NSPopUpButton()
    private let escCloses = NSButton(checkboxWithTitle: L10n.t("menu.escCloses", "按 Esc 关闭窗口"), target: nil, action: nil)
    private let hdr = NSButton(checkboxWithTitle: L10n.t("set.hdrCheck", "显示 HDR 照片的高光"), target: nil, action: nil)
    private let hdrNote = note("")
    private let autoUpdate = NSButton(checkboxWithTitle: L10n.t("set.autoUpdate", "自动检查更新（每天一次）"), target: nil, action: nil)
    private let ratingBadge = NSButton(checkboxWithTitle: L10n.t("set.ratingBadge", "在照片底部显示星级"), target: nil, action: nil)
    private let editorName = NSTextField(labelWithString: "")
    private let editorIcon = NSImageView()
    private lazy var clearEditor = pillButton(L10n.t("set.clear", "清除"), self, #selector(clearEditorApp))
    private let defaultStatus = NSTextField(labelWithString: "")
    private lazy var makeDefault = pillButton(L10n.t("set.makeDefault", "设为默认看图软件"), self, #selector(makeDefaultViewer))

    override func loadView() {
        for key in SortKey.allCases { sortPopup.addItem(withTitle: key.title); sortPopup.lastItem?.tag = key.rawValue }
        for sec in ViewerViewController.slideshowIntervals {
            intervalPopup.addItem(withTitle: L10n.f("slide.seconds", "%d 秒", sec))
            intervalPopup.lastItem?.tag = sec
        }
        for d in ViewerViewController.slideshowFadeDurations {
            fadePopup.addItem(withTitle: L10n.f("slide.fadeSeconds", "%@ 秒", Self.secondsText(d)))
            fadePopup.lastItem?.representedObject = d
        }
        let thumbNames = [L10n.t("set.thumbSmall", "小"), L10n.t("set.thumbMedium", "中"), L10n.t("set.thumbLarge", "大"), L10n.t("set.thumbXL", "特大")]
        for (name, size) in zip(thumbNames, FilmstripView.thumbSizes) {
            thumbPopup.addItem(withTitle: name)
            thumbPopup.lastItem?.tag = Int(size)
        }
        thumbPopup.action = #selector(thumbSizeChanged)
        for c in [sortPopup, intervalPopup, fadePopup, thumbPopup] as [NSControl] { c.target = self }
        fadePopup.action = #selector(slideFadeChanged)
        slideFade.target = self; slideFade.action = #selector(slideFadeChanged)
        sortPopup.action = #selector(sortChanged)
        descending.target = self; descending.action = #selector(sortChanged)
        intervalPopup.action = #selector(intervalChanged)
        fade.target = self; fade.action = #selector(fadeChanged)
        escCloses.target = self; escCloses.action = #selector(escChanged)
        ratingBadge.target = self; ratingBadge.action = #selector(ratingBadgeChanged)
        autoUpdate.target = self; autoUpdate.action = #selector(autoUpdateChanged)
        hdr.target = self; hdr.action = #selector(hdrChanged)
        let checkNow = pillButton(L10n.t("set.checkNow", "现在检查"), self, #selector(checkNow))
        let updateRow = NSStackView(views: [autoUpdate, checkNow])
        updateRow.spacing = 12
        let choose = pillButton(L10n.t("set.choose", "选择…"), self, #selector(chooseEditorApp))

        editorIcon.translatesAutoresizingMaskIntoConstraints = false
        editorIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        editorIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let editorRow = NSStackView(views: [editorIcon, editorName, choose, clearEditor])
        editorRow.spacing = 6
        editorRow.setCustomSpacing(12, after: editorName)
        let sortRow = NSStackView(views: [sortPopup, descending])
        sortRow.spacing = 12

        let slideFadeRow = NSStackView(views: [slideFade, fadePopup])
        slideFadeRow.spacing = 12
        let defaultRow = NSStackView(views: [defaultStatus, makeDefault])
        defaultRow.spacing = 12
        let g = grid([
            [label(L10n.t("set.default", "默认看图：")), defaultRow],
            spacerRow(note(L10n.t("set.defaultNote", "JPEG、PNG、HEIC、TIFF、GIF、WebP 和相机 RAW 双击都用 Flipic 打开。也可以在访达里右键一张图，按住 ⌥ 键，选「始终以此打开」› Flipic。"))),
            [label(L10n.t("set.sort", "排序方式：")), sortRow],
            [label(L10n.t("set.paging", "翻页：")), fade],
            [label(L10n.t("set.rating", "评分：")), ratingBadge],
            [label(L10n.t("set.thumbs", "缩略图：")), thumbPopup],
            [label(L10n.t("set.slideInterval", "幻灯片间隔：")), intervalPopup],
            [label(L10n.t("set.slideFadeLabel", "幻灯片渐变：")), slideFadeRow],
            [label(L10n.t("set.esc", "Esc 键：")), escCloses],
            spacerRow(note(L10n.t("set.escNote", "适应窗口时按 Esc 直接关闭，放大时先恢复。配合访达的 ⌘↓ 打开，可以当快速查看用。"))),
            [label(L10n.t("set.hdr", "HDR：")), hdr],
            spacerRow(hdrNote),
            [label(L10n.t("set.editor", "后期软件：")), editorRow],
            spacerRow(note(L10n.t("set.editorNote", "「在后期软件中编辑」用它打开当前照片，同名 RAW 也在时打开 RAW。"))),
            [label(L10n.t("set.update", "更新：")), updateRow],
            spacerRow(note(L10n.t("set.updateNote", "Flipic 默认不联网。打开后每天最多查一次，只向官网请求最新版本号，不发送任何数据。"))),
        ])
        g.row(at: 1).topPadding = -4
        g.row(at: 9).topPadding = -4
        g.row(at: 11).topPadding = -4
        g.row(at: 13).topPadding = -4
        g.row(at: 15).topPadding = -4
        view = host(g)
        reload()
    }

    func reload() {
        sortPopup.selectItem(withTag: UserDefaults.standard.integer(forKey: "sortKey"))
        descending.state = UserDefaults.standard.bool(forKey: "sortReversed") ? .on : .off
        fade.state = ZoomableImageView.fadeTransition ? .on : .off
        let sec = UserDefaults.standard.integer(forKey: "slideshowInterval")
        intervalPopup.selectItem(withTag: ViewerViewController.slideshowIntervals.contains(sec) ? sec : 3)
        escCloses.state = ViewerViewController.escCloses ? .on : .off
        ratingBadge.state = ViewerViewController.showRatingBadge ? .on : .off
        thumbPopup.selectItem(withTag: Int(FilmstripView.thumbSize))
        slideFade.state = ViewerViewController.slideshowFade ? .on : .off
        autoUpdate.state = UpdateChecker.autoCheck ? .on : .off
        let hdrOK = ImageLoader.hdrSupported
        hdr.state = ImageLoader.hdrEnabled && hdrOK ? .on : .off
        hdr.isEnabled = hdrOK
        hdrNote.stringValue = hdrOK
            ? L10n.t("set.hdrNote", "iPhone 等拍的 HDR 照片，亮部会比普通白更亮，和系统「预览」看到的一样。HDR 照片占用的内存是普通照片的两倍。")
            : L10n.t("set.hdrUnsupported", "需要 macOS 14 或更新版本，以及支持 HDR 的屏幕（如 MacBook Pro 的 XDR 屏）。")
        let fd = ViewerViewController.slideshowFadeDuration
        if let item = fadePopup.itemArray.first(where: { ($0.representedObject as? Double) == fd }) { fadePopup.select(item) }
        fadePopup.isEnabled = slideFade.state == .on
        let isDefault = DefaultViewer.isDefault
        defaultStatus.stringValue = isDefault ? L10n.t("set.isDefault", "Flipic 已是默认看图软件")
            : L10n.f("set.currentDefault", "现在双击照片用「%@」打开", DefaultViewer.currentName)
        defaultStatus.textColor = isDefault ? .labelColor : .secondaryLabelColor
        makeDefault.isHidden = isDefault
        if let app = ViewerViewController.storedEditorAppURL {
            editorName.stringValue = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            editorName.textColor = .labelColor
            editorIcon.image = NSWorkspace.shared.icon(forFile: app.path)
            editorIcon.isHidden = false
            clearEditor.isHidden = false
        } else {
            editorName.stringValue = L10n.t("set.editorNone", "未设置")
            editorName.textColor = .secondaryLabelColor
            editorIcon.isHidden = true
            clearEditor.isHidden = true
        }
    }

    @objc private func makeDefaultViewer() {
        DefaultViewer.make { [weak self] in self?.reload() }
    }

    @objc private func sortChanged() {
        UserDefaults.standard.set(sortPopup.selectedTag(), forKey: "sortKey")
        UserDefaults.standard.set(descending.state == .on, forKey: "sortReversed")
        SettingsWindowController.notify("sort")
    }

    @objc private func intervalChanged() {
        UserDefaults.standard.set(intervalPopup.selectedTag(), forKey: "slideshowInterval")
        SettingsWindowController.notify("slideshow")
    }

    @objc private func fadeChanged() { ZoomableImageView.fadeTransition = fade.state == .on }
    @objc private func hdrChanged() {
        ImageLoader.hdrEnabled = hdr.state == .on
        SettingsWindowController.notify("hdr")
    }

    @objc private func autoUpdateChanged() { UpdateChecker.autoCheck = autoUpdate.state == .on }

    @objc private func checkNow() {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
    }

    @objc private func slideFadeChanged() {
        ViewerViewController.slideshowFade = slideFade.state == .on
        if let d = fadePopup.selectedItem?.representedObject as? Double { ViewerViewController.slideshowFadeDuration = d }
        fadePopup.isEnabled = slideFade.state == .on
    }

    /// 0.5、1、1.5 这样按系统语言写小数
    static func secondsText(_ v: Double) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    @objc private func thumbSizeChanged() {
        FilmstripView.thumbSize = CGFloat(thumbPopup.selectedTag())
        SettingsWindowController.notify("thumbs")
    }

    @objc private func ratingBadgeChanged() {
        ViewerViewController.showRatingBadge = ratingBadge.state == .on
        SettingsWindowController.notify("rating")
    }

    @objc private func escChanged() { ViewerViewController.escCloses = escCloses.state == .on }

    @objc private func chooseEditorApp() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("panel.chooseEditor", "选择后期软件")
        panel.prompt = L10n.t("panel.choose", "选择")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            ViewerViewController.storedEditorAppURL = url
            self?.reload()
        }
    }

    @objc private func clearEditorApp() {
        ViewerViewController.storedEditorAppURL = nil
        reload()
    }
}

// MARK: - 鼠标与触控板

private final class MouseSettingsPane: NSViewController, SettingsPane {
    private let wheelZoom = NSButton(radioButtonWithTitle: L10n.t("wheel.zoom", "缩放图片"), target: nil, action: nil)
    private let wheelNav = NSButton(radioButtonWithTitle: L10n.t("wheel.navigate", "切换上一张 / 下一张"), target: nil, action: nil)
    private let invert = NSButton(checkboxWithTitle: L10n.t("wheel.invert", "反转缩放方向"), target: nil, action: nil)
    private let invertNav = NSButton(checkboxWithTitle: L10n.t("wheel.invertNav", "反转翻页方向"), target: nil, action: nil)
    private let wheelNote = note("")

    override func loadView() {
        for b in [wheelZoom, wheelNav] { b.target = self; b.action = #selector(wheelChanged(_:)) }
        invert.target = self; invert.action = #selector(invertChanged)
        invertNav.target = self; invertNav.action = #selector(invertNavChanged)
        let radios = NSStackView(views: [wheelZoom, wheelNav])
        radios.orientation = .vertical
        radios.alignment = .leading
        radios.spacing = 6
        let g = grid([
            [label(L10n.t("set.wheel", "鼠标滚轮：")), radios],
            spacerRow(wheelNote),
            [label(L10n.t("set.navDirection", "翻页方向：")), invertNav],
            spacerRow(note(L10n.t("set.invertNavNote", "默认手指往下滑是下一张。勾上后照片跟着手指走，往下滑回到上一张、往上滑是下一张，和刷手机一样。鼠标滚轮和触控板都适用。"))),
            [label(L10n.t("set.zoomDirection", "缩放方向：")), invert],
            spacerRow(note(L10n.t("set.invertNote", "用 Mos 之类的工具改过滚轮方向后，如果滚轮缩放反了，就勾上这一项。只影响滚轮缩放，不影响触控板捏合和滚轮翻页。"))),
            [label(L10n.t("set.trackpad", "触控板：")), note(L10n.t("set.trackpadNote", "双指捏合缩放，双指轻点两下在适应窗口和 100% 之间切换，拖动平移。"))],
        ])
        g.row(at: 0).rowAlignment = .none
        g.cell(atColumnIndex: 0, rowIndex: 0).yPlacement = .top
        g.row(at: 1).topPadding = -4
        g.row(at: 3).topPadding = -4
        g.row(at: 5).topPadding = -4
        view = host(g)
        reload()
    }

    func reload() {
        let nav = ZoomableImageView.wheelNavigates
        wheelZoom.state = nav ? .off : .on
        wheelNav.state = nav ? .on : .off
        invert.state = ZoomableImageView.wheelZoomInverted ? .on : .off
        invertNav.state = ZoomableImageView.wheelNavInverted ? .on : .off
        invertNav.isEnabled = nav
        wheelNote.stringValue = nav ? L10n.t("wheel.navigate.on", "滚轮：切换图片（⌘+滚轮缩放）")
                                    : L10n.t("wheel.zoom.on", "滚轮：缩放图片（⌘+滚轮平移）")
    }

    @objc private func wheelChanged(_ sender: NSButton) {
        ZoomableImageView.wheelNavigates = sender === wheelNav
        reload()
    }

    @objc private func invertNavChanged() { ZoomableImageView.wheelNavInverted = invertNav.state == .on }

    @objc private func invertChanged() { ZoomableImageView.wheelZoomInverted = invert.state == .on }
}

// MARK: - 快捷键

/// 点一下进入录制，按下新的组合就保存；Esc 取消，单按 ⌫ 清除
final class ShortcutRecorder: NSButton {
    var shortcut: ShortcutAction!
    var onRecord: ((KeyCombo?) -> Void)?
    private(set) var isRecording = false {
        didSet { refresh() }
    }

    convenience init(action: ShortcutAction) {
        self.init(frame: .zero)
        shortcut = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        refresh()
    }

    /// 键帽样式：平时是浅色描边的小方块，录制时换成强调色
    func refresh() {
        let text: String
        let color: NSColor
        if isRecording {
            text = L10n.t("sc.recording", "按下快捷键…")
            color = .white
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if let c = Shortcuts.combo(for: shortcut) {
            text = c.display
            color = .labelColor
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(Shortcuts.isCustomized(shortcut) ? 0.45 : 0.12).cgColor
        } else {
            text = L10n.t("sc.none", "无")
            color = .tertiaryLabelColor
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
            layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        }
        let weight: NSFont.Weight = Shortcuts.isCustomized(shortcut) ? .semibold : .medium
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 12.5, weight: weight)])
    }

    @objc private func clicked() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    /// 录制时连 ⌘ 组合也自己收下，不让菜单先响应
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        guard let combo = KeyCombo(event: event) else { return }
        let mods = combo.modifiers
        if combo.keyCode == 53 && mods.isEmpty {
            isRecording = false
            return
        }
        if (combo.keyCode == 51 || combo.keyCode == 117) && mods.isEmpty {
            isRecording = false
            onRecord?(nil)
            return
        }
        isRecording = false
        onRecord?(combo)
    }
}

private final class ShortcutSettingsPane: NSViewController, SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row { case header(ShortcutAction.Group), item(ShortcutAction) }
    private let rows: [Row] = ShortcutAction.Group.allCases.flatMap { g in [Row.header(g)] + g.actions.map { Row.item($0) } }
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 32
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = note(L10n.t("sc.hint", "点右侧的按键，再按下新的组合。Esc 取消，⌫ 清除。带 ⌘ 的组合在菜单里也能看到。"))
        hint.preferredMaxLayoutWidth = 500
        let fixed = note(L10n.t("sc.fixed", "固定按键：Esc 关闭照片信息、退出预览和全屏；双击在适应窗口和 100% 之间切换；⌘O 打开，⌘W 关闭窗口，⌘= ⌘- 缩放，⌘0 适应窗口，⌘1 实际大小。"))
        fixed.preferredMaxLayoutWidth = 500
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let reset = pillButton(L10n.t("sc.reset", "全部恢复默认"), self, #selector(resetAll))
        let bottom = NSStackView(views: [status, reset])
        bottom.distribution = .fill
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let p = settingsPanel()
        p.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: p.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: p.bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: p.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: p.trailingAnchor),
        ])
        let stack = NSStackView(views: [hint, p, fixed, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 600),
            v.heightAnchor.constraint(equalToConstant: 580),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            p.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            bottom.widthAnchor.constraint(equalTo: p.widthAnchor),
        ])
        view = v
    }

    func reload() {
        status.stringValue = ""
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 28 : 40 }
        return 32
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let g):
            // 分组标题贴在行底部，上面留出和上一组的间隔
            let l = NSTextField(labelWithString: g.title)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            l.translatesAutoresizingMaskIntoConstraints = false
            let v = NSView()
            v.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
                l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
            ])
            return v
        case .item(let a):
            let title = NSTextField(labelWithString: a.title)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let rec = ShortcutRecorder(action: a)
            rec.onRecord = { [weak self] combo in self?.assign(combo, to: a) }
            let row = NSStackView(views: [title, rec])
            row.distribution = .fill
            row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 12)
            return row
        }
    }

    private func assign(_ combo: KeyCombo?, to action: ShortcutAction) {
        guard let combo else {
            Shortcuts.set(nil, for: action)
            reload()
            return
        }
        if action == .toggleApp && !combo.isMenuCombo {
            NSSound.beep()
            reload()
            status.stringValue = L10n.t("sc.needsModifier", "全局快捷键要带 ⌘、⌥ 或 ⌃，单个键会和别的软件冲突")
            return
        }
        if Shortcuts.isReserved(combo) {
            NSSound.beep()
            reload()
            status.stringValue = L10n.f("sc.reserved", "%@ 是固定按键，不能改给别的操作", combo.display)
            return
        }
        let previous = Shortcuts.owner(of: combo, excluding: action)
        if let previous { Shortcuts.set(nil, for: previous) }
        Shortcuts.set(combo, for: action)
        reload()
        if let previous {
            status.stringValue = L10n.f("sc.moved", "%1$@ 原来用于「%2$@」，那一项已清空", combo.display, previous.title)
        }
    }

    @objc private func resetAll() {
        Shortcuts.resetAll()
        reload()
    }
}

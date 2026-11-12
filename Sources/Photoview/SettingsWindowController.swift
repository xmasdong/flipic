import AppKit
import UniformTypeIdentifiers

/// 设置窗口（⌘,）：通用 / 看图 / 鼠标与触控板 / 快捷键 / Pro。改动直接写进 UserDefaults，
/// 需要看图界面跟着变的（排序、幻灯片间隔）通过通知告诉它
final class SettingsWindowController: NSWindowController {
    static let didChange = Notification.Name("FlipicSettingsDidChange")
    static let shared = SettingsWindowController()

    enum Pane { case general, viewing, mouse, shortcuts, pro }

    private let root = SettingsRoot()

    private init() {
        // 和看图窗口一个样子：标题栏透明、内容铺满；深浅色跟设置里的外观
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.gray(dark: 0.055, light: 0.95)
        window.isMovableByWindowBackground = true
        window.title = L10n.t("menu.settings", "设置…").replacingOccurrences(of: "…", with: "")
        super.init(window: window)
        root.panes = [
            (.general, L10n.t("set.tab.general", "通用"), "gearshape", GeneralSettingsPane()),
            (.viewing, L10n.t("set.tab.viewing", "看图"), "photo", ViewingSettingsPane()),
            (.mouse, L10n.t("set.tab.mouse", "鼠标与触控板"), "computermouse", MouseSettingsPane()),
            (.shortcuts, L10n.t("set.tab.shortcuts", "快捷键"), "keyboard", ShortcutSettingsPane()),
        ]
        window.contentViewController = root
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: Pane? = nil) {
        root.select(pane.flatMap { p in root.panes.firstIndex { $0.id == p } } ?? root.selected)
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

    /// 测试用：某一项右边的「清除」
    func debugClearButton(for action: ShortcutAction) -> ShortcutClearButton? {
        (debugRecorder(for: action)?.superview as? NSStackView)?.arrangedSubviews.lazy.compactMap { $0 as? ShortcutClearButton }.first
    }

    /// --settingspanes <输出文件夹>：依次打开每一页并截图，看分页后每页的内容和长度
    func debugShotAllPanes(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        showWindow(nil)
        for (i, p) in root.panes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(i) * 0.8) { [self] in
                root.select(i)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    guard let w = window, let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber),
                                                                         [.bestResolution, .boundsIgnoreFraming]),
                          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(i)-\(p.id).png") as CFURL,
                                                                     "public.png" as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(root.panes.count) * 0.8) { NSApp.terminate(nil) }
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
    var panes: [(id: SettingsWindowController.Pane, title: String, symbol: String, vc: NSViewController)] = []
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
        (pane as? SettingsPane)?.reload()
        // 页面比屏幕高（13 寸屏上的 Pro 页）就放进滚动视图，窗口最高到屏幕可用高度
        let maxHeight = ((view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 150
        // 按窗口宽度量高度，不限宽时文字排成一长行，量出来偏矮
        let widthPin = pv.widthAnchor.constraint(equalToConstant: 600)
        widthPin.isActive = true
        let fit = pv.fittingSize.height
        widthPin.isActive = false
        if fit > maxHeight {
            let doc = FlippedDocView()
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(pv)
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.documentView = doc
            container.addSubview(scroll)
            NSLayoutConstraint.activate([
                pv.topAnchor.constraint(equalTo: doc.topAnchor),
                pv.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
                pv.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                scroll.topAnchor.constraint(equalTo: container.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.heightAnchor.constraint(equalToConstant: maxHeight),
            ])
            current = scroll
        } else {
            container.addSubview(pv)
            NSLayoutConstraint.activate([
                pv.topAnchor.constraint(equalTo: container.topAnchor),
                pv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                pv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            current = pv
        }
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true, animate: false)
    }
}

/// 滚动视图的内容从顶上排起
private final class FlippedDocView: NSView {
    override var isFlipped: Bool { true }
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? Theme.overlay(0.12).cgColor : hovering ? Theme.overlay(0.06).cgColor : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
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
final class PillButton: NSButton {
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { Theme.paint(self, background: Theme.overlay(0.16)) }
    override func mouseExited(with event: NSEvent) { Theme.paint(self, background: Theme.overlay(0.1)) }
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 22
        s.height = 26
        return s
    }
}

func pillButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = PillButton(title: title, target: target, action: action)
    b.isBordered = false
    b.wantsLayer = true
    b.layer?.cornerRadius = 7
    Theme.paint(b, background: Theme.overlay(0.1))
    b.attributedTitle = NSAttributedString(string: title, attributes: [
        .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
    return b
}

/// 圆角半透明面板，同看图界面右上角的照片信息
func settingsPanel() -> NSVisualEffectView {
    let p = NSVisualEffectView()
    p.material = .hudWindow
    p.blendingMode = .withinWindow
    p.state = .active
    p.wantsLayer = true
    p.layer?.cornerRadius = 12
    p.layer?.masksToBounds = true
    p.layer?.borderWidth = 1
    Theme.paint(p, border: Theme.overlay(0.08))
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
}

// MARK: - 共用的小控件

func label(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.alignment = .right
    return l
}

func note(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    l.textColor = .secondaryLabelColor
    l.preferredMaxLayoutWidth = 340
    return l
}

/// 文字很长的复选框：超过 maxWidth 就换行。英文、德文这类长语言下不会把设置页撑得比面板还宽（撑宽了左边的标签会被裁掉）
final class WrapCheckbox: NSButton {
    var maxWidth: CGFloat = 360 { didSet { invalidateIntrinsicContentSize() } }

    convenience init(title: String, maxWidth: CGFloat = 360) {
        self.init(checkboxWithTitle: title, target: nil, action: nil)
        self.maxWidth = maxWidth
        cell?.wraps = true
        cell?.lineBreakMode = .byWordWrapping
        cell?.truncatesLastVisibleLine = false
    }

    override var intrinsicContentSize: NSSize {
        guard let cell else { return super.intrinsicContentSize }
        let big: CGFloat = 10_000
        let one = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: big, height: big))
        if one.width <= maxWidth { return one }
        let wrapped = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxWidth, height: big))
        return NSSize(width: maxWidth, height: wrapped.height)
    }
}

func grid(_ rows: [[NSView]]) -> NSGridView {
    let g = NSGridView(views: rows)
    g.translatesAutoresizingMaskIntoConstraints = false
    g.rowSpacing = 10
    g.columnSpacing = 10
    g.column(at: 0).xPlacement = .trailing
    g.rowAlignment = .firstBaseline
    return g
}

func host(_ g: NSGridView, width: CGFloat = 600) -> NSView {
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
        // 内容再宽也不能超出面板（超出会两边一起被裁）
        g.leadingAnchor.constraint(greaterThanOrEqualTo: p.leadingAnchor, constant: 16),
        g.trailingAnchor.constraint(lessThanOrEqualTo: p.trailingAnchor, constant: -16),
    ])
    return v
}

/// 网格里给说明文字留的空行（第一列空着）
func spacerRow(_ v: NSView) -> [NSView] { [NSGridCell.emptyContentView, v] }

// MARK: - 通用

private final class GeneralSettingsPane: NSViewController, SettingsPane {
    private let sortPopup = NSPopUpButton()
    private let descending = NSButton(checkboxWithTitle: L10n.t("sort.descending", "倒序"), target: nil, action: nil)
    private let newWindow = NSButton(checkboxWithTitle: L10n.t("set.newWindowCheck", "在新窗口里打开，可以同时开几个"), target: nil, action: nil)
    private let openPeek = NSButton(checkboxWithTitle: L10n.t("set.openPeekCheck", "窗口贴合照片比例（和按空格一样）"), target: nil, action: nil)
    private let peekKeep = NSButton(checkboxWithTitle: L10n.t("set.peekKeep", "贴合预览翻上一张、下一张时，窗口留在原地"), target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: L10n.t("set.autoUpdate", "自动检查更新（每天一次）"), target: nil, action: nil)
    private let keepRunning = NSButton(checkboxWithTitle: L10n.t("set.keepRunning", "关掉窗口后留在后台，再打开图片更快"), target: nil, action: nil)
    private let trashLocal = NSButton(checkboxWithTitle: L10n.t("set.trashLocalCheck", "删除外置盘上的照片时，复制到本机废纸篓"), target: nil, action: nil)
    private let themePopup = NSPopUpButton()
    private let editorName = NSTextField(labelWithString: "")
    private let editorIcon = NSImageView()
    private lazy var clearEditor = pillButton(L10n.t("set.clear", "清除"), self, #selector(clearEditorApp))
    private let defaultStatus = NSTextField(labelWithString: "")
    private lazy var makeDefault = pillButton(L10n.t("set.makeDefault", "设为默认看图软件"), self, #selector(makeDefaultViewer))

    override func loadView() {
        for key in SortKey.allCases { sortPopup.addItem(withTitle: key.title); sortPopup.lastItem?.tag = key.rawValue }
        sortPopup.target = self; sortPopup.action = #selector(sortChanged)
        descending.target = self; descending.action = #selector(sortChanged)
        keepRunning.target = self; keepRunning.action = #selector(keepRunningChanged)
        trashLocal.target = self; trashLocal.action = #selector(trashLocalChanged)
        for (m, title) in [(Theme.Mode.dark, L10n.t("set.theme.dark", "深色")), (.light, L10n.t("set.theme.light", "浅色")),
                           (.system, L10n.t("set.theme.system", "跟随系统"))] {
            themePopup.addItem(withTitle: title)
            themePopup.lastItem?.tag = m.rawValue
        }
        themePopup.target = self; themePopup.action = #selector(themeChanged)
        openPeek.target = self; openPeek.action = #selector(openPeekChanged)
        peekKeep.target = self; peekKeep.action = #selector(peekKeepChanged)
        let peekRow = NSStackView(views: [openPeek, peekKeep])
        peekRow.orientation = .vertical
        peekRow.alignment = .leading
        peekRow.spacing = 6
        newWindow.target = self; newWindow.action = #selector(newWindowChanged)
        autoUpdate.target = self; autoUpdate.action = #selector(autoUpdateChanged)
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
        let defaultRow = NSStackView(views: [defaultStatus, makeDefault])
        defaultRow.spacing = 12
        let g = grid([
            [label(L10n.t("set.default", "默认看图：")), defaultRow],
            spacerRow(note(L10n.t("set.defaultNote", "JPEG、PNG、HEIC、TIFF、GIF、WebP 和相机 RAW 双击都用 Flipic 打开。也可以在访达里右键一张图，按住 ⌥ 键，选「始终以此打开」› Flipic。"))),
            [label(L10n.t("set.openPeek", "打开照片时：")), newWindow],
            [NSGridCell.emptyContentView, peekRow],
            spacerRow(note(L10n.t("set.openPeekNote", "从访达双击照片打开时，窗口直接收成照片的比例；按空格或 Esc 回到普通窗口。打开文件夹时还是普通窗口。"))),
            [label(L10n.t("set.sort", "排序方式：")), sortRow],
            [label(L10n.t("set.editor", "后期软件：")), editorRow],
            spacerRow(note(L10n.t("set.editorNote", "「在后期软件中编辑」用它打开当前照片，同名 RAW 也在时打开 RAW。"))),
            [label(L10n.t("set.appearance", "外观：")), themePopup],
            spacerRow(note(L10n.t("set.appearanceNote", "工作台、设置等窗口跟着变；看图窗口一直是深色，方便看曝光和颜色。"))),
            [label(L10n.t("set.background", "后台：")), keepRunning],
            [label(L10n.t("set.trash", "删除：")), trashLocal],
            spacerRow(note(L10n.t("set.trashNote", "打开后，外置盘（U 盘、移动硬盘）上的照片删除时先复制到本机废纸篓再删原文件，所有删除都在一处查看和清空。代价是要多复制一份，几百张 RAW 会慢一些，也会临时占本机空间；复制不成时仍然退回该盘自己的废纸篓。关掉后和访达一样，进该盘自己的废纸篓。"))),
            [label(L10n.t("set.update", "更新：")), updateRow],
            spacerRow(note(L10n.t("set.updateNote", "Flipic 默认不联网。打开后每天最多查一次，只向官网请求最新版本号，不发送任何数据。"))),
        ])
        // 行号：0 默认看图 1 说明 2 打开照片 3 贴合 4 说明 5 排序 6 后期软件 7 说明 8 外观 9 说明 10 后台 11 删除 12 说明 13 更新 14 说明
        for r in [1, 4, 7, 9, 12, 14] { g.row(at: r).topPadding = -4 }
        view = host(g)
        reload()
    }

    @objc private func themeChanged() {
        Theme.mode = Theme.Mode(rawValue: themePopup.selectedTag()) ?? .dark
    }

    func reload() {
        sortPopup.selectItem(withTag: UserDefaults.standard.integer(forKey: "sortKey"))
        descending.state = UserDefaults.standard.bool(forKey: "sortReversed") ? .on : .off
        keepRunning.state = AppDelegate.keepRunning ? .on : .off
        trashLocal.state = Trash.copyExternalToLocal ? .on : .off
        themePopup.selectItem(withTag: Theme.mode.rawValue)
        openPeek.state = ViewerViewController.openInPeek ? .on : .off
        peekKeep.state = ViewerViewController.peekKeepsPosition ? .on : .off
        newWindow.state = AppDelegate.openInNewWindow ? .on : .off
        autoUpdate.state = UpdateChecker.autoCheck ? .on : .off
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

    @objc private func autoUpdateChanged() { UpdateChecker.autoCheck = autoUpdate.state == .on }

    @objc private func checkNow() {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
    }

    @objc private func newWindowChanged() { AppDelegate.openInNewWindow = newWindow.state == .on }
    @objc private func openPeekChanged() { ViewerViewController.openInPeek = openPeek.state == .on }
    @objc private func peekKeepChanged() { ViewerViewController.peekKeepsPosition = peekKeep.state == .on }
    @objc private func keepRunningChanged() { AppDelegate.keepRunning = keepRunning.state == .on }
    @objc private func trashLocalChanged() { Trash.copyExternalToLocal = trashLocal.state == .on }

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

// MARK: - 看图

/// 看图时的样子和手感：翻页、星级、工具条、背景、缩略图、HDR、Esc、幻灯片
private final class ViewingSettingsPane: NSViewController, SettingsPane {
    private let fade = NSButton(checkboxWithTitle: L10n.t("menu.fadeTransition", "翻页渐变"), target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: L10n.t("set.wrap", "翻过最后一张回到第一张"), target: nil, action: nil)
    private let intervalPopup = NSPopUpButton()
    private let thumbPopup = NSPopUpButton()
    private let slideFade = NSButton(checkboxWithTitle: L10n.t("set.slideFade", "切换时渐变"), target: nil, action: nil)
    private let fadePopup = NSPopUpButton()
    private let escCloses = NSButton(checkboxWithTitle: L10n.t("menu.escCloses", "按 Esc 关闭窗口"), target: nil, action: nil)
    private let hdr = NSButton(checkboxWithTitle: L10n.t("set.hdrCheck", "显示 HDR 照片的高光"), target: nil, action: nil)
    private let hdrNote = note("")
    private let ratingBadge = NSButton(checkboxWithTitle: L10n.t("set.ratingBadge", "在照片底部显示星级"), target: nil, action: nil)
    private let videosCheck = NSButton(checkboxWithTitle: L10n.t("set.videosCheck", "在文件夹里显示视频"), target: nil, action: nil)
    private let toolbarCheck = NSButton(checkboxWithTitle: L10n.t("set.toolbarCheck", "移动鼠标时显示底部工具条"), target: nil, action: nil)
    private let fileNameCheck = WrapCheckbox(title: L10n.t("set.fileNameCheck", "移动鼠标时在左上角显示文件名"))
    private let backdropPopup = NSPopUpButton()
    private let recentsCheck = NSButton(checkboxWithTitle: L10n.t("set.recentsCheck", "记录并显示最近打开的文件夹"), target: nil, action: nil)
    private let transparencyCheck = NSButton(checkboxWithTitle: L10n.t("set.transparencyGrid", "透明的地方显示棋盘格"), target: nil, action: nil)
    private let liveText = NSButton(checkboxWithTitle: L10n.t("set.liveText", "自动识别图中文字"), target: nil, action: nil)
    private let rotSavePopup = NSPopUpButton()
    private let rotRemind = WrapCheckbox(title: L10n.t("set.rotRemind", "翻到别的照片时，提醒没保存的旋转"))

    override func loadView() {
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
        for c in [intervalPopup, fadePopup, thumbPopup] as [NSControl] { c.target = self }
        fadePopup.action = #selector(slideFadeChanged)
        slideFade.target = self; slideFade.action = #selector(slideFadeChanged)
        intervalPopup.action = #selector(intervalChanged)
        fade.target = self; fade.action = #selector(fadeChanged)
        wrap.target = self; wrap.action = #selector(wrapChanged)
        escCloses.target = self; escCloses.action = #selector(escChanged)
        ratingBadge.target = self; ratingBadge.action = #selector(ratingBadgeChanged)
        toolbarCheck.target = self; toolbarCheck.action = #selector(toolbarChanged)
        videosCheck.target = self; videosCheck.action = #selector(videosChanged)
        fileNameCheck.target = self; fileNameCheck.action = #selector(fileNameChanged)
        hdr.target = self; hdr.action = #selector(hdrChanged)
        liveText.target = self; liveText.action = #selector(liveTextChanged)
        let toolbarRow = NSStackView(views: [toolbarCheck, fileNameCheck])
        toolbarRow.orientation = .vertical
        toolbarRow.alignment = .leading
        toolbarRow.spacing = 6
        for (t, title) in [(2, L10n.t("set.bg.photo", "照片色磨砂")), (1, L10n.t("set.bg.glass", "磨砂玻璃")), (0, L10n.t("set.bg.black", "纯黑"))] {
            backdropPopup.addItem(withTitle: title)
            backdropPopup.lastItem?.tag = t
        }
        backdropPopup.target = self; backdropPopup.action = #selector(backdropChanged)
        transparencyCheck.target = self; transparencyCheck.action = #selector(transparencyChanged)
        recentsCheck.target = self; recentsCheck.action = #selector(recentsChanged)
        let backdropRow = NSStackView(views: [backdropPopup, transparencyCheck])
        backdropRow.orientation = .vertical
        backdropRow.alignment = .leading
        backdropRow.spacing = 8
        let pagingRow = NSStackView(views: [fade, wrap])
        pagingRow.orientation = .vertical
        pagingRow.alignment = .leading
        pagingRow.spacing = 6
        for (t, title) in [(Straighten.Target.ask, L10n.t("set.rotSave.ask", "每次询问")),
                           (.overwrite, L10n.t("rot.overwrite", "覆盖原图")), (.copy, L10n.t("rot.copy", "另存一份"))] {
            rotSavePopup.addItem(withTitle: title)
            rotSavePopup.lastItem?.representedObject = t.rawValue
        }
        rotSavePopup.target = self; rotSavePopup.action = #selector(rotSaveChanged)
        rotRemind.target = self; rotRemind.action = #selector(rotRemindChanged)
        let rotRow = NSStackView(views: [rotSavePopup, rotRemind])
        rotRow.orientation = .vertical
        rotRow.alignment = .leading
        rotRow.spacing = 8
        let slideFadeRow = NSStackView(views: [slideFade, fadePopup])
        slideFadeRow.spacing = 12
        var rows: [[NSView]] = [
            [label(L10n.t("set.paging", "翻页：")), pagingRow],
            [label(L10n.t("set.rating", "评分：")), ratingBadge],
            [label(L10n.t("set.videos", "视频：")), videosCheck],
            spacerRow(note(L10n.t("set.videosNote", "MP4、MOV、M4V 和照片一起列出，回车播放。只播系统自带能播的格式，不额外下载解码器。"))),
            [label(L10n.t("set.toolbar", "工具条：")), toolbarRow],
            [label(L10n.t("set.backdrop", "背景：")), backdropRow],
            [label(L10n.t("set.thumbs", "缩略图：")), thumbPopup],
            [label(L10n.t("set.rotSave", "保存旋转：")), rotRow],
            spacerRow(note(L10n.t("set.rotSaveNote", "旋转（R / L）和拉直（⇧R）先只改显示，按 ⌘⌥S 或底部的「保存…」才写进文件。RAW 只能另存成 JPEG。"))),
            [label(L10n.t("set.recents", "最近打开：")), recentsCheck],
            spacerRow(note(L10n.t("set.recentsNote", "关掉后，开始页和「文件 › 最近打开」都不再列出文件夹，也不再记录。开会投屏前可以关掉。已有的记录不会删除。"))),
            [label(L10n.t("set.hdr", "HDR：")), hdr],
            spacerRow(hdrNote),
            [label(L10n.t("set.esc", "Esc 键：")), escCloses],
            spacerRow(note(L10n.t("set.escNote", "适应窗口时按 Esc 直接关闭，放大时先恢复。配合访达的 ⌘↓ 打开，可以当快速查看用。"))),
            [label(L10n.t("set.slideInterval", "幻灯片间隔：")), intervalPopup],
            [label(L10n.t("set.slideFadeLabel", "幻灯片渐变：")), slideFadeRow],
        ]
        // 系统不支持实况文本时整行不出现
        if TextRecognition.liveTextSupported {
            rows.insert(contentsOf: [
                [label(L10n.t("set.text", "文字：")), liveText],
                spacerRow(note(L10n.t("set.liveTextNote", "在一张照片上停留片刻后识别图中文字，可以直接选中、复制、查询。关掉后，「复制图中全部文字」仍可使用。"))),
            ], at: rows.firstIndex { $0.first is NSTextField && ($0.first as? NSTextField)?.stringValue == L10n.t("set.esc", "Esc 键：") } ?? rows.count)
        }
        let g = grid(rows)
        // 说明行紧贴上一行
        for (i, r) in rows.enumerated() where r.first === NSGridCell.emptyContentView && i > 0 && !(r.last is NSStackView) {
            g.row(at: i).topPadding = -4
        }
        view = host(g)
        reload()
    }

    func reload() {
        fade.state = ZoomableImageView.fadeTransition ? .on : .off
        wrap.state = ViewerViewController.wrapAround ? .on : .off
        let sec = UserDefaults.standard.integer(forKey: "slideshowInterval")
        intervalPopup.selectItem(withTag: ViewerViewController.slideshowIntervals.contains(sec) ? sec : 3)
        escCloses.state = ViewerViewController.escCloses ? .on : .off
        ratingBadge.state = ViewerViewController.showRatingBadge ? .on : .off
        toolbarCheck.state = ViewerViewController.showToolbar ? .on : .off
        videosCheck.state = Video.enabled ? .on : .off
        fileNameCheck.state = ViewerViewController.showFileName ? .on : .off
        backdropPopup.selectItem(withTag: ZoomableImageView.backdropStyle.rawValue)
        transparencyCheck.state = ZoomableImageView.showsTransparencyGrid ? .on : .off
        recentsCheck.state = Recents.enabled ? .on : .off
        thumbPopup.selectItem(withTag: Int(FilmstripView.thumbSize))
        slideFade.state = ViewerViewController.slideshowFade ? .on : .off
        let hdrOK = ImageLoader.hdrSupported
        hdr.state = ImageLoader.hdrEnabled && hdrOK ? .on : .off
        hdr.isEnabled = hdrOK
        hdrNote.stringValue = hdrOK
            ? L10n.t("set.hdrNote", "iPhone 等拍的 HDR 照片，亮部会比普通白更亮，和系统「预览」看到的一样。HDR 照片占用的内存是普通照片的两倍。")
            : L10n.t("set.hdrUnsupported", "需要 macOS 14 或更新版本，以及支持 HDR 的屏幕（如 MacBook Pro 的 XDR 屏）。")
        let fd = ViewerViewController.slideshowFadeDuration
        if let item = fadePopup.itemArray.first(where: { ($0.representedObject as? Double) == fd }) { fadePopup.select(item) }
        fadePopup.isEnabled = slideFade.state == .on
        liveText.state = TextRecognition.autoAnalyze ? .on : .off
        if let item = rotSavePopup.itemArray.first(where: { ($0.representedObject as? String) == Straighten.saveTarget.rawValue }) {
            rotSavePopup.select(item)
        }
        rotRemind.state = Straighten.remindUnsaved ? .on : .off
    }

    @objc private func rotSaveChanged() {
        Straighten.saveTarget = Straighten.Target(rawValue: rotSavePopup.selectedItem?.representedObject as? String ?? "") ?? .ask
    }

    @objc private func rotRemindChanged() { Straighten.remindUnsaved = rotRemind.state == .on }

    @objc private func liveTextChanged() {
        TextRecognition.autoAnalyze = liveText.state == .on
        SettingsWindowController.notify("liveText")
    }

    @objc private func intervalChanged() {
        UserDefaults.standard.set(intervalPopup.selectedTag(), forKey: "slideshowInterval")
        SettingsWindowController.notify("slideshow")
    }

    @objc private func fadeChanged() { ZoomableImageView.fadeTransition = fade.state == .on }
    @objc private func wrapChanged() { ViewerViewController.wrapAround = wrap.state == .on }
    @objc private func hdrChanged() {
        ImageLoader.hdrEnabled = hdr.state == .on
        SettingsWindowController.notify("hdr")
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

    @objc private func backdropChanged() {
        ZoomableImageView.backdropStyle = ZoomableImageView.BackdropStyle(rawValue: backdropPopup.selectedTag()) ?? .photo
        SettingsWindowController.notify("backdrop")
    }

    @objc private func recentsChanged() { Recents.enabled = recentsCheck.state == .on }

    @objc private func transparencyChanged() {
        ZoomableImageView.showsTransparencyGrid = transparencyCheck.state == .on
        SettingsWindowController.notify("transparencyGrid")
    }

    @objc private func fileNameChanged() {
        ViewerViewController.showFileName = fileNameCheck.state == .on
        SettingsWindowController.notify("fileName")
    }

    @objc private func videosChanged() {
        Video.enabled = videosCheck.state == .on
        SettingsWindowController.notify("videos")
    }

    @objc private func toolbarChanged() {
        ViewerViewController.showToolbar = toolbarCheck.state == .on
        SettingsWindowController.notify("toolbar")
    }

    @objc private func ratingBadgeChanged() {
        ViewerViewController.showRatingBadge = ratingBadge.state == .on
        SettingsWindowController.notify("rating")
    }

    @objc private func escChanged() { ViewerViewController.escCloses = escCloses.state == .on }
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
            [label(L10n.t("set.wheel", "滚轮 / 双指上下：")), radios],
            spacerRow(wheelNote),
            [label(L10n.t("set.navDirection", "翻页方向：")), invertNav],
            spacerRow(note(L10n.t("set.invertNavNote", "默认手指往下滑是下一张。勾上后照片跟着手指走，往下滑回到上一张、往上滑是下一张，和刷手机一样。鼠标滚轮和触控板都适用。"))),
            [label(L10n.t("set.zoomDirection", "缩放方向：")), invert],
            spacerRow(note(L10n.t("set.invertNote", "用 Mos 之类的工具改过滚轮方向后，如果缩放反了，就勾上这一项。对滚轮缩放和触控板双指上下滑缩放都有效，不影响双指捏合和翻页。"))),
            [label(L10n.t("set.trackpad", "触控板：")), note(L10n.t("set.trackpadNote", "双指左右滑翻页（往左滑是下一张），双指捏合缩放，双指轻点两下在适应窗口和 100% 之间切换，拖动平移。"))],
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

/// 点一下进入录制，按下新的键或组合就保存（单个 ⌫、⌦、字母都可以）；Esc 取消。清除用这一行右边的「清除」
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// 键帽样式：平时是浅色描边的小方块，录制时换成强调色
    func refresh() { effectiveAppearance.performAsCurrentDrawingAppearance { restyleKey() } }

    private func restyleKey() {
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
            layer?.backgroundColor = Theme.overlay(0.09).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(Shortcuts.isCustomized(shortcut) ? 0.45 : 0.12).cgColor
        } else {
            text = L10n.t("sc.none", "无")
            color = .tertiaryLabelColor
            layer?.backgroundColor = Theme.overlay(0.04).cgColor
            layer?.borderColor = Theme.overlay(0.08).cgColor
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
        isRecording = false
        onRecord?(combo)
    }

    /// 「清除」：这一项不再有快捷键
    func clear() {
        isRecording = false
        onRecord?(nil)
    }
}

/// 快捷键一行右边的「清除」：小号文字按钮，悬停时变亮
final class ShortcutClearButton: NSButton {
    private(set) weak var recorder: ShortcutRecorder?
    private var trackingArea: NSTrackingArea?

    convenience init(recorder: ShortcutRecorder) {
        self.init(frame: .zero)
        self.recorder = recorder
        isBordered = false
        target = self
        action = #selector(clicked)
        refusesFirstResponder = true
        toolTip = L10n.t("sc.clearTip", "去掉这一项的快捷键")
        setContentHuggingPriority(.required, for: .horizontal)
        style(hover: false)
    }

    private func style(hover: Bool) {
        attributedTitle = NSAttributedString(string: L10n.t("sc.clear", "清除"), attributes: [
            .foregroundColor: hover ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11.5)])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { style(hover: true) }
    override func mouseExited(with event: NSEvent) { style(hover: false) }

    @objc private func clicked() { recorder?.clear() }
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

        let hint = note(L10n.t("sc.hint", "点右侧的按键，再按下新的组合，单个键也行（比如 ⌫）。Esc 取消，点「清除」去掉快捷键。带 ⌘ 的组合在菜单里也能看到。"))
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
            // 没有快捷键时「清除」隐藏但占着位置，各行的按键框保持对齐
            let clear = ShortcutClearButton(recorder: rec)
            clear.isHidden = Shortcuts.combo(for: a) == nil
            let row = NSStackView(views: [title, rec, clear])
            row.detachesHiddenViews = false
            row.setCustomSpacing(4, after: rec)
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

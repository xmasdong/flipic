import AppKit
import ImageIO

/// 「编辑水印…」：左边是样式列表（添加、复制、删除、恢复内置），中间是这一款的各项设置，右边是当前这张照片上的实时预览。
/// 每一处改动立刻存进 WatermarkStore，没有「保存」按钮。样式同导出预设管理窗口
final class WatermarkEditor: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    static let shared = WatermarkEditor()

    /// 预览用哪张照片：默认是看图窗口里正在看的那张；没有就用示意图
    static var photoProvider: () -> URL? = {
        for w in NSApp.windows {
            if let v = w.contentViewController as? ViewerViewController, let u = v.folder.current?.url, !Video.isVideo(u) { return u }
        }
        return nil
    }

    /// 弹出编辑窗口，关掉再回来（从导出窗口里的菜单进来，导出窗口还开着）
    static func runModal(from parent: NSWindow?, selecting id: UUID?) {
        let e = shared
        e.prepare(selecting: id)
        guard let w = e.window else { return }
        if let parent { w.setFrameOrigin(NSPoint(x: parent.frame.midX - w.frame.width / 2, y: max(40, parent.frame.midY - w.frame.height / 2))) }
        NSApp.runModal(for: w)
        w.orderOut(nil)
    }

    var store: WatermarkStore { WatermarkStore.shared }
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var addButton: NSButton!
    private var dupButton: NSButton!
    private var delButton: NSButton!
    private var resetButton: NSButton!
    private let countLabel = NSTextField(labelWithString: "")
    private let formScroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    // 控件
    let nameField = NSTextField()
    let kindSeg = NSSegmentedControl(labels: [L10n.t("wm.kind.text", "文字"), L10n.t("wm.kind.image", "图片")], trackingMode: .selectOne, target: nil, action: nil)
    let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let imageNameLabel = NSTextField(labelWithString: "")
    private var chooseImageButton: NSButton!
    let layoutSeg = NSSegmentedControl(labels: [L10n.t("wm.layout.tiled", "平铺"), L10n.t("wm.layout.single", "单个")], trackingMode: .selectOne, target: nil, action: nil)
    let angleSlider = NSSlider(value: -30, minValue: -90, maxValue: 90, target: nil, action: nil)
    let spacingSlider = NSSlider(value: 1, minValue: 0, maxValue: 4, target: nil, action: nil)
    let marginSlider = NSSlider(value: 0.025, minValue: 0, maxValue: 0.1, target: nil, action: nil)
    let sizeSlider = NSSlider(value: 0.03, minValue: 0.008, maxValue: 0.15, target: nil, action: nil)
    let opacitySlider = NSSlider(value: 0.3, minValue: 0.05, maxValue: 1, target: nil, action: nil)
    private let angleValue = NSTextField(labelWithString: "")
    private let spacingValue = NSTextField(labelWithString: "")
    private let marginValue = NSTextField(labelWithString: "")
    private let sizeValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")
    let tintSeg = NSSegmentedControl(labels: [L10n.t("wm.tint.white", "白"), L10n.t("wm.tint.black", "黑"), L10n.t("wm.tint.custom", "自定")],
                                     trackingMode: .selectOne, target: nil, action: nil)
    let colorWell = NSColorWell()
    let boldCheck = NSButton(checkboxWithTitle: L10n.t("wm.bold", "粗体"), target: nil, action: nil)
    let edgePopup = NSPopUpButton()
    private var anchorButtons: [NSButton] = []
    private var form: NSGridView!
    private let previewView = WatermarkPreviewView()
    private let previewCaption = NSTextField(wrappingLabelWithString: "")

    private var loading = false
    private(set) var selectedID: UUID?
    /// 测试用：删除时不弹确认
    var skipDeleteConfirm = false

    // 预览
    private var previewBase: CGImage?
    private var previewName: String?
    private var previewIsPlaceholder = true
    private var previewGeneration = 0
    private let previewQueue = DispatchQueue(label: "app.flipic.watermark.preview", qos: .userInitiated)
    private(set) var lastPreview: CGImage?
    private var deliveredGeneration = 0
    private var previewDecoded = false
    private(set) var lastPreviewMillis: Double = 0

    // 表单各行（按类型、排布显示和隐藏）
    private enum Row: Int, CaseIterable { case name, kind, text, image, layout, angle, spacing, anchor, margin, size, opacity, tint, bold, edge }

    private init() {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: min(660, screenH - 60)),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.gray(dark: 0.055, light: 0.95)
        window.isMovableByWindowBackground = true
        window.title = L10n.t("wm.editor.title", "导出水印")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: WatermarkStore.didChange, object: nil)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { NSApp.stopModal() }
    }

    /// 打开前：读列表、选中、取预览用的照片
    func prepare(selecting id: UUID?) {
        store.reload()
        reloadList(select: id ?? selectedID ?? store.styles.first?.id)
        loadPreviewBase()
    }

    func show(selecting id: UUID? = nil) {
        prepare(selecting: id)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 界面

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: L10n.t("wm.editor.title", "导出水印"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let intro = note(L10n.t("wm.editor.intro", "给导出、转换出来的副本加水印，原照片不会被改动。在导出窗口的「水印」菜单里选用。"))
        intro.preferredMaxLayoutWidth = 900
        let head = NSStackView(views: [title, intro])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 4
        head.translatesAutoresizingMaskIntoConstraints = false

        // 左：列表
        let listPanel = settingsPanel()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("style"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 30
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(L10n.t("wm.editor.title", "导出水印"))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addButton = pillButton(L10n.t("wm.add", "添加"), self, #selector(addStyle))
        dupButton = pillButton(L10n.t("wm.duplicate", "复制"), self, #selector(duplicateStyle))
        delButton = pillButton(L10n.t("wm.delete", "删除"), self, #selector(deleteStyle))
        resetButton = pillButton(L10n.t("wm.resetBuiltIn", "恢复内置样式"), self, #selector(resetBuiltIns))
        resetButton.toolTip = L10n.t("wm.resetTip", "把「证件用途」「样片」「署名」恢复成最初的样子，被删掉的补回来")
        // 四个按钮竖着排、一样宽：德语、俄语这类长语言下也放得下
        let buttons = NSStackView(views: [addButton, dupButton, delButton, resetButton])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for b in [addButton!, dupButton!, delButton!, resetButton!] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 188).isActive = true
        }
        listPanel.addSubview(scroll)
        listPanel.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listPanel.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: listPanel.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: listPanel.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor, constant: -14),
        ])

        // 中：设置
        let formPanel = settingsPanel()
        buildForm()
        let doc = WatermarkFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(form)
        formScroll.documentView = doc
        formScroll.hasVerticalScroller = true
        formScroll.drawsBackground = false
        formScroll.borderType = .noBorder
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.stringValue = L10n.t("wm.empty", "还没有水印样式。点「添加」建一个，或「恢复内置样式」。")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        formPanel.addSubview(formScroll)
        formPanel.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
            form.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),
            form.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -20),
            doc.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            formScroll.topAnchor.constraint(equalTo: formPanel.topAnchor),
            formScroll.bottomAnchor.constraint(equalTo: formPanel.bottomAnchor),
            formScroll.leadingAnchor.constraint(equalTo: formPanel.leadingAnchor),
            formScroll.trailingAnchor.constraint(equalTo: formPanel.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: formPanel.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: formPanel.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: formPanel.widthAnchor, constant: -40),
        ])

        // 右：预览
        let previewPanel = settingsPanel()
        let caption = NSTextField(labelWithString: L10n.t("wm.preview", "预览"))
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.translatesAutoresizingMaskIntoConstraints = false
        previewCaption.font = .systemFont(ofSize: 11)
        previewCaption.textColor = .secondaryLabelColor
        previewCaption.maximumNumberOfLines = 3
        previewCaption.preferredMaxLayoutWidth = 240
        previewCaption.translatesAutoresizingMaskIntoConstraints = false
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.addSubview(caption)
        previewPanel.addSubview(previewView)
        previewPanel.addSubview(previewCaption)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 16),
            caption.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 16),
            previewView.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
            previewView.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 14),
            previewView.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -14),
            previewView.bottomAnchor.constraint(equalTo: previewCaption.topAnchor, constant: -10),
            previewCaption.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 16),
            previewCaption.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -16),
            previewCaption.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor, constant: -14),
        ])

        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        let done = pillButton(L10n.t("wm.done", "完成"), self, #selector(closeWindow))
        done.translatesAutoresizingMaskIntoConstraints = false
        done.keyEquivalent = "\r"

        for v in [head, listPanel, formPanel, previewPanel, countLabel, done] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            head.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            head.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            listPanel.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 14),
            listPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            listPanel.widthAnchor.constraint(equalToConstant: 216),
            listPanel.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -14),
            formPanel.topAnchor.constraint(equalTo: listPanel.topAnchor),
            formPanel.leadingAnchor.constraint(equalTo: listPanel.trailingAnchor, constant: 12),
            formPanel.widthAnchor.constraint(equalToConstant: 440),
            formPanel.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor),
            previewPanel.topAnchor.constraint(equalTo: listPanel.topAnchor),
            previewPanel.leadingAnchor.constraint(equalTo: formPanel.trailingAnchor, constant: 12),
            previewPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            previewPanel.bottomAnchor.constraint(equalTo: listPanel.bottomAnchor),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            countLabel.centerYAnchor.constraint(equalTo: done.centerYAnchor),
        ])
    }

    private func slider(_ s: NSSlider, value: NSTextField, width: CGFloat = 200) -> NSStackView {
        s.target = self
        s.action = #selector(controlChanged(_:))
        s.isContinuous = true
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let r = NSStackView(views: [s, value])
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    private func buildForm() {
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 250).isActive = true

        for (seg, act) in [(kindSeg, #selector(controlChanged(_:))), (layoutSeg, #selector(controlChanged(_:))), (tintSeg, #selector(controlChanged(_:)))] {
            seg.target = self
            seg.action = act
            seg.segmentStyle = .rounded
        }

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.delegate = self
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(L10n.t("wm.f.text", "文字："))
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.widthAnchor.constraint(equalToConstant: 250).isActive = true
        textScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let textNote = note(L10n.t("wm.f.textNote", "可以写多行。{date} 是导出当天的日期，{name} 是文件名（不含扩展名）。"))
        textNote.preferredMaxLayoutWidth = 250
        let textStack = NSStackView(views: [textScroll, textNote])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        imageNameLabel.lineBreakMode = .byTruncatingMiddle
        imageNameLabel.translatesAutoresizingMaskIntoConstraints = false
        imageNameLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        chooseImageButton = NSButton(title: L10n.t("wm.chooseImage", "选择图片…"), target: self, action: #selector(chooseImage))
        chooseImageButton.controlSize = .small
        chooseImageButton.bezelStyle = .rounded
        let imageNote = note(L10n.t("wm.f.imageNote", "带透明背景的 PNG 最合适。图片会复制一份存在这个 App 里，原文件挪走也不影响。"))
        imageNote.preferredMaxLayoutWidth = 250
        let imageTop = NSStackView(views: [imageNameLabel, chooseImageButton])
        imageTop.spacing = 8
        imageTop.alignment = .centerY
        let imageStack = NSStackView(views: [imageTop, imageNote])
        imageStack.orientation = .vertical
        imageStack.alignment = .leading
        imageStack.spacing = 4

        // 九个位置
        var cells: [[NSView]] = []
        let anchors = WatermarkStyle.Anchor.allCases
        for r in 0..<3 {
            var row: [NSView] = []
            for c in 0..<3 {
                let a = anchors[r * 3 + c]
                let b = NSButton(radioButtonWithTitle: "", target: self, action: #selector(anchorPicked(_:)))
                b.tag = r * 3 + c
                b.setAccessibilityLabel(Self.anchorName(a))
                b.toolTip = Self.anchorName(a)
                anchorButtons.append(b)
                row.append(b)
            }
            cells.append(row)
        }
        let anchorGrid = NSGridView(views: cells)
        anchorGrid.rowSpacing = 2
        anchorGrid.columnSpacing = 6

        colorWell.target = self
        colorWell.action = #selector(controlChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let tintRow = NSStackView(views: [tintSeg, colorWell])
        tintRow.spacing = 8
        tintRow.alignment = .centerY

        boldCheck.target = self
        boldCheck.action = #selector(controlChanged(_:))
        edgePopup.addItems(withTitles: [L10n.t("wm.edge.none", "无"), L10n.t("wm.edge.shadow", "阴影"), L10n.t("wm.edge.outline", "描边")])
        edgePopup.target = self
        edgePopup.action = #selector(controlChanged(_:))
        let edgeNote = note(L10n.t("wm.f.edgeNote", "照片上深浅不一时，加一圈阴影或描边更容易看清。"))
        edgeNote.preferredMaxLayoutWidth = 250
        let edgeStack = NSStackView(views: [edgePopup, edgeNote])
        edgeStack.orientation = .vertical
        edgeStack.alignment = .leading
        edgeStack.spacing = 4

        let g = grid([
            [label(L10n.t("wm.f.name", "名称：")), nameField],
            [label(L10n.t("wm.f.kind", "类型：")), kindSeg],
            [label(L10n.t("wm.f.text", "文字：")), textStack],
            [label(L10n.t("wm.f.image", "图片：")), imageStack],
            [label(L10n.t("wm.f.layout", "排布：")), layoutSeg],
            [label(L10n.t("wm.f.angle", "角度：")), slider(angleSlider, value: angleValue)],
            [label(L10n.t("wm.f.spacing", "疏密：")), slider(spacingSlider, value: spacingValue)],
            [label(L10n.t("wm.f.anchor", "位置：")), anchorGrid],
            [label(L10n.t("wm.f.margin", "边距：")), slider(marginSlider, value: marginValue)],
            [label(L10n.t("wm.f.size", "大小：")), slider(sizeSlider, value: sizeValue)],
            [label(L10n.t("wm.f.opacity", "不透明度：")), slider(opacitySlider, value: opacityValue)],
            [label(L10n.t("wm.f.tint", "颜色：")), tintRow],
            [label(L10n.t("wm.f.font", "字体：")), boldCheck],
            [label(L10n.t("wm.f.edge", "边缘：")), edgeStack],
        ])
        g.cell(atColumnIndex: 0, rowIndex: Row.text.rawValue).yPlacement = .top
        g.cell(atColumnIndex: 0, rowIndex: Row.image.rawValue).yPlacement = .top
        g.cell(atColumnIndex: 0, rowIndex: Row.edge.rawValue).yPlacement = .top
        g.cell(atColumnIndex: 0, rowIndex: Row.anchor.rawValue).yPlacement = .top
        form = g
    }

    static func anchorName(_ a: WatermarkStyle.Anchor) -> String {
        switch a {
        case .topLeft: return L10n.t("wm.anchor.topLeft", "左上")
        case .top: return L10n.t("wm.anchor.top", "上中")
        case .topRight: return L10n.t("wm.anchor.topRight", "右上")
        case .left: return L10n.t("wm.anchor.left", "左中")
        case .center: return L10n.t("wm.anchor.center", "正中")
        case .right: return L10n.t("wm.anchor.right", "右中")
        case .bottomLeft: return L10n.t("wm.anchor.bottomLeft", "左下")
        case .bottom: return L10n.t("wm.anchor.bottom", "下中")
        case .bottomRight: return L10n.t("wm.anchor.bottomRight", "右下")
        }
    }

    // MARK: - 列表

    @objc private func storeChanged() {
        guard !loading, window?.isVisible == true || NSApp.modalWindow === window else { return }
        reloadList(select: selectedID)
    }

    private func reloadList(select id: UUID?) {
        loading = true
        table.reloadData()
        let list = store.styles
        let row = id.flatMap { id in list.firstIndex { $0.id == id } } ?? (list.isEmpty ? nil : 0)
        if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { table.deselectAll(nil) }
        loading = false
        selectedID = row.map { list[$0].id }
        updateButtons()
        loadForm()
    }

    var selectedIndex: Int? {
        let r = table.selectedRow
        return r >= 0 && r < store.styles.count ? r : nil
    }

    private func updateButtons() {
        let n = store.styles.count
        addButton.isEnabled = n < WatermarkStore.maxCount
        dupButton.isEnabled = selectedIndex != nil && n < WatermarkStore.maxCount
        delButton.isEnabled = selectedIndex != nil
        countLabel.stringValue = L10n.f("preset.count", "%1$d / %2$d", n, WatermarkStore.maxCount)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.styles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.styles.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let name = NSTextField(labelWithString: store.styles[row].displayName)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(name)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading else { return }
        selectedID = selectedIndex.map { store.styles[$0].id }
        updateButtons()
        loadForm()
    }

    @objc func addStyle() {
        guard let s = store.addNew() else { return }
        reloadList(select: s.id)
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    @objc func duplicateStyle() {
        guard let i = selectedIndex, let c = store.duplicate(id: store.styles[i].id) else { return }
        reloadList(select: c.id)
    }

    @objc func deleteStyle() {
        guard let i = selectedIndex else { return }
        let s = store.styles[i]
        let remove = { [weak self] in
            guard let self else { return }
            self.store.remove(id: s.id)
            let list = self.store.styles
            self.reloadList(select: list.isEmpty ? nil : list[min(i, list.count - 1)].id)
        }
        if skipDeleteConfirm { remove(); return }
        let alert = NSAlert()
        alert.messageText = L10n.f("wm.deleteConfirm", "删除水印样式「%@」？", s.displayName)
        alert.informativeText = L10n.t("wm.deleteInfo", "只删除这个样式，不影响已经导出的照片，已存进导出预设的也照常用。")
        alert.addButton(withTitle: L10n.t("wm.delete", "删除"))
        alert.addButton(withTitle: L10n.t("alert.cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remove()
    }

    @objc func resetBuiltIns() {
        store.resetBuiltIns()
        reloadList(select: selectedID ?? store.styles.first?.id)
    }

    @objc private func closeWindow() {
        window?.close()
    }

    // MARK: - 编辑区

    private var current: WatermarkStyle? { selectedIndex.map { store.styles[$0] } }

    private func loadForm() {
        guard let s = current else {
            formScroll.isHidden = true
            emptyLabel.isHidden = false
            refreshPreview()
            return
        }
        formScroll.isHidden = false
        emptyLabel.isHidden = true
        loading = true
        defer { loading = false; refreshPreview() }
        nameField.stringValue = s.displayName
        nameField.placeholderString = L10n.t("wm.unnamed", "未命名")
        kindSeg.selectedSegment = s.kind == .text ? 0 : 1
        textView.string = s.resolvedText
        imageNameLabel.stringValue = s.imageFile == nil ? L10n.t("wm.noImage", "还没有选图片") : (store.logoImage(s.imageFile) == nil ? L10n.t("wm.imageMissing", "图片找不到了，请重新选") : L10n.t("wm.imageChosen", "已选图片"))
        imageNameLabel.textColor = s.imageFile == nil || store.logoImage(s.imageFile) == nil ? .tertiaryLabelColor : .labelColor
        layoutSeg.selectedSegment = s.layout == .tiled ? 0 : 1
        angleSlider.doubleValue = s.angle
        spacingSlider.doubleValue = s.spacing
        marginSlider.doubleValue = s.margin
        if s.kind == .text { sizeSlider.minValue = 0.008; sizeSlider.maxValue = 0.15 } else { sizeSlider.minValue = 0.03; sizeSlider.maxValue = 0.7 }
        sizeSlider.doubleValue = s.size
        opacitySlider.doubleValue = s.opacity
        tintSeg.selectedSegment = s.tint == .white ? 0 : s.tint == .black ? 1 : 2
        let c = s.customColor.count == 3 ? s.customColor : [0.5, 0.5, 0.5]
        colorWell.color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        boldCheck.state = s.bold ? .on : .off
        edgePopup.selectItem(at: s.edge == .none ? 0 : s.edge == .shadow ? 1 : 2)
        for (i, a) in WatermarkStyle.Anchor.allCases.enumerated() { anchorButtons[i].state = a == s.anchor ? .on : .off }
        syncRows(s)
    }

    /// 类型、排布决定哪些行看得到；数值旁边的字跟着变
    private func syncRows(_ s: WatermarkStyle) {
        let text = s.kind == .text, tiled = s.layout == .tiled
        func show(_ r: Row, _ on: Bool) { form.row(at: r.rawValue).isHidden = !on }
        show(.text, text); show(.image, !text)
        show(.angle, tiled); show(.spacing, tiled)
        show(.anchor, !tiled); show(.margin, !tiled)
        show(.tint, text); show(.bold, text); show(.edge, text)
        colorWell.isHidden = s.tint != .custom
        angleValue.stringValue = String(format: "%d°", Int(s.angle.rounded()))
        spacingValue.stringValue = String(format: "%.1f", s.spacing)
        marginValue.stringValue = String(format: "%.1f%%", s.margin * 100)
        sizeValue.stringValue = String(format: "%.1f%%", s.size * 100)
        opacityValue.stringValue = String(format: "%d%%", Int((s.opacity * 100).rounded()))
        sizeSlider.toolTip = text ? L10n.t("wm.f.sizeTipText", "字的大小，占照片长边的比例") : L10n.t("wm.f.sizeTipImage", "图片的宽度，占照片长边的比例")
    }

    /// 控件里的值回写到样式
    private func commit() {
        guard !loading, var s = current else { return }
        let oldKind = s.kind
        let typedName = nameField.stringValue
        // 内置样式的名字、文字没动过就仍然跟着语言走
        if typedName != s.displayName { s.name = typedName }
        s.kind = kindSeg.selectedSegment == 1 ? .image : .text
        let typedText = textView.string
        if typedText != s.resolvedText { s.text = typedText }
        s.layout = layoutSeg.selectedSegment == 1 ? .single : .tiled
        s.angle = angleSlider.doubleValue
        s.spacing = spacingSlider.doubleValue
        s.margin = marginSlider.doubleValue
        s.size = sizeSlider.doubleValue
        s.opacity = opacitySlider.doubleValue
        s.tint = tintSeg.selectedSegment == 0 ? .white : tintSeg.selectedSegment == 1 ? .black : .custom
        if let rgb = colorWell.color.usingColorSpace(.sRGB) { s.customColor = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)] }
        s.bold = boldCheck.state == .on
        s.edge = edgePopup.indexOfSelectedItem == 1 ? .shadow : edgePopup.indexOfSelectedItem == 2 ? .outline : .none
        if let i = anchorButtons.firstIndex(where: { $0.state == .on }) { s.anchor = WatermarkStyle.Anchor.allCases[i] }
        if s.kind != oldKind {
            // 文字和图片的合适大小差很多：换类型时给一个顺手的默认大小
            s.size = s.kind == .image ? 0.14 : 0.03
        }
        loading = true
        store.update(s)
        loading = false
        if s.kind != oldKind { loadForm() } else {
            syncRows(s)
            if let i = selectedIndex { table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0)) }
            refreshPreview()
        }
    }

    func controlTextDidChange(_ obj: Notification) { commit() }
    func textDidChange(_ notification: Notification) { commit() }

    @objc private func controlChanged(_ sender: Any?) { commit() }

    @objc private func anchorPicked(_ sender: NSButton) {
        for b in anchorButtons { b.state = b === sender ? .on : .off }
        commit()
    }

    @objc private func chooseImage() {
        guard var s = current else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP, .image]
        panel.message = L10n.t("wm.chooseImage.message", "选一张图片做水印（带透明背景的 PNG 最合适）")
        panel.prompt = L10n.t("wm.chooseImage.prompt", "选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setImage(url, for: &s)
    }

    /// 选定图片水印：复制进 Watermarks 文件夹
    func setImage(_ url: URL, for s: inout WatermarkStyle) {
        guard let file = store.importLogo(from: url) else {
            let a = NSAlert()
            a.messageText = L10n.t("wm.imageFail", "这张图片打不开")
            a.addButton(withTitle: L10n.t("bc.ok", "好"))
            a.runModal()
            return
        }
        s.imageFile = file
        loading = true
        store.update(s)
        loading = false
        loadForm()
    }

    func debugSetImage(_ url: URL) { if var s = current { setImage(url, for: &s) } }

    // MARK: - 预览

    private func loadPreviewBase() {
        previewBase = nil
        previewDecoded = false
        previewName = nil
        previewIsPlaceholder = true
        guard let url = Self.photoProvider() else {
            previewBase = Self.placeholderImage()
            previewCaption.stringValue = L10n.t("wm.preview.placeholder", "现在没有打开照片，这里用示意图预览。")
            refreshPreview()
            return
        }
        previewName = url.deletingPathExtension().lastPathComponent
        previewIsPlaceholder = false
        previewCaption.stringValue = L10n.f("wm.preview.photo", "预览用的是现在这张照片：%@", url.lastPathComponent)
        previewBase = Self.placeholderImage()
        refreshPreview()
        previewQueue.async { [weak self] in
            let img = ImageLoader.decodedFull(url: url, maxPixel: 1100)
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewDecoded = true
                if let img { self.previewBase = img } else {
                    self.previewIsPlaceholder = true
                    self.previewCaption.stringValue = L10n.t("wm.preview.placeholder", "现在没有打开照片，这里用示意图预览。")
                }
                self.refreshPreview()
            }
        }
    }

    /// 没有照片时的预览底图：中性灰底，上面是一张证件大小的卡片和几行深浅条纹，没有图案和渐变
    static func placeholderImage() -> CGImage {
        let w = 1000, h = 700
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let card = CGRect(x: 90, y: 110, width: 820, height: 480)
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0.62, alpha: 1))
        ctx.fill(CGRect(x: 130, y: 250, width: 200, height: 270))
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        for (i, wd) in [380.0, 300.0, 340.0, 220.0].enumerated() {
            ctx.fill(CGRect(x: 380, y: 470 - CGFloat(i) * 60, width: wd, height: 22))
        }
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        ctx.fill(CGRect(x: 130, y: 160, width: 700, height: 28))
        return ctx.makeImage()!
    }

    func refreshPreview() {
        guard let base = previewBase, let s = current else {
            previewView.image = previewBase.map { NSImage(cgImage: $0, size: .zero) }
            return
        }
        previewGeneration += 1
        let gen = previewGeneration
        let name = previewName ?? "IMG_0421"
        let logo = s.kind == .image ? store.logoImage(s.imageFile) : nil
        previewQueue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let out = WatermarkRenderer.render(base, style: s.frozen(), text: nil, fileName: name, logo: logo)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == gen else { return }
                self.lastPreview = out
                self.deliveredGeneration = gen
                self.lastPreviewMillis = ms
                self.previewView.image = NSImage(cgImage: out ?? base, size: .zero)
            }
        }
    }

    /// 自测用：等排队的预览画完
    func debugFlushPreview() {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            if lastPreview != nil, deliveredGeneration == previewGeneration { break }
        }
    }

    var debugPreviewIsPlaceholder: Bool { previewIsPlaceholder }
    var debugPreviewDecoded: Bool { previewDecoded }
    var debugPreviewCaption: String { previewCaption.stringValue }
    func debugSelect(_ row: Int) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    func debugRowName(_ row: Int) -> String {
        guard let v = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { return "" }
        return v.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? ""
    }
    func debugCommit() { commit() }
    func debugLoad() { loadForm() }
    var debugForm: NSView { form }
    var debugAnchorButtons: [NSButton] { anchorButtons }
    var debugButtons: (add: NSButton, dup: NSButton, del: NSButton, reset: NSButton) { (addButton, dupButton, delButton, resetButton) }
    var debugCount: String { countLabel.stringValue }
    var debugPreviewView: NSView { previewView }
    func debugType(_ s: String) { textView.string = s; commit() }
    func debugTypeName(_ s: String) { nameField.stringValue = s; commit() }
}

/// 预览：图按比例缩放放在中间，没有图案和渐变，边上一条细线
final class WatermarkPreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let bg = Theme.gray(dark: 0.1, light: 0.9)
        bg.setFill()
        bounds.fill()
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s = min(bounds.width / iw, bounds.height / ih)
        let r = NSRect(x: (bounds.width - iw * s) / 2, y: (bounds.height - ih * s) / 2, width: iw * s, height: ih * s).integral
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        NSGraphicsContext.current?.cgContext.draw(cg, in: r)
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }

    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

private final class WatermarkFlippedView: NSView {
    override var isFlipped: Bool { true }
}

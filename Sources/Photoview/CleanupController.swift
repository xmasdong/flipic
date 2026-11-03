import AppKit

/// 清理模式：盖在看图界面上的整窗视图。左侧四个分类，右侧网格，底部移到废纸篓。
/// 只给建议，删除永远要用户按下按钮；文件进废纸篓，⌘Z 可撤销。
final class CleanupController: NSViewController {
    private let folderURL: URL
    private var units: [CleanupUnit]
    private let scanner: CleanupScanner
    private let onExit: (_ changed: Bool) -> Void

    private var result = CleanupResult()
    private var category: CleanupCategory = .similar
    /// 用户手动改过的勾选，覆盖默认建议
    private var userChecked = Set<URL>()
    private var userUnchecked = Set<URL>()
    private var undoStack: [[(original: URL, trashed: URL)]] = []
    private var changed = false
    private var lastBuild = Date.distantPast

    private let sidebar = NSVisualEffectView()
    private var rows: [CleanupCategory: CategoryRow] = [:]
    private let progressLabel = NSTextField(labelWithString: "")
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerDetail = NSTextField(labelWithString: "")
    private let selectAllButton = NSButton()
    private let selectNoneButton = NSButton()
    private let scroll = NSScrollView()
    let grid = CleanupGridView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let trashButton = NSButton()
    private let preview = CleanupPreviewView()

    private let thumbCache: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.countLimit = 600
        return c
    }()
    private let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private static let itemID = NSUserInterfaceItemIdentifier("cleanupItem")
    private static let headerID = NSUserInterfaceItemIdentifier("cleanupHeader")

    init(folderURL: URL, items: [ImageItem], onExit: @escaping (_ changed: Bool) -> Void) {
        self.folderURL = folderURL
        units = CleanupUnit.make(from: items)
        scanner = CleanupScanner(folder: folderURL, units: units)
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isScanFinished: Bool { scanner.finished }

    // MARK: - 布局

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        view = root

        // 左侧栏
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let title = NSTextField(labelWithString: L10n.t("cleanup.title", "清理模式"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let titleRow = NSStackView(views: [title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6

        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        for c in CleanupCategory.allCases {
            let row = CategoryRow(title: c.title)
            row.onClick = { [weak self] in self?.select(category: c) }
            rows[c] = row
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byWordWrapping
        progressLabel.maximumNumberOfLines = 3
        progressLabel.preferredMaxLayoutWidth = 176

        for v in [titleRow, rowStack, progressLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }

        // 右侧标题行
        headerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        headerDetail.font = .systemFont(ofSize: 12)
        headerDetail.textColor = .secondaryLabelColor
        for (b, t, a) in [(selectAllButton, L10n.t("cleanup.selectAll", "全选"), #selector(checkAll(_:))),
                          (selectNoneButton, L10n.t("cleanup.selectNone", "全不选"), #selector(checkNone(_:)))] {
            b.title = t
            b.bezelStyle = .inline
            b.isBordered = false
            b.contentTintColor = .controlAccentColor
            b.font = .systemFont(ofSize: 12)
            b.target = self
            b.action = a
            b.refusesFirstResponder = true
        }
        let done = NSButton(title: L10n.t("cleanup.done", "完成"), target: self, action: #selector(finish(_:)))
        done.bezelStyle = .rounded
        done.refusesFirstResponder = true

        // 网格
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 164, height: 164)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 4, left: 20, bottom: 18, right: 20)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.backgroundColors = [.clear]
        grid.dataSource = self
        grid.delegate = self
        grid.register(CleanupItem.self, forItemWithIdentifier: Self.itemID)
        grid.register(CleanupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                      withIdentifier: Self.headerID)
        grid.onToggle = { [weak self] ip in self?.toggle(at: ip) }
        grid.onPreview = { [weak self] in self?.togglePreview() }
        grid.onEscape = { [weak self] in
            guard let self else { return }
            if !self.preview.isHidden { self.togglePreview() } else { self.finish(nil) }
        }
        grid.onUndo = { [weak self] in self?.undo() }
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        // 底部栏
        let bottomBar = NSView()
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor
        let line = NSBox()
        line.boxType = .separator
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: L10n.t("cleanup.hint", "点击 勾选 / 取消 · 空格 放大检查"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        trashButton.title = L10n.t("cleanup.trash", "移到废纸篓")
        trashButton.bezelStyle = .rounded
        trashButton.hasDestructiveAction = true
        trashButton.target = self
        trashButton.action = #selector(trashChecked(_:))
        trashButton.refusesFirstResponder = true
        for v in [line, statusLabel, hint, trashButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(v)
        }

        preview.isHidden = true

        for v in [headerTitle, headerDetail, selectAllButton, selectNoneButton, done, scroll, emptyLabel, bottomBar, preview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208),

            // 顶部留出标题栏与红绿灯的位置
            titleRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            titleRow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
            rowStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            rowStack.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 16),
            progressLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            progressLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            progressLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),

            headerTitle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20),
            headerTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            headerDetail.leadingAnchor.constraint(equalTo: headerTitle.trailingAnchor, constant: 10),
            headerDetail.firstBaselineAnchor.constraint(equalTo: headerTitle.firstBaselineAnchor),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            done.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            selectNoneButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            selectNoneButton.centerYAnchor.constraint(equalTo: headerTitle.centerYAnchor),
            selectAllButton.trailingAnchor.constraint(equalTo: selectNoneButton.leadingAnchor, constant: -14),
            selectAllButton.centerYAnchor.constraint(equalTo: headerTitle.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -20),

            bottomBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 52),
            line.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            trashButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.topAnchor.constraint(equalTo: root.topAnchor),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        scanner.onProgress = { [weak self] in self?.scanProgressed() }
        select(category: .similar)
        scanner.start()
    }

    // MARK: - 扫描进度与结果

    private func scanProgressed() {
        let total = units.count
        if scanner.finished {
            progressLabel.stringValue = L10n.f("cleanup.scanned", "已检查 %d 张，用时 %d 秒", total, Int(scanner.elapsed.rounded()))
        } else {
            progressLabel.stringValue = L10n.f("cleanup.scanning", "正在检查 %d / %d", scanner.done, total)
        }
        // 扫描中每秒最多重排一次，避免网格不停跳动
        if scanner.finished || Date().timeIntervalSince(lastBuild) > 1.0 {
            rebuild()
        }
    }

    private func rebuild() {
        lastBuild = Date()
        let focused = focusedUnit?.primary
        result = CleanupResult.build(units: units, scanner: scanner)
        for c in CleanupCategory.allCases { rows[c]?.count = result.count(c) }
        reloadGrid(keeping: focused)
    }

    private var sections: [CleanupGroup] { result.groups[category] ?? [] }

    private func isChecked(_ url: URL) -> Bool {
        (result.suggested.contains(url) || userChecked.contains(url)) && !userUnchecked.contains(url)
    }

    private func setChecked(_ url: URL, _ on: Bool) {
        if on { userChecked.insert(url); userUnchecked.remove(url) } else { userUnchecked.insert(url); userChecked.remove(url) }
    }

    private var checkedUnits: [CleanupUnit] { units.filter { isChecked($0.primary) } }

    private func select(category c: CleanupCategory) {
        category = c
        for (k, row) in rows { row.isActive = k == c }
        reloadGrid(keeping: nil)
        grid.scroll(.zero)
    }

    private func reloadGrid(keeping url: URL?) {
        let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout
        layout?.headerReferenceSize = (category == .similar || category == .duplicate) ? NSSize(width: 100, height: 30) : .zero
        grid.reloadData()
        headerTitle.stringValue = category.title
        let n = result.count(category)
        switch category {
        case .similar: headerDetail.stringValue = L10n.f("cleanup.detail.groups", "%d 组 · %d 张", sections.count, n)
        case .duplicate: headerDetail.stringValue = L10n.f("cleanup.detail.copies", "%d 份内容相同 · %d 张", sections.count, n)
        default: headerDetail.stringValue = L10n.f("cleanup.detail.count", "%d 张", n)
        }
        let empty = n == 0
        emptyLabel.isHidden = !empty
        emptyLabel.stringValue = scanner.finished ? category.emptyText : L10n.t("cleanup.waiting", "正在检查…")
        selectAllButton.isHidden = empty
        selectNoneButton.isHidden = empty
        if let url, let ip = indexPath(of: url) {
            grid.selectionIndexPaths = [ip]
        }
        updateStatus()
    }

    private func indexPath(of url: URL) -> IndexPath? {
        for (s, g) in sections.enumerated() {
            if let i = g.units.firstIndex(where: { $0.primary == url }) { return IndexPath(item: i, section: s) }
        }
        return nil
    }

    private func unit(at ip: IndexPath) -> CleanupUnit? {
        guard sections.indices.contains(ip.section), sections[ip.section].units.indices.contains(ip.item) else { return nil }
        return sections[ip.section].units[ip.item]
    }

    private var focusedUnit: CleanupUnit? { grid.selectionIndexPaths.first.flatMap { unit(at: $0) } }

    private func updateStatus() {
        let sel = checkedUnits
        let bytes = sel.reduce(0) { $0 + $1.fileSize }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        statusLabel.stringValue = sel.isEmpty ? L10n.t("cleanup.noneSelected", "没有勾选照片")
            : L10n.f("cleanup.selected", "已选 %d 张 · %@", sel.count, size)
        trashButton.title = sel.isEmpty ? L10n.t("cleanup.trash", "移到废纸篓")
            : L10n.f("cleanup.trashN", "移到废纸篓 (%d)", sel.count)
        trashButton.isEnabled = !sel.isEmpty
    }

    // MARK: - 勾选

    private func toggle(at ip: IndexPath) {
        guard let u = unit(at: ip) else { return }
        setChecked(u.primary, !isChecked(u.primary))
        refreshVisibleItems()
        updateStatus()
        if !preview.isHidden { updatePreview() }
    }

    private func refreshVisibleItems() {
        for ip in grid.indexPathsForVisibleItems() {
            if let item = grid.item(at: ip) as? CleanupItem, let u = unit(at: ip) {
                item.isChecked = isChecked(u.primary)
            }
        }
    }

    @objc private func checkAll(_ sender: Any?) {
        for g in sections { for u in g.units { setChecked(u.primary, true) } }
        refreshVisibleItems(); updateStatus()
    }

    @objc private func checkNone(_ sender: Any?) {
        for g in sections { for u in g.units { setChecked(u.primary, false) } }
        refreshVisibleItems(); updateStatus()
    }

    // MARK: - 放大检查

    private func togglePreview() {
        if preview.isHidden {
            guard focusedUnit != nil else { return }
            preview.isHidden = false
            updatePreview()
        } else {
            preview.isHidden = true
        }
    }

    private func updatePreview() {
        guard let u = focusedUnit, let m = Optional(scanner.metrics[u.primary]) else { return }
        var reasons: [String] = []
        if result.keepers.contains(u.primary) { reasons.append(L10n.t("cleanup.keep", "推荐保留")) }
        if result.closedFaces[u.primary] != nil { reasons.append(CleanupCategory.closedEyes.title) }
        if let m, CleanupResult.isBlurry(m) { reasons.append(CleanupCategory.blurry.title) }
        let state = isChecked(u.primary) ? L10n.t("cleanup.state.checked", "已勾选，回车取消")
            : L10n.t("cleanup.state.unchecked", "未勾选，回车勾选")
        preview.caption = ([u.primary.lastPathComponent] + reasons + [state]).joined(separator: "  ·  ")
        preview.faces = category == .closedEyes ? (result.closedFaces[u.primary] ?? []) : []
        let url = u.primary
        if let hit = ImageLoader.shared.cachedPreview(for: url, maxPixel: 2048) {
            preview.image = hit
            return
        }
        preview.image = thumbCache.object(forKey: url as NSURL)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let img = ImageLoader.shared.preview(for: url, maxPixel: 2048)
            DispatchQueue.main.async {
                guard let self, self.focusedUnit?.primary == url else { return }
                self.preview.image = img
            }
        }
    }

    // MARK: - 删除与撤销

    /// 菜单「移到废纸篓」（⌘⌫）在清理模式里作用于全部勾选项
    @objc func trashCurrent(_ sender: Any?) { trashChecked(sender) }

    @objc private func trashChecked(_ sender: Any?) {
        let sel = checkedUnits
        guard !sel.isEmpty else { return }
        // 实况照片的同名 MOV 也一起删，不留下拆开的一半
        var urls = sel.flatMap(\.allURLs)
        for u in urls { for f in ViewerViewController.companions(of: u) where !urls.contains(f) { urls.append(f) } }
        NSWorkspace.shared.recycle(urls) { [weak self] moved, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let record = moved.map { (original: $0.key, trashed: $0.value) }
                let gone = Set(moved.keys)
                self.units.removeAll { $0.allURLs.contains { gone.contains($0) } }
                for u in record { ImageLoader.shared.evict(url: u.original) }
                self.undoStack.append(record)
                self.changed = true
                self.preview.isHidden = true
                self.rebuild()
                let photos = sel.filter { gone.contains($0.primary) }.count
                self.statusLabel.stringValue = L10n.f("cleanup.trashed", "已移到废纸篓 %d 张 · ⌘Z 撤销", photos)
            }
        }
    }

    private func undo() {
        guard let record = undoStack.popLast() else { return }
        var restored = Set<URL>()
        for r in record where (try? FileManager.default.moveItem(at: r.trashed, to: r.original)) != nil {
            restored.insert(r.original)
        }
        // 按原顺序把恢复的照片放回列表
        let back = scanner.units.filter { u in u.allURLs.contains { restored.contains($0) } }
        let present = Set(units.map(\.primary))
        let order = Dictionary(uniqueKeysWithValues: scanner.units.enumerated().map { ($1.primary, $0) })
        units = (units + back.filter { !present.contains($0.primary) }).sorted { order[$0.primary]! < order[$1.primary]! }
        rebuild()
        statusLabel.stringValue = L10n.f("cleanup.restored", "已恢复 %d 个文件", restored.count)
    }

    @objc func finish(_ sender: Any?) {
        scanner.cancel()
        thumbQueue.cancelAllOperations()
        onExit(changed)
    }

    // MARK: - 自测用

    func debugSelect(_ c: CleanupCategory) { select(category: c) }
    func debugFocusFirst() {
        if !sections.isEmpty { grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)] }
    }
    func debugTogglePreview() { togglePreview() }
    func debugTrash() { trashChecked(nil) }
    func debugUndo() { undo() }
    var debugSummary: String {
        let cats = CleanupCategory.allCases.map { "\($0)=\(result.count($0))" }.joined(separator: " ")
        return "units=\(units.count) checked=\(checkedUnits.count) \(cats) undo=\(undoStack.count)"
    }
}

// MARK: - 网格数据源

extension CleanupController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].units.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! CleanupItem
        guard let u = unit(at: indexPath) else { return item }
        let url = u.primary
        item.url = url
        item.isChecked = isChecked(url)
        item.isKeeper = sections[indexPath.section].keeper == url && result.keepers.contains(url)
        item.faces = category == .closedEyes ? (result.closedFaces[url] ?? []) : []
        item.badge = u.companions.isEmpty ? nil : u.companions.map { $0.pathExtension.uppercased() }.joined(separator: "+")
        if let t = thumbCache.object(forKey: url as NSURL) {
            item.thumbnail = t
        } else {
            item.thumbnail = nil
            thumbQueue.addOperation { [weak self] in
                guard let t = ImageLoader.renderThumbnail(url: url, maxPixel: 360, allowEmbedded: CleanupUnit.isRaw(url)) else { return }
                DispatchQueue.main.async {
                    self?.thumbCache.setObject(t, forKey: url as NSURL)
                    if item.url == url { item.thumbnail = t }
                }
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let h = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.headerID, for: indexPath) as! CleanupHeader
        let g = sections[indexPath.section]
        if category == .duplicate {
            h.text = L10n.f("cleanup.header.copies", "%d 份相同", g.units.count)
            // 每份都勾上时说明原因，免得以为会把这张照片删光
            if g.units.allSatisfy({ isChecked($0.primary) }) {
                h.text += "  ·  " + L10n.t("cleanup.header.betterInBurst", "同一组连拍里有更好的一张")
            }
        } else if let d = g.date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .medium
            h.text = L10n.f("cleanup.header.burst", "%d 张 · %@", g.units.count, f.string(from: d))
        } else {
            h.text = ""
        }
        return h
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !preview.isHidden { updatePreview() }
    }
}

// MARK: - 左侧分类行

private final class CategoryRow: NSView {
    var onClick: (() -> Void)?
    private let titleLabel: NSTextField
    private let countLabel = NSTextField(labelWithString: "")

    var count: Int = 0 { didSet { countLabel.stringValue = "\(count)" } }
    var isActive = false {
        didSet {
            layer?.backgroundColor = isActive ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
            titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        }
    }

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.stringValue = "0"
        for v in [titleLabel, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - 网格：点击即勾选，空格放大，方向键移动

final class CleanupGridView: NSCollectionView {
    var onToggle: ((IndexPath) -> Void)?
    var onPreview: (() -> Void)?
    var onEscape: (() -> Void)?
    var onUndo: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let ip = indexPathForItem(at: p) else { return }
        selectionIndexPaths = [ip]
        delegate?.collectionView?(self, didSelectItemsAt: [ip])
        if event.clickCount == 2 {
            onPreview?()
        } else {
            onToggle?(ip)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onPreview?()                       // 空格
        case 53: onEscape?()                        // Esc
        case 36, 76:                                // 回车
            if let ip = selectionIndexPaths.first { onToggle?(ip) }
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "x", let ip = selectionIndexPaths.first {
                onToggle?(ip)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 主菜单没有「编辑」菜单，⌘Z 在这里接
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "z" {
            onUndo?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 网格格子

final class CleanupItem: NSCollectionViewItem {
    var url: URL?
    private let imageLayer = CALayer()
    private let faceLayer = CAShapeLayer()
    private let check = NSImageView()
    private let keepLabel = NSTextField(labelWithString: L10n.t("cleanup.keep", "推荐保留"))
    private let badgeLabel = NSTextField(labelWithString: "")

    var thumbnail: CGImage? { didSet { imageLayer.contents = thumbnail; view.needsLayout = true } }
    var isChecked = false { didSet { updateCheck() } }
    var isKeeper = false { didSet { keepLabel.isHidden = !isKeeper } }
    var faces: [CGRect] = [] { didSet { view.needsLayout = true } }
    var badge: String? { didSet { badgeLabel.stringValue = badge ?? ""; badgeLabel.isHidden = badge == nil } }

    override func loadView() {
        let v = CleanupItemView(frame: NSRect(x: 0, y: 0, width: 164, height: 164))
        v.onLayout = { [weak self] in self?.layoutLayers() }
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = 2
        v.layer?.addSublayer(imageLayer)
        faceLayer.fillColor = nil
        faceLayer.strokeColor = NSColor.systemOrange.cgColor
        faceLayer.lineWidth = 1.5
        v.layer?.addSublayer(faceLayer)

        check.translatesAutoresizingMaskIntoConstraints = false
        check.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        for l in [keepLabel, badgeLabel] {
            l.font = .systemFont(ofSize: 10, weight: .medium)
            l.textColor = .white
            l.wantsLayer = true
            l.drawsBackground = true
            l.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.6)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.isHidden = true
        }
        for s in [check, keepLabel, badgeLabel] as [NSView] { v.addSubview(s) }
        NSLayoutConstraint.activate([
            check.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            check.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            keepLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            keepLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
            badgeLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            badgeLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
        ])
        view = v
        updateCheck()
    }

    private func updateCheck() {
        let name = isChecked ? "checkmark.circle.fill" : "circle"
        check.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        check.contentTintColor = isChecked ? .controlAccentColor : NSColor.white.withAlphaComponent(0.85)
        // 勾上的（将被删除）略压暗，保留的保持原样，扫一眼就分得清
        imageLayer.opacity = isChecked ? 0.55 : 1
    }

    /// 图片在格子里按比例居中后的实际矩形
    private var imageRect: CGRect {
        let b = view.bounds.insetBy(dx: 4, dy: 4)
        guard let t = thumbnail, t.width > 0, t.height > 0 else { return b }
        let s = min(b.width / CGFloat(t.width), b.height / CGFloat(t.height))
        let w = CGFloat(t.width) * s, h = CGFloat(t.height) * s
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = imageRect
        imageLayer.frame = r
        let path = CGMutablePath()
        for f in faces {
            // 人脸框是左上原点的归一化坐标，图层是左下原点
            path.addRect(CGRect(x: r.minX + f.minX * r.width, y: r.minY + (1 - f.maxY) * r.height,
                                width: f.width * r.width, height: f.height * r.height))
        }
        faceLayer.frame = view.bounds
        faceLayer.path = path
        CATransaction.commit()
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.white.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        url = nil
        thumbnail = nil
        faces = []
        badge = nil
    }
}

private final class CleanupItemView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class CleanupHeader: NSView, NSCollectionViewElement {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 放大检查（盖在清理界面上，按键仍由网格接收）

final class CleanupPreviewView: NSView {
    private let imageLayer = CALayer()
    private let faceLayer = CAShapeLayer()
    private let captionLabel = NSTextField(labelWithString: "")

    var image: CGImage? { didSet { imageLayer.contents = image; needsLayout = true } }
    var faces: [CGRect] = [] { didSet { needsLayout = true } }
    var caption: String {
        get { captionLabel.stringValue }
        set { captionLabel.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1).cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = 2
        layer?.addSublayer(imageLayer)
        faceLayer.fillColor = nil
        faceLayer.strokeColor = NSColor.systemOrange.cgColor
        faceLayer.lineWidth = 2
        layer?.addSublayer(faceLayer)
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionLabel)
        NSLayoutConstraint.activate([
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 盖住下面的网格，点击不穿透
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds.insetBy(dx: 40, dy: 0)
        let area = CGRect(x: b.minX, y: 50, width: b.width, height: max(bounds.height - 50 - 40, 10))
        var r = area
        if let t = image, t.width > 0, t.height > 0 {
            let s = min(area.width / CGFloat(t.width), area.height / CGFloat(t.height))
            let w = CGFloat(t.width) * s, h = CGFloat(t.height) * s
            r = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        }
        imageLayer.frame = r
        let path = CGMutablePath()
        for f in faces {
            path.addRect(CGRect(x: r.minX + f.minX * r.width, y: r.minY + (1 - f.maxY) * r.height,
                                width: f.width * r.width, height: f.height * r.height))
        }
        faceLayer.frame = bounds
        faceLayer.path = path
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {}
}

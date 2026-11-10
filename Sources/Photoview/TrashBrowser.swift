import AppKit

/// 废纸篓里的照片。
///
/// 扫描本机废纸篓 `~/.Trash` 和各外置盘废纸篓 `<盘>/.Trashes/<uid>`，把最近删掉的图片列出来，
/// 选中就能放回。**不依赖任何删除记录**——所以用老版本删掉的照片也能在这里看见、捞回来。
final class TrashBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = TrashBrowserWindowController()

    struct Found {
        let url: URL
        let date: Date
        /// 位置说明：本机废纸篓 / 某块盘的名字
        let place: String
        /// 记录里能查到的原位置（自己删的、还没重启过）
        let original: URL?
    }

    /// 只看最近这么多天删掉的
    static let scanDays = 90
    /// 最多列这么多张，免得废纸篓里几万个文件时卡住
    static let scanLimit = 400

    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let restoreToButton = NSButton()
    private let restoreOriginalButton = NSButton()
    private let revealButton = NSButton()
    private var items: [Found] = []
    /// 放回以后要显示的提示：重扫完再显示，免得被「正在找…」盖掉
    private var pendingMessage: String?
    private var thumbs: [URL: NSImage] = [:]
    private let thumbQueue = DispatchQueue(label: "flipic.trashbrowser.thumbs", qos: .userInitiated)

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L10n.t("trashbrowse.title", "废纸篓里的照片")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 布局

    private func build() {
        guard let content = window?.contentView else { return }

        for (id, title, width) in [
            ("name", L10n.t("trashbrowse.colName", "照片"), CGFloat(420)),
            ("date", L10n.t("trashbrowse.colDate", "删除时间"), CGFloat(160)),
            ("where", L10n.t("trashbrowse.colWhere", "位置"), CGFloat(160)),
        ] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.rowHeight = 44
        table.allowsMultipleSelection = true
        // 代码里建的表格默认没有表头视图，不给的话第一行会被表头压住
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(restoreTo(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        restoreToButton.title = L10n.t("trashbrowse.restoreTo", "放回到…")
        restoreToButton.bezelStyle = .rounded
        restoreToButton.target = self
        restoreToButton.action = #selector(restoreTo(_:))

        restoreOriginalButton.title = L10n.t("trashbrowse.restoreOriginal", "放回原处")
        restoreOriginalButton.bezelStyle = .rounded
        restoreOriginalButton.target = self
        restoreOriginalButton.action = #selector(restoreOriginal(_:))

        revealButton.title = L10n.t("trashbrowse.reveal", "在 Finder 中显示")
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(revealInFinder(_:))

        let rescan = NSButton(title: L10n.t("trashbrowse.rescan", "重新扫描"), target: self, action: #selector(rescan(_:)))
        rescan.bezelStyle = .rounded

        let buttons = NSStackView(views: [restoreOriginalButton, restoreToButton, revealButton, rescan])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttons)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
    }

    // MARK: - 打开与扫描

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        startScan()
    }

    @objc private func rescan(_ sender: Any?) { startScan() }

    private func startScan() {
        status.stringValue = L10n.t("trashbrowse.scanning", "正在找废纸篓里的照片…")
        items = []
        thumbs = [:]
        table.reloadData()
        updateButtons()
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan(days: Self.scanDays, limit: Self.scanLimit)
            DispatchQueue.main.async {
                self.items = found
                self.table.reloadData()
                if let msg = self.pendingMessage {
                    self.status.stringValue = msg
                    self.pendingMessage = nil
                } else {
                    self.status.stringValue = found.isEmpty
                        ? L10n.t("trashbrowse.empty", "没找到能列出来的照片。本机废纸篓里的照片系统不让 App 读，可以在访达里直接看。")
                        : L10n.f("trashbrowse.found", "找到 %d 张", found.count)
                }
                self.updateButtons()
            }
        }
    }

    /// 扫描废纸篓里的图片，按删除时间从新到旧。
    ///
    /// 本机废纸篓 `~/.Trash` 系统不让 App 列目录（TCC 限制，只有访达能列），
    /// 所以本机的照片靠「最近一次删除」的记录找回：具体文件能查、能取回，只是没法扫全。
    /// 外置盘的 `.Trashes/501` 没有这个限制，能直接列出来。
    static func scan(days: Int, limit: Int) -> [Found] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let originals = originalMap()
        var out: [Found] = []
        var seen = Set<URL>()

        func consider(_ url: URL, place: String, original: URL?) {
            guard seen.insert(url.standardizedFileURL).inserted else { return }
            guard ImageLoader.isSupportedExtension(url.lastPathComponent) else { return }
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let date = v.contentModificationDate, date > cutoff else { return }
            out.append(Found(url: url, date: date, place: place, original: original))
        }

        // 1. 自己删的：记录里有原位置，能直接「放回原处」
        for (trashed, original) in originals {
            consider(trashed, place: placeName(for: trashed), original: original)
        }

        // 2. 能列目录的地方：本机废纸篓（有完全磁盘访问权限才行）+ 各外置盘废纸篓
        var roots: [(URL, String)] = [(Trash.localTrashFolder, L10n.t("trashbrowse.whereLocal", "本机废纸篓"))]
        for vol in Trash.mountedExternalVolumes {
            let name = vol.lastPathComponent
            let own = Trash.volumeTrashFolder(of: vol)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: own.path, isDirectory: &isDir), isDir.boolValue {
                roots.append((own, name))
            }
            let all = vol.appendingPathComponent(".Trashes")
            if let subs = try? fm.contentsOfDirectory(at: all, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) {
                for sub in subs where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if sub.standardizedFileURL.path == own.standardizedFileURL.path { continue }
                    roots.append((sub, name))
                }
            }
        }
        for (root, place) in roots {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var scanned = 0
            for case let url as URL in en {
                scanned += 1
                if scanned > 5000 { break }
                consider(url, place: place, original: originals[url])
            }
        }

        out.sort { $0.date > $1.date }
        return Array(out.prefix(limit))
    }

    /// 位置说明：外置盘取卷名，本机取「本机废纸篓」
    private static func placeName(for url: URL) -> String {
        let comps = url.pathComponents
        if comps.count > 2, comps[1] == "Volumes" {
            return comps[2]
        }
        return L10n.t("trashbrowse.whereLocal", "本机废纸篓")
    }

    /// 废纸篓里 → 原位置，从「最近一次删除」的记录里取（没重启过才有）
    private static func originalMap() -> [URL: URL] {
        guard let rec = ViewerViewController.lastTrash else { return [:] }
        var map: [URL: URL] = [:]
        for (orig, trashed) in rec.moved { map[trashed] = orig }
        return map
    }

    /// 截图自测：`--trashbrowseshot <png>`，开窗、扫完、把窗口本身画成 PNG 再退出
    func debugShot(to path: String) {
        show()
        // 先选中一行，让「放回」按钮变成可用，再等一帧重绘
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !self.items.isEmpty {
                self.table.selectRowIndexes([0, min(1, self.items.count - 1)], byExtendingSelection: false)
                self.updateButtons()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard let w = self.window else { print("trashbrowseshot no-window"); exit(1) }
            // 让窗口服务器合成，背景、表头、按钮都是用户真正看到的样子
            let rect = CGRect(x: 0, y: 0, width: w.frame.width, height: w.frame.height)
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                   CGWindowID(w.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) else {
                print("trashbrowseshot capture-failed")
                exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: img)
            rep.size = NSSize(width: rect.width, height: rect.height)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("trashbrowseshot wrote \(path) rows=\(self.items.count)")
            }
            exit(0)
        }
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, items.indices.contains(row) else { return nil }
        let item = items[row]
        switch id.rawValue {
        case "name":
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? nameCell(id)
            cell.textField?.stringValue = item.url.lastPathComponent
            cell.imageView?.image = thumbs[item.url] ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            loadThumb(item.url)
            return cell
        case "date":
            let cell = textCell(id)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            cell.textField?.stringValue = f.string(from: item.date)
            return cell
        default:
            let cell = textCell(id)
            cell.textField?.stringValue = item.place
            return cell
        }
    }

    private func textCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let v = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return v }
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func nameCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(iv)
        cell.addSubview(tf)
        cell.imageView = iv
        cell.textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 36),
            iv.heightAnchor.constraint(equalToConstant: 36),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// 缩略图在后台按需生成，只做已经滚到眼前的这些
    private func loadThumb(_ url: URL) {
        if thumbs[url] != nil { return }
        thumbQueue.async {
            guard let cg = ImageLoader.renderThumbnail(url: url, maxPixel: 72, allowEmbedded: true) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                self.thumbs[url] = img
                guard let row = self.items.firstIndex(where: { $0.url == url }) else { return }
                self.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        let picked = selectedItems
        restoreToButton.isEnabled = !picked.isEmpty
        revealButton.isEnabled = !picked.isEmpty
        restoreOriginalButton.isEnabled = !picked.isEmpty && picked.allSatisfy { $0.original != nil }
    }

    private var selectedItems: [Found] {
        table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    // MARK: - 放回

    @objc private func restoreTo(_ sender: Any?) {
        let picked = selectedItems
        guard !picked.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("trashbrowse.restoreTo", "放回到…")
        panel.message = L10n.t("trashbrowse.choose", "放回到哪个文件夹")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let done = Self.moveBack(picked, to: dir)
        finish(done: done, total: picked.count)
    }

    @objc private func restoreOriginal(_ sender: Any?) {
        let picked = selectedItems
        guard !picked.isEmpty else { return }
        let done = Self.moveBackToOriginals(picked)
        if done < picked.count && picked.contains(where: { $0.original == nil }) {
            let alert = NSAlert()
            alert.messageText = L10n.t("trashbrowse.originalMissing", "不知道这几张原来在哪，用「放回到…」挑个文件夹")
            alert.addButton(withTitle: L10n.t("trashhelp.ok", "好"))
            alert.runModal()
        }
        finish(done: done, total: picked.count)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// 放回到指定文件夹，返回成功张数（重名加编号，不覆盖已有文件）
    @discardableResult
    static func moveBack(_ items: [Found], to dir: URL) -> Int {
        var done = 0
        for item in items where move(item.url, to: dir, preferredName: nil) { done += 1 }
        return done
    }

    /// 放回各自的原位置；不知道原位置的不动
    @discardableResult
    static func moveBackToOriginals(_ items: [Found]) -> Int {
        var done = 0
        for item in items {
            guard let original = item.original else { continue }
            let dir = original.deletingLastPathComponent()
            if move(item.url, to: dir, preferredName: original.lastPathComponent) { done += 1 }
        }
        return done
    }

    /// 单个文件挪回目标文件夹；重名加编号，不覆盖已有的文件
    @discardableResult
    static func move(_ url: URL, to dir: URL, preferredName: String?) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let dest = Trash.uniqueURL(named: preferredName ?? url.lastPathComponent, in: dir)
        return (try? fm.moveItem(at: url, to: dest)) != nil
    }

    private func finish(done: Int, total: Int) {
        if done > 0 { pendingMessage = L10n.f("trashbrowse.restored", "已放回 %d 张", done) }
        if done < total { pendingMessage = L10n.f("trashbrowse.failed", "%d 张没能放回", total - done) }
        startScan()
    }
}

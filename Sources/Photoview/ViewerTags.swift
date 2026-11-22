import AppKit

/// 访达颜色标签和复制文件名（看图界面这一半；读写文件在 Tags.swift）
extension ViewerViewController {
    // MARK: - 菜单

    /// 「颜色标签」子菜单：红橙黄绿蓝紫灰七项（前面带色块，打勾表示当前照片有这个标签），最后是清除。
    /// 主菜单和右键菜单共用；右键菜单自己把 target 设成看图界面
    static func buildTagMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.t("menu.tags", "颜色标签"))
        for c in TagColor.allCases {
            let it = NSMenuItem(title: c.title, action: #selector(setTagColorMenu(_:)), keyEquivalent: "")
            it.tag = c.index
            it.image = c.swatch
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menu.tagsClear", "清除颜色标签"), action: #selector(clearTagColors(_:)), keyEquivalent: ""))
        return menu
    }

    /// 「只看颜色标签」子菜单：全部照片，然后七种颜色
    static func buildTagFilterMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.t("menu.tagFilter", "只看颜色标签"))
        let all = NSMenuItem(title: L10n.t("menu.ratingFilterAll", "全部照片"), action: #selector(setTagFilter(_:)), keyEquivalent: "")
        all.tag = 0
        menu.addItem(all)
        menu.addItem(.separator())
        for c in TagColor.allCases {
            let it = NSMenuItem(title: c.title, action: #selector(setTagFilter(_:)), keyEquivalent: "")
            it.tag = c.index
            it.image = c.swatch
            menu.addItem(it)
        }
        return menu
    }

    /// 颜色项打勾：要处理的照片（多选时是选中的那些）都有这个标签打勾，只有一部分有就是减号
    func validateTagColorItem(_ item: NSMenuItem) -> Bool {
        guard folder.current != nil, cleanup == nil, let c = TagColor(rawValue: item.tag) else { item.state = .off; return false }
        let urls = actionURLs
        let have = folder.tagColors(for: urls)
        let count = urls.filter { have[$0]?.contains(c) == true }.count
        item.state = count == 0 ? .off : (count == urls.count ? .on : .mixed)
        return true
    }

    @objc func setTagColorMenu(_ sender: NSMenuItem) {
        if let c = TagColor(rawValue: sender.tag) { toggleTagColor(c) }
    }

    // MARK: - 打标签

    /// 要写的文件：处理的照片，加上同名的 RAW / JPG 搭档（和评分、标记一样当成一张）
    private func tagTargets() -> [URL] {
        var seen = Set<URL>()
        var targets: [URL] = []
        for u in actionURLs { for t in ratingTargets(for: u) where seen.insert(t).inserted { targets.append(t) } }
        return targets
    }

    /// 切换一种颜色标签：选中的照片都有就全去掉，否则全加上；其他标签不动。再按一次同一个键就是去掉。
    /// 写访达标签的同时同步写标准 XMP xmp:Label（Lightroom Classic / Capture One / Photo Mechanic 都能认）
    func toggleTagColor(_ color: TagColor) {
        guard cleanup == nil, folder.current != nil else { return }
        let targets = tagTargets()
        let have = folder.tagColors(for: targets)
        let on = !targets.allSatisfy { have[$0]?.contains(color) == true }
        applyTagChange(targets,
                       message: on ? L10n.f("msg.tagAdded", "已加上颜色标签：%@", color.title)
                                   : L10n.f("msg.tagRemoved", "已去掉颜色标签：%@", color.title),
                       change: { $0.with(color, on: on) },
                       write: { url in
                           guard FinderTags.set(color, on: on, for: url) else { return false }
                           let nextLabel = on ? color : FinderTags.colors(of: url).colors.first
                           _ = Rating.writeLabel(nextLabel, to: url)
                           return true
                       })
    }

    @objc func clearTagColors(_ sender: Any?) {
        guard cleanup == nil, folder.current != nil else { return }
        applyTagChange(tagTargets(), message: L10n.t("msg.tagsCleared", "已清除颜色标签"),
                       change: { _ in TagColorSet() }, write: { url in
                           guard FinderTags.clearColors(for: url) else { return false }
                           _ = Rating.writeLabel(nil, to: url)
                           return true
                       })
    }

    /// 先改界面，后台写文件；写不进去（只读的盘、没有权限）就把界面改回去并说明
    private func applyTagChange(_ targets: [URL], message: String, change: @escaping (TagColorSet) -> TagColorSet,
                                write: @escaping (URL) -> Bool) {
        let old = folder.tagColors(for: targets)
        for t in targets { folder.setTagColors(change(old[t] ?? TagColorSet()), url: t) }
        refreshTags()
        flash(message, seconds: 1.2)
        ratingQueue.async { [weak self] in
            let failed = targets.filter { !write($0) }
            guard !failed.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for t in failed { self.folder.setTagColors(old[t] ?? TagColorSet(), url: t) }
                self.refreshTags()
                self.flash(failed.contains { Volumes.info(for: $0)?.readOnly == true }
                           ? L10n.t("tag.readOnly", "这张卡是只读的，颜色标签没有写入")
                           : L10n.f("msg.tagFailed", "颜色标签没能写入：%@", failed.map(\.lastPathComponent).joined(separator: "、")), seconds: 4)
            }
        }
    }

    /// 颜色标签变了以后刷新左下角的圆点、缩略图上的圆点、信息面板和顶部计数，不重建缩略图栏
    func refreshTags() {
        updateRatingLabel()
        for case let cell as FilmstripItem in filmstrip.collectionView.visibleItems()
        where folder.items.indices.contains(cell.itemIndex) {
            cell.setTagColors(folder.items[cell.itemIndex].tagColors)
        }
        updateMarkedOnlyPill()
        if !exifPanel.isHidden { updateExifPanel() }
    }

    // MARK: - 只看某种颜色标签

    /// 「只看颜色标签」菜单：tag 是颜色序号，0 是全部；再选一次同一种回到全部。
    /// 筛选条件同一时刻只有一个：选了颜色，「只看已标记」「只看星级」就换掉，反过来也一样
    @objc func setTagFilter(_ sender: NSMenuItem) { applyTagFilter(TagColor(rawValue: sender.tag)) }

    func applyTagFilter(_ color: TagColor?) {
        guard cleanup == nil, folder.totalCount > 0 else { return }
        exitCompare()
        guard let color, folder.filter != .colorTag(color) else {
            if folder.filter != nil, folder.setFilter(nil) { filterDidChange() }
            return
        }
        guard folder.setFilter(.colorTag(color)) else {
            flash(L10n.f("msg.noTagMatch", "没有带「%@」标签的照片", color.title), seconds: 2.5)
            return
        }
        filterDidChange()
    }

    // MARK: - 复制文件名

    private func putNames(_ names: [String], on pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(names.joined(separator: "\n"), forType: .string)
        flash(L10n.f("msg.copiedNames", "已拷贝文件名（%d 个）", names.count), seconds: 2)
    }

    /// 当前照片（多选时是选中的那些）的文件名，带扩展名，每行一个。
    /// 合并显示 JPG 和 RAW 时一对只算一行，用显示着的那个文件的名字。pb 只有自测才换成别的，免得动用户的剪贴板
    func copyFileNames(to pb: NSPasteboard = .general) {
        guard cleanup == nil, folder.current != nil else { return }
        putNames(actionURLs.map(\.lastPathComponent), on: pb)
    }

    /// 当前文件夹里全部已标记照片的文件名，按当前的排序；一个都没标记时什么也不做
    func copyMarkedFileNames(to pb: NSPasteboard = .general) {
        guard cleanup == nil else { return }
        let shown = folder.allItems.filter { !folder.hidden.contains($0.url) }
        // 合并显示时藏起来的那个标记了也算这一对标记了
        let markedKeys: Set<String>? = folder.hidden.isEmpty ? nil
            : Set(folder.allItems.filter(\.marked).map { $0.url.deletingPathExtension().path })
        let names = shown.filter { markedKeys?.contains($0.url.deletingPathExtension().path) ?? $0.marked }.map { $0.url.lastPathComponent }
        guard !names.isEmpty else { return }
        putNames(names, on: pb)
    }

    @objc func copyFileNames(_ sender: Any?) { copyFileNames(to: .general) }
    @objc func copyMarkedFileNames(_ sender: Any?) { copyMarkedFileNames(to: .general) }
}

import AppKit
import Darwin

/// 删除照片统一走这里。
///
/// 默认和访达一致：文件进它**所在卷**的废纸篓。外置盘（U 盘、移动硬盘）有自己的废纸篓，
/// 在 `<卷>/.Trashes/<uid>`，不在本机 `~/.Trash` 里，盘拔掉以后就看不到了——用户很容易以为没删成功。
///
/// 打开「删除外置盘上的照片时，复制到本机废纸篓」以后，外置盘上的文件先复制进 `~/.Trash` 再删原文件：
/// 这样所有删除都集中在本机废纸篓，缺点是要多复制一份（跨卷没有真正的移动），大文件会慢、会临时占本机空间。
/// 复制失败（空间不够、盘只读、盘中途拔掉）时自动退回该盘自己的废纸篓，保证文件一定有个去处。
enum Trash {
    /// 一次删除的结果
    struct Outcome {
        /// 原位置 → 废纸篓里的位置；只有这里面的文件才真的挪走了（可以 ⌘Z 放回）
        var moved: [URL: URL] = [:]
        /// 没能挪走的，文件还在原处
        var failed: [URL] = []
        /// 参与删除的外置盘名字（从卷名取，比如「LaCie」）；没有外置盘时 nil
        var volumeName: String?
        /// 这次是不是复制进了本机废纸篓（而不是盘上自己的废纸篓）
        var usedLocalTrash = false
    }

    // MARK: - 设置

    /// 设置项：外置盘上的照片删除时复制到本机废纸篓。默认关，和访达行为一致
    static var copyExternalToLocal: Bool {
        get { UserDefaults.standard.bool(forKey: "trashExternalToLocal") }
        set { UserDefaults.standard.set(newValue, forKey: "trashExternalToLocal") }
    }

    /// 这次删除会走「复制到本机废纸篓」吗（调用方据此先给个「正在复制…」提示）
    static func usesLocalCopy(_ urls: [URL]) -> Bool {
        copyExternalToLocal && urls.contains { externalVolume(of: $0) != nil }
    }

    // MARK: - 位置

    static var localTrashFolder: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
    }

    /// 文件所在的卷；启动盘返回 nil，外置盘返回比如 `/Volumes/LaCie`
    static func externalVolume(of url: URL) -> URL? {
        guard let vol = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
              vol.path != "/" else { return nil }
        return vol
    }

    /// 卷的名字（`/Volumes/LaCie` → `LaCie`）
    static func volumeName(of url: URL) -> String? {
        externalVolume(of: url)?.lastPathComponent
    }

    /// 外置盘自己的废纸篓位置：`<卷>/.Trashes/<uid>`（只是用来「在 Finder 中显示」，取不到就算了）
    static func volumeTrashFolder(of volume: URL) -> URL {
        volume.appendingPathComponent(".Trashes").appendingPathComponent(String(getuid()))
    }

    static func volumeTrashFolder(forFile url: URL) -> URL? {
        externalVolume(of: url).map(volumeTrashFolder(of:))
    }

    /// 真能打开的位置：用户废纸篓 → 整块盘的 .Trashes → 盘根目录（目录不存在时逐级退，别点了没反应）
    static func existingVolumeTrashFolder(of volume: URL) -> URL {
        let fm = FileManager.default
        let byUser = volumeTrashFolder(of: volume)
        if fm.fileExists(atPath: byUser.path) { return byUser }
        let all = volume.appendingPathComponent(".Trashes")
        if fm.fileExists(atPath: all.path) { return all }
        return volume
    }

    /// 现在挂着的本地外置卷（网络盘不算：它们多半没有废纸篓）
    static var mountedExternalVolumes: [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey]
        let all = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                        options: [.skipHiddenVolumes]) ?? []
        return all.filter { vol in
            guard vol.path != "/" else { return false }
            let values = try? vol.resourceValues(forKeys: Set(keys))
            return values?.volumeIsLocal ?? false
        }
    }

    // MARK: - 删除

    /// 把文件移到废纸篓；completion 一定回到主线程。
    /// 先按卷分组：要复制到本机的走复制，其余用系统的 trashItem（进所在卷的废纸篓）。
    static func trash(_ urls: [URL], completion: @escaping (Outcome) -> Void) {
        var seen = Set<URL>()
        let files = urls.filter { seen.insert($0).inserted }
        guard !files.isEmpty else {
            completion(Outcome())
            return
        }
        var out = Outcome()
        out.volumeName = files.lazy.compactMap(volumeName(of:)).first
        out.usedLocalTrash = copyExternalToLocal && files.contains { externalVolume(of: $0) != nil }

        // 以实际落点为准：复制成功进了 ~/.Trash 的才算「本机废纸篓」，
        // 复制不成退回盘上废纸篓的那些不能被说成本机废纸篓
        let localRoot = localTrashFolder.standardizedFileURL.path
        let copyLocally = out.usedLocalTrash
        DispatchQueue.global(qos: .userInitiated).async {
            var moved: [URL: URL] = [:]
            var failed: [URL] = []
            var localCount = 0
            for url in files {
                let dest: URL?
                if copyLocally, externalVolume(of: url) != nil {
                    // 复制到本机废纸篓；失败就退回这块盘自己的废纸篓，别让文件没地方去
                    dest = copyIntoLocalTrash(url) ?? moveToVolumeTrash(url)
                } else {
                    dest = moveToVolumeTrash(url)
                }
                if let dest {
                    moved[url] = dest
                    if dest.standardizedFileURL.path.hasPrefix(localRoot + "/") { localCount += 1 }
                } else {
                    failed.append(url)
                }
            }
            DispatchQueue.main.async {
                out.moved = moved
                out.failed = failed
                out.usedLocalTrash = localCount > 0
                completion(out)
            }
        }
    }

    /// 系统回收：进文件所在卷的废纸篓，返回废纸篓里的位置
    private static func moveToVolumeTrash(_ url: URL) -> URL? {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        } catch {
            return nil
        }
    }

    /// 在 dir 里给 name 找一个不重名的位置：`IMG.jpg`、`IMG 2.jpg`、`IMG 3.jpg`…
    static func uniqueURL(named name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let probe = URL(fileURLWithPath: name)
        let base = probe.deletingPathExtension().lastPathComponent
        let ext = probe.pathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(candidate)
            n += 1
            if n > 500 { return dir.appendingPathComponent(UUID().uuidString) }
        }
        return dest
    }

    /// 复制进本机废纸篓再删原文件（跨卷没有真正的移动）。重名时加编号，不覆盖废纸篓里已有的东西
    private static func copyIntoLocalTrash(_ url: URL) -> URL? {
        let fm = FileManager.default
        let dir = localTrashFolder
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(named: url.lastPathComponent, in: dir)
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        do {
            try fm.removeItem(at: url)
        } catch {
            // 复制成了但原文件删不掉：删掉刚复制的那份，退回盘上废纸篓，避免留两个副本
            try? fm.removeItem(at: dest)
            return nil
        }
        return dest
    }

    // MARK: - 提示与找回

    /// 「已移到…废纸篓 N 张」的提示；一个都没挪成时只说失败，不报「0 张」
    static func summary(_ out: Outcome, count: Int) -> String {
        if out.moved.isEmpty {
            guard !out.failed.isEmpty else { return "" }
            return L10n.f("trash.someFailed", "%d 个没挪动成功，还在原处", out.failed.count)
        }
        var text: String
        if out.usedLocalTrash {
            text = L10n.f("trash.movedLocal", "已移到本机废纸篓 %d 张 · ⌘Z 撤销", count)
        } else if let vol = out.volumeName {
            text = L10n.f("trash.movedVolume", "已移到「%@」的废纸篓 %d 张 · ⌘Z 撤销", vol, count)
        } else {
            text = L10n.f("cleanup.trashed", "已移到废纸篓 %d 张 · ⌘Z 撤销", count)
        }
        if !out.failed.isEmpty {
            text += " · " + L10n.f("trash.someFailed", "%d 个没挪动成功，还在原处", out.failed.count)
        }
        return text
    }

    /// 在 Finder 里选中这些已经删掉的文件（本机废纸篓、盘上废纸篓都行）
    static func revealInFinder(_ trashed: [URL]) {
        guard !trashed.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(trashed)
    }

    /// 用 Finder 打开一个文件夹（废纸篓这种隐藏目录也能直接打开）
    static func openFolder(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }
}

/// 把「最近一次删除」存一份到磁盘。退出 Flipic、装上更新以后，
/// 「文件 › 放回刚才删掉的照片」「在 Finder 中显示刚才删掉的照片」仍然可用——
/// 前提是废纸篓还没清空、或者那块盘还接得上。
enum TrashLedger {
    /// 超过这个天数就不认了，免得翻出很久以前的记录
    static let keepDays: Double = 14

    private static var folderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Flipic", isDirectory: true)
    }

    static var fileURL: URL { folderURL.appendingPathComponent("last-trash.json") }

    static func save(_ rec: ViewerViewController.TrashRecord?) {
        let fm = FileManager.default
        guard let rec, !rec.moved.isEmpty else {
            try? fm.removeItem(at: fileURL)
            return
        }
        var pairs: [[String]] = rec.moved.map { [$0.key.path, $0.value.path] }
        pairs.sort { $0[0] < $1[0] }
        var payload: [String: Any] = [
            "date": Date().timeIntervalSince1970,
            "pairs": pairs,
        ]
        if let p = rec.photo?.path { payload["photo"] = p }
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// 读出还找得到的记录：文件还在废纸篓里，或者那块盘只是没插着（接上还能用）
    static func load() -> ViewerViewController.TrashRecord? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any],
              let pairs = obj["pairs"] as? [[String]],
              let date = obj["date"] as? Double else { return nil }
        guard Date().timeIntervalSince1970 - date <= keepDays * 86400 else {
            try? fm.removeItem(at: fileURL)
            return nil
        }
        var moved: [URL: URL] = [:]
        for pair in pairs where pair.count == 2 {
            let original = URL(fileURLWithPath: pair[0])
            let trashed = URL(fileURLWithPath: pair[1])
            if fm.fileExists(atPath: trashed.path) {
                moved[original] = trashed
            } else if !volumeRootExists(of: trashed) {
                // 盘没插着：记录先留着，接上盘还能放回
                moved[original] = trashed
            }
            // 盘在、文件不在：废纸篓已经清空，丢掉这条
        }
        guard !moved.isEmpty else {
            try? fm.removeItem(at: fileURL)
            return nil
        }
        let photo = (obj["photo"] as? String).flatMap { p -> URL? in
            let u = URL(fileURLWithPath: p)
            return moved.keys.contains(u) ? u : nil
        }
        return ViewerViewController.TrashRecord(moved: moved, photo: photo)
    }

    /// 记录里的文件所在的卷现在还挂着吗（`/Volumes/名字/…`）
    private static func volumeRootExists(of url: URL) -> Bool {
        let comps = url.pathComponents
        if comps.count > 2, comps[1] == "Volumes" {
            return FileManager.default.fileExists(atPath: "/Volumes/" + comps[2])
        }
        return FileManager.default.fileExists(atPath: "/")
    }
}

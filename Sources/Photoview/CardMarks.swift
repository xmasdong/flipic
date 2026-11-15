import Foundation

/// 存储卡上的挑片标记：不往卡里写，记在这台电脑的 Application Support/Flipic/card-marks.json。
/// 哪些卷算「卡」见 Volumes.keepsMarksOffVolume。按卷标识（UUID，没有就退回卷名 + 容量）加相对卷根的路径记，
/// 卡拔了再插、挂载点变了，标记照样回来。App Store 沙盒版里 Application Support 是容器内的同名路径，不需要额外权限
enum CardMarks {
    struct Entry: Codable {
        var name: String
        var lastSeen: Double
        /// 小写、规范化后的相对路径
        var marks: [String]
    }
    struct Store: Codable {
        var version = 1
        var volumes: [String: Entry] = [:]
    }

    /// 超过这么多天没见过的卷，标记记录清掉
    static let pruneDays: Double = 90
    /// 测试用：换一个存放位置，不碰真正的记录
    static var storeURLOverride: URL?
    /// 这次运行里已经告诉过用户「标记只记在这台电脑上」了
    static var noticeShown = false

    private static let lock = NSLock()
    private static var loaded: Store?

    static var storeURL: URL {
        if let o = storeURLOverride { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Flipic", isDirectory: true).appendingPathComponent("card-marks.json")
    }

    /// 测试用：马上读一次记录（读的时候会清掉太久没见的卷）
    static func forceLoadForTest() { lock.lock(); _ = load(); lock.unlock() }

    /// 测试用：丢掉内存里的副本，下次从文件重新读（模拟重启软件）
    static func reloadFromDisk() { lock.lock(); loaded = nil; lock.unlock() }

    static func normalized(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    // MARK: - 判断与定位

    /// 这个路径所在的卷是「标记不往里写」的卷吗；是就给出卷信息
    static func appSideVolume(for url: URL) -> VolumeInfo? {
        guard let i = Volumes.info(for: url), Volumes.keepsMarksOffVolume(i) else { return nil }
        return i
    }

    static func usesAppSide(_ url: URL) -> Bool { appSideVolume(for: url) != nil }

    /// 相对卷根的路径（规范化）。路径经过符号链接（/tmp → /private/tmp）时先解开再比
    static func relativePath(_ url: URL, in info: VolumeInfo) -> String? {
        let root = info.root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        var rel = String(path.dropFirst(root.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return normalized(rel)
    }

    // MARK: - 读写记录

    private static func load() -> Store {
        if let s = loaded { return s }
        var s = Store()
        if let d = try? Data(contentsOf: storeURL), let decoded = try? JSONDecoder().decode(Store.self, from: d) { s = decoded }
        // 很久没见过的卷：记录清掉
        let cutoff = Date().timeIntervalSince1970 - pruneDays * 86_400
        let before = s.volumes.count
        s.volumes = s.volumes.filter { $0.value.lastSeen >= cutoff }
        loaded = s
        if s.volumes.count != before { save(s) }
        return s
    }

    private static func save(_ s: Store) {
        let url = storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: url, options: .atomic) }
    }

    /// 取这个卷的记录改一改再存回去
    private static func mutate(_ info: VolumeInfo, _ change: (inout Entry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        var e = s.volumes[info.key] ?? Entry(name: info.name, lastSeen: 0, marks: [])
        e.name = info.name
        e.lastSeen = Date().timeIntervalSince1970
        change(&e)
        s.volumes[info.key] = e
        loaded = s
        save(s)
    }

    /// 这个文件夹里被标记的文件名（规范化）；文件夹不在「卡」上返回 nil（走访达标签那条路）
    static func markedNames(inFolder dir: URL) -> Set<String>? {
        guard let info = appSideVolume(for: dir), let rel = relativePath(dir, in: info) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var s = load()
        guard var e = s.volumes[info.key] else { return [] }
        // 看过一次就算「见过」，刷新时间（不用每次都写盘：一天内不重复写）
        let now = Date().timeIntervalSince1970
        if now - e.lastSeen > 86_400 {
            e.lastSeen = now
            e.name = info.name
            s.volumes[info.key] = e
            loaded = s
            save(s)
        }
        let prefix = rel.isEmpty ? "" : rel + "/"
        var names = Set<String>()
        for m in e.marks where m.hasPrefix(prefix) {
            let rest = m.dropFirst(prefix.count)
            if !rest.contains("/") { names.insert(String(rest)) }
        }
        return names
    }

    /// 记录里有没有这个文件（只看记录，不看访达标签）
    static func isStoreMarked(_ url: URL) -> Bool {
        guard let info = appSideVolume(for: url), let rel = relativePath(url, in: info) else { return false }
        lock.lock(); defer { lock.unlock() }
        return load().volumes[info.key]?.marks.contains(rel) ?? false
    }

    /// 标上或取消；不在「卡」上的文件什么也不做并返回 false
    @discardableResult
    static func set(_ on: Bool, for url: URL) -> Bool {
        guard let info = appSideVolume(for: url), let rel = relativePath(url, in: info) else { return false }
        if !on, !isStoreMarked(url) { return true }
        mutate(info) { e in
            e.marks.removeAll { $0 == rel }
            if on { e.marks.append(rel); e.marks.sort() }
        }
        return true
    }

    /// 文件改了名：记录跟着改
    static func rename(from old: URL, to new: URL) {
        guard isStoreMarked(old) else { return }
        set(false, for: old)
        set(true, for: new)
    }
}

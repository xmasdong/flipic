import Foundation
import ImageIO

struct ImageItem {
    let url: URL
    var pixelSize: CGSize?
    var modified: Date?
    var created: Date?
    var fileSize: Int = 0
    /// EXIF 拍摄时间；nil 表示尚未读取，读过但没有则回落为修改时间
    var captureDate: Date?
    /// 挑片标记（访达标签「Flipic」）
    var marked = false
    /// 星级；nil 表示还没读过
    var rating: Int?
    /// 访达颜色标签（红橙黄绿蓝紫灰），和挑片标记、星级各管各的
    var tagColors = TagColorSet()
    /// 放进这个文件夹的时间（访达的「添加日期」）；拷卡、下载、拖进来的时间，和拍摄、修改时间都不一样
    var added: Date?
}

/// 「只看」筛选：已标记，或某个星级以上
enum PhotoFilter: Equatable {
    case marked
    case minRating(Int)
    /// 带某种访达颜色标签
    case colorTag(TagColor)
    #if FLIPIC_PRO
    /// Pro：按内容查找的结果，列表按分数从高到低排
    case content(ContentMatch)
    /// Pro：按客户文件名清单匹配的结果（按无扩展名主路径匹配，同名 RAW+JPG 自动成对）
    case nameList(Set<String>, Int)
    #endif

    func matches(_ item: ImageItem) -> Bool {
        switch self {
        case .marked: return item.marked
        case .minRating(let n): return (item.rating ?? 0) >= n
        case .colorTag(let c): return item.tagColors.contains(c)
        #if FLIPIC_PRO
        case .content(let m): return m.scores[item.url] != nil
        case .nameList(let keys, _): return keys.contains(item.url.deletingPathExtension().path)
        #endif
        }
    }
}

enum SortKey: Int, CaseIterable {
    // 原始值存在偏好设置里，新加的只能往后排；菜单里的顺序看 menuOrder
    case name, captureDate, modified, created, size, added

    /// 菜单和设置里的顺序：「添加时间」跟在「创建时间」后面
    static let menuOrder: [SortKey] = [.name, .captureDate, .modified, .created, .added, .size]

    /// 各排序方式的自然方向（与 Finder 一致）：名称 A→Z，时间新的在前，大小大的在前
    var largestFirst: Bool { self != .name }

    var title: String {
        switch self {
        case .name: return L10n.t("sort.name", "文件名")
        case .captureDate: return L10n.t("sort.captureDate", "拍摄时间")
        case .modified: return L10n.t("sort.modified", "修改时间")
        case .created: return L10n.t("sort.created", "创建时间")
        case .size: return L10n.t("sort.size", "文件大小")
        case .added: return L10n.t("sort.added", "添加时间")
        }
    }
}

/// 文件夹里的图片列表与当前位置
final class FolderModel {
    private(set) var items: [ImageItem] = []
    private(set) var index: Int = 0
    /// 筛选或有藏起来的文件时存着完整列表，items 只是其中显示的；nil 表示显示全部
    private var unfiltered: [ImageItem]?
    private(set) var filter: PhotoFilter?
    /// 不单独显示的文件（JPG 和 RAW 合并显示时藏起来的那一张），仍在整个文件夹的列表里
    private(set) var hidden: Set<URL> = []
    /// 打开的文件夹；照片全被删光了也还记着，别处再放进来能接着显示
    private(set) var folderURL: URL?
    /// 当前目录里已存在的 .xmp 旁车文件无扩展名小写集合（列目录时顺带收集，0 额外磁盘探测）
    private(set) var xmpStems: Set<String> = []

    func hasSidecar(for url: URL) -> Bool { xmpStems.contains(Rating.sidecarStem(for: url)) }
    func noteSidecarPresent(for url: URL) { xmpStems.insert(Rating.sidecarStem(for: url)) }

    /// 排序方式与方向，跨启动记住；sortReversed 是在该方式自然方向上反过来。
    /// 跟随访达时用 finderSort，不动记住的那个；指定一种排序方式就不再跟随访达
    var sortKey: SortKey {
        get { activeFinder?.key ?? SortKey(rawValue: UserDefaults.standard.integer(forKey: "sortKey")) ?? .name }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "sortKey")
            Self.followsFinder = false
            finderSort = nil
        }
    }
    /// 跟随访达时点「倒序」只对这个文件夹有效，下次打开文件夹又按访达的
    var sortReversed: Bool {
        get { activeFinder?.reversed ?? UserDefaults.standard.bool(forKey: "sortReversed") }
        set {
            if activeFinder != nil { finderSort?.reversed = newValue }
            else { UserDefaults.standard.set(newValue, forKey: "sortReversed") }
        }
    }

    /// 跟随访达的排序：从没选过排序方式的默认跟随，选过的照旧
    static var followsFinder: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: "sortFollowsFinder") as? Bool ?? (d.object(forKey: "sortKey") == nil)
        }
        set { UserDefaults.standard.set(newValue, forKey: "sortFollowsFinder") }
    }
    /// 跟随访达时，当前文件夹在访达里的排序
    private(set) var finderSort: FinderSort.Order?
    /// 别的窗口里改成了指定排序时，这个窗口也不再按访达的
    private var activeFinder: FinderSort.Order? { finderSort.flatMap { Self.followsFinder ? $0 : nil } }

    /// 打开文件夹、改了设置时重新读一次访达的排序
    func refreshFinderSort() {
        finderSort = Self.followsFinder ? folderURL.map(FinderSort.resolve) : nil
    }

    var count: Int { items.count }
    var current: ImageItem? { items.isEmpty ? nil : items[index] }

    var markedOnly: Bool { filter == .marked }
    /// 整个文件夹的列表，不受筛选影响
    var allItems: [ImageItem] { unfiltered ?? items }
    /// 整个文件夹的张数，不受筛选影响；合并显示的一对算一张
    var totalCount: Int { (unfiltered?.count ?? items.count) - hidden.count }
    var markedCount: Int { (unfiltered ?? items).filter { $0.marked && !hidden.contains($0.url) }.count }
    /// 整个文件夹里符合当前筛选条件的张数
    var matchingCount: Int { filter.map { f in allItems.filter { !hidden.contains($0.url) && f.matches($0) }.count } ?? items.count }
    /// 还没读过星级的文件
    var urlsMissingRating: [URL] { allItems.filter { $0.rating == nil }.map(\.url) }

    /// 改列表里某个文件的信息，两份列表一起改
    private func update(_ url: URL, _ change: (inout ImageItem) -> Void) {
        for i in items.indices where items[i].url == url { change(&items[i]) }
        if var all = unfiltered {
            for i in all.indices where all[i].url == url { change(&all[i]) }
            unfiltered = all
        }
    }

    /// 自己写了这些文件（保存裁剪、写星级）：只把它们记的修改时间和大小更新到磁盘上现在的，不扫整个文件夹
    func noteOwnWrites(_ urls: [URL]) {
        for u in urls {
            guard let s = FolderWatcher.stamp(of: u) else { continue }
            let name = u.lastPathComponent, target = u.standardizedFileURL.path
            func match(_ item: ImageItem) -> Bool { item.url.lastPathComponent == name && item.url.standardizedFileURL.path == target }
            for i in items.indices where match(items[i]) { items[i].modified = s.modified; items[i].fileSize = s.size }
            if var all = unfiltered {
                for i in all.indices where match(all[i]) { all[i].modified = s.modified; all[i].fileSize = s.size }
                unfiltered = all
            }
        }
    }

    /// 被别的软件改过的照片（修改时间或大小和记下的不一样）：更新记录，返回这些文件。
    /// Flipic 自己写星级、旋转造成的变化只更新记录，不算在内
    func takeModifiedOutside() -> [URL] {
        var changed: [URL] = []
        for item in allItems {
            guard let s = FolderWatcher.stamp(of: item.url),
                  s.modified != item.modified || s.size != item.fileSize else { continue }
            update(item.url) { $0.modified = s.modified; $0.fileSize = s.size }
            if !FolderWatcher.isOwnWrite(item.url, s) { changed.append(item.url) }
        }
        return changed
    }

    func setMarked(_ on: Bool, url: URL) { update(url) { $0.marked = on } }
    func setRating(_ rating: Int?, url: URL) { update(url) { $0.rating = rating } }
    func setTagColors(_ colors: TagColorSet, url: URL) { update(url) { $0.tagColors = colors } }
    /// 这些文件现在各有哪几种颜色标签（一次扫整个列表）
    func tagColors(for urls: [URL]) -> [URL: TagColorSet] {
        let want = Set(urls)
        var map: [URL: TagColorSet] = [:]
        for item in allItems where want.contains(item.url) { map[item.url] = item.tagColors }
        return map
    }

    /// 移动走的文件从列表里拿掉；当前这张被拿掉时停在原位置的下一张
    func remove(urls: Set<URL>) {
        let cur = current?.url
        let oldIndex = index
        items.removeAll { urls.contains($0.url) }
        unfiltered?.removeAll { urls.contains($0.url) }
        hidden.subtract(urls)
        if let cur, !urls.contains(cur) {
            index = items.firstIndex { $0.url == cur } ?? 0
        } else {
            index = min(oldIndex, max(items.count - 1, 0))
        }
    }

    @discardableResult
    func setMarkedOnly(_ on: Bool) -> Bool { setFilter(on ? .marked : nil) }

    /// 换筛选条件（nil 显示全部）。当前这张不符合就跳到它后面第一张符合的；一张都不符合返回 false、列表不变。
    /// 筛选中取消标记或改了星级的照片先留在列表里，下次切换时才拿掉，免得看着看着画面突然换了
    @discardableResult
    func setFilter(_ f: PhotoFilter?) -> Bool {
        let all = allItems
        if let f, !all.contains(where: { isVisible($0, f) }) { return false }
        let cur = current?.url
        filter = f
        rebuild(all, keeping: cur)
        return true
    }

    /// 换一组藏起来的文件；keeping 指定的文件要是被藏了，就停在它后面第一张显示的
    func setHidden(_ h: Set<URL>, keeping: URL? = nil) {
        let all = allItems
        let cur = keeping ?? current?.url
        hidden = h
        rebuild(all, keeping: cur)
    }

    /// 当前显示的 shown 换成藏起来的 other（同一对 JPG / RAW 互换），位置不变
    func swapVisible(_ shown: URL, for other: URL) {
        guard hidden.contains(other), let item = allItems.first(where: { $0.url == other }),
              let i = items.firstIndex(where: { $0.url == shown }) else { return }
        hidden.remove(other)
        hidden.insert(shown)
        items[i] = item
    }

    /// 列表里这些文件，加上它们藏起来的同名搭档（导出、移动时一起带走）
    func withHiddenPartners(_ urls: [URL]) -> [URL] {
        guard !hidden.isEmpty else { return urls }
        let keys = Set(urls.map { $0.deletingPathExtension().path.lowercased() })
        return urls + hidden.filter { keys.contains($0.deletingPathExtension().path.lowercased()) }.sorted { $0.path < $1.path }
    }

    private func isVisible(_ item: ImageItem, _ f: PhotoFilter?) -> Bool {
        !hidden.contains(item.url) && (f?.matches(item) ?? true)
    }

    private func rebuild(_ all: [ImageItem], keeping cur: URL?) {
        if filter == nil && hidden.isEmpty {
            items = all
            unfiltered = nil
        } else {
            unfiltered = all
            items = all.filter { isVisible($0, filter) }
            #if FLIPIC_PRO
            if case .content(let m) = filter { items = m.ranked(items) }
            #endif
        }
        guard let cur, let start = all.firstIndex(where: { $0.url == cur }) else {
            index = 0
            return
        }
        let order = Array(all[start...]) + Array(all[..<start])
        let target = order.first { isVisible($0, filter) }?.url
        index = target.flatMap { u in items.firstIndex { $0.url == u } } ?? 0
    }

    /// 按拍摄时间排序但还有文件没读 EXIF
    var needsCaptureDates: Bool {
        sortKey == .captureDate && items.contains { $0.captureDate == nil }
    }

    private static let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .tagNamesKey, .addedToDirectoryDateKey]
    /// exFAT / FAT / NTFS / 网络盘没有原生扩展属性与 addedDate，只取原生目录项里的修改时间/创建时间/大小，避免触发 AppleDouble (._*) 寻道
    private static let fastResourceKeys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]

    private static func enumerationKeys(for folderURL: URL) -> (keys: [URLResourceKey], skipTags: Bool) {
        if Volumes.skipsFinderTags(for: folderURL) { return (fastResourceKeys, true) }
        return (resourceKeys, false)
    }

    /// 传文件夹则列出其中全部图片；传文件则打开其所在文件夹并定位到该文件
    @discardableResult
    func open(url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        // 文件夹与目标文件统一用规整后的路径，否则 /private/tmp 与 /tmp 会被当成两个文件
        let std = url.standardizedFileURL
        let folderURL = isDir.boolValue ? std : std.deletingLastPathComponent()
        let target: URL? = isDir.boolValue ? nil : std
        // 同一个文件夹重新列（批量改名后）时，跟随访达下手动点的倒序留着
        let previous = self.folderURL == folderURL ? finderSort : nil
        self.folderURL = folderURL
        refreshFinderSort()
        if let previous, finderSort?.key == previous.key { finderSort = previous }

        // 列目录时一并取回时间、大小，并顺带收集现有 .xmp 旁车名（零额外磁盘探测）
        let (keys, skipTags) = Self.enumerationKeys(for: folderURL)
        let keySet = Set(keys)
        let allEntries = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var stems = Set<String>()
        var rawEntries: [URL] = []
        rawEntries.reserveCapacity(allEntries.count)
        for u in allEntries {
            let name = u.lastPathComponent
            if name.lowercased().hasSuffix(".xmp") {
                stems.insert(Rating.sidecarStem(for: u))
            } else if Self.isListable(name) {
                rawEntries.append(u)
            }
        }
        xmpStems = stems
        var prefetched: [URL: URLResourceValues] = [:]
        prefetched.reserveCapacity(rawEntries.count)
        var urls: [URL] = []
        urls.reserveCapacity(rawEntries.count)
        for raw in rawEntries {
            let canonical = folderURL.appendingPathComponent(raw.lastPathComponent)
            urls.append(canonical)
            if let v = try? raw.resourceValues(forKeys: keySet) { prefetched[canonical] = v }
        }
        if let target, !urls.contains(target) { urls.append(target) }
        urls = Video.dropLiveCompanions(urls)

        // 存储卡上的标记记在这台电脑里（CardMarks），列目录时一并并进来；原生支持标签的卷照常读访达标签
        let card = CardMarks.markedNames(inFolder: folderURL)
        items = urls.map { Self.makeItem($0, prefetched: prefetched[$0], keySet: keySet, skipTags: skipTags, card: card) }
        unfiltered = nil
        filter = nil
        hidden = []
        index = 0
        resort(keeping: target)
        return !items.isEmpty
    }

    /// 回到开始页：清空列表
    /// 列表里显示的文件：图片，加上系统能播的视频（设置里可以关）
    static func isListable(_ name: String) -> Bool {
        ImageLoader.isSupportedExtension(name) || (Video.enabled && Video.isVideoName(name))
    }

    private static func makeItem(_ u: URL, prefetched: URLResourceValues? = nil, keySet: Set<URLResourceKey>? = nil,
                                 skipTags: Bool = false, card: Set<String>? = nil) -> ImageItem {
        let v = prefetched ?? (try? u.resourceValues(forKeys: keySet ?? Set(resourceKeys)))
        let tags = skipTags ? nil : v?.tagNames
        return ImageItem(url: u, pixelSize: nil, modified: v?.contentModificationDate,
                         created: v?.creationDate, fileSize: v?.fileSize ?? 0,
                         marked: Marks.isMarked(tagNames: tags) || (card?.contains(CardMarks.normalized(u.lastPathComponent)) ?? false),
                         tagColors: FinderTags.colors(fromTagNames: tags), added: v?.addedToDirectoryDate)
    }

    /// 和磁盘对一遍：别处新放进来的照片按当前排序插进列表，当前这张不动。
    /// 不见了的文件（删掉、改名、移走）返回在 missing 里；removing 为 true 时才从列表拿掉。
    /// 有的软件存盘是先删再写，看到不见了先别急着拿，过一会儿再对一次
    func syncWithDisk(removing: Bool) -> (added: [URL], missing: Set<URL>) {
        guard let folderURL else { return ([], []) }
        // 列不出目录（桌面、文稿还没获准访问，App Store 版只拿到这一个文件的权限）时什么都不动：
        // 以前这里当成空目录，正在看的照片被认成「不见了」，0.8 秒后被拿掉，退回开始页
        let (keys, skipTags) = Self.enumerationKeys(for: folderURL)
        let keySet = Set(keys)
        guard let listed = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return ([], []) }
        var stems = Set<String>()
        var prefetched: [URL: URLResourceValues] = [:]
        var mapped: [URL] = []
        for raw in listed {
            let name = raw.lastPathComponent
            if name.lowercased().hasSuffix(".xmp") {
                stems.insert(Rating.sidecarStem(for: raw))
            } else if Self.isListable(name) {
                let canonical = folderURL.appendingPathComponent(name)
                mapped.append(canonical)
                if let v = try? raw.resourceValues(forKeys: keySet) { prefetched[canonical] = v }
            }
        }
        xmpStems = stems
        let onDisk = Set(Video.dropLiveCompanions(mapped))
        let known = Set(allItems.map(\.url))
        // 目录里没列出来、但按路径还在的（比如只拿到单个文件的权限）不算不见了
        let missing = known.subtracting(onDisk).filter { !FileManager.default.fileExists(atPath: $0.path) }
        let added = onDisk.subtracting(known).sorted { $0.path < $1.path }
        if removing, !missing.isEmpty { remove(urls: missing) }
        if !added.isEmpty {
            let cur = current?.url
            let card = CardMarks.markedNames(inFolder: folderURL)
            rebuild(allItems + added.map { Self.makeItem($0, prefetched: prefetched[$0], keySet: keySet, skipTags: skipTags, card: card) }, keeping: cur)
            resort(keeping: cur ?? current?.url)
        }
        return (added, missing)
    }

    func clear() {
        folderURL = nil
        items = []
        unfiltered = nil
        filter = nil
        hidden = []
        index = 0
    }

    /// 按当前排序方式重排，keeping 指定的文件保持为当前项
    func resort(keeping url: URL?) {
        let key = sortKey
        let desc = key.largestFirst != sortReversed
        func byName(_ a: ImageItem, _ b: ImageItem) -> Bool {
            a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        func ordered<T: Comparable>(_ x: T, _ y: T, _ a: ImageItem, _ b: ImageItem) -> Bool {
            x == y ? byName(a, b) : x < y
        }
        func less(_ a: ImageItem, _ b: ImageItem) -> Bool {
            switch key {
            case .name: return byName(a, b)
            case .captureDate:
                return ordered(a.captureDate ?? a.modified ?? .distantPast,
                               b.captureDate ?? b.modified ?? .distantPast, a, b)
            case .modified: return ordered(a.modified ?? .distantPast, b.modified ?? .distantPast, a, b)
            case .created: return ordered(a.created ?? .distantPast, b.created ?? .distantPast, a, b)
            case .size: return ordered(a.fileSize, b.fileSize, a, b)
            case .added: return ordered(a.added ?? a.created ?? .distantPast, b.added ?? b.created ?? .distantPast, a, b)
            }
        }
        items.sort { desc ? less($1, $0) : less($0, $1) }
        unfiltered?.sort { desc ? less($1, $0) : less($0, $1) }
        #if FLIPIC_PRO
        if case .content(let m) = filter { items = m.ranked(items) }
        #endif
        index = url.flatMap { u in items.firstIndex { $0.url == u } } ?? 0
    }

    /// 后台读拍摄时间用：返回尚未读取的文件
    func urlsMissingCaptureDate() -> [URL] {
        (unfiltered ?? items).filter { $0.captureDate == nil }.map(\.url)
    }

    func setCaptureDates(_ dates: [URL: Date]) {
        for i in items.indices {
            if let d = dates[items[i].url] { items[i].captureDate = d }
        }
        if var all = unfiltered {
            for i in all.indices {
                if let d = dates[all[i].url] { all[i].captureDate = d }
            }
            unfiltered = all
        }
    }

    /// 只读文件头的 EXIF 拍摄时间，没有则用修改时间
    static func readCaptureDate(url: URL, fallback: Date?) -> Date {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let raw = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String)
                ?? (exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime as String] as? String)
            if let raw, let d = exifDateFormatter.date(from: raw) { return d }
        }
        return fallback ?? .distantPast
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func go(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }

    func jump(to i: Int) {
        guard items.indices.contains(i) else { return }
        index = i
    }

    func url(atOffset offset: Int) -> URL? {
        guard !items.isEmpty else { return nil }
        let i = (index + offset + items.count) % items.count
        return items[i].url
    }

    func setCurrentPixelSize(_ size: CGSize) {
        guard items.indices.contains(index) else { return }
        items[index].pixelSize = size
    }

    /// 当前文件已重命名后更新列表中的路径（不重扫目录）
    func renameCurrent(to newName: String) {
        guard items.indices.contains(index) else { return }
        let old = items[index].url
        update(old) { item in
            item = ImageItem(url: item.url.deletingLastPathComponent().appendingPathComponent(newName),
                             pixelSize: item.pixelSize, modified: item.modified, created: item.created,
                             fileSize: item.fileSize, captureDate: item.captureDate, marked: item.marked, rating: item.rating,
                             tagColors: item.tagColors, added: item.added)
        }
    }

    /// 当前项已移入废纸篓后从列表移除，返回是否还有剩余
    @discardableResult
    func removeCurrent() -> Bool {
        guard items.indices.contains(index) else { return false }
        let url = items[index].url
        items.remove(at: index)
        unfiltered?.removeAll { $0.url == url }
        index = min(index, max(items.count - 1, 0))
        return !items.isEmpty
    }
}

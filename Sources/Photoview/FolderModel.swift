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
}

/// 「只看」筛选：已标记，或某个星级以上
enum PhotoFilter: Equatable {
    case marked
    case minRating(Int)

    func matches(_ item: ImageItem) -> Bool {
        switch self {
        case .marked: return item.marked
        case .minRating(let n): return (item.rating ?? 0) >= n
        }
    }
}

enum SortKey: Int, CaseIterable {
    case name, captureDate, modified, created, size

    /// 各排序方式的自然方向（与 Finder 一致）：名称 A→Z，时间新的在前，大小大的在前
    var largestFirst: Bool { self != .name }

    var title: String {
        switch self {
        case .name: return L10n.t("sort.name", "文件名")
        case .captureDate: return L10n.t("sort.captureDate", "拍摄时间")
        case .modified: return L10n.t("sort.modified", "修改时间")
        case .created: return L10n.t("sort.created", "创建时间")
        case .size: return L10n.t("sort.size", "文件大小")
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

    /// 排序方式与方向，跨启动记住；sortReversed 是在该方式自然方向上反过来
    var sortKey: SortKey {
        get { SortKey(rawValue: UserDefaults.standard.integer(forKey: "sortKey")) ?? .name }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sortKey") }
    }
    var sortReversed: Bool {
        get { UserDefaults.standard.bool(forKey: "sortReversed") }
        set { UserDefaults.standard.set(newValue, forKey: "sortReversed") }
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

    func setMarked(_ on: Bool, url: URL) { update(url) { $0.marked = on } }
    func setRating(_ rating: Int?, url: URL) { update(url) { $0.rating = rating } }

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
        let keys = Set(urls.map { $0.deletingPathExtension().path })
        return urls + hidden.filter { keys.contains($0.deletingPathExtension().path) }.sorted { $0.path < $1.path }
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

    private static let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .tagNamesKey]

    /// 传文件夹则列出其中全部图片；传文件则打开其所在文件夹并定位到该文件
    @discardableResult
    func open(url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        // 文件夹与目标文件统一用规整后的路径，否则 /private/tmp 与 /tmp 会被当成两个文件
        let std = url.standardizedFileURL
        let folderURL = isDir.boolValue ? std : std.deletingLastPathComponent()
        let target: URL? = isDir.boolValue ? nil : std

        // 列目录时一并取回时间与大小，排序不再逐个 stat
        var urls = ((try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: Self.resourceKeys, options: [.skipsHiddenFiles])) ?? [])
            .filter { ImageLoader.isSupportedExtension($0.lastPathComponent) }
            .map { folderURL.appendingPathComponent($0.lastPathComponent) }
        if let target, !urls.contains(target) { urls.append(target) }

        items = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(Self.resourceKeys))
            return ImageItem(url: u, pixelSize: nil, modified: v?.contentModificationDate,
                             created: v?.creationDate, fileSize: v?.fileSize ?? 0,
                             marked: Marks.isMarked(tagNames: v?.tagNames))
        }
        unfiltered = nil
        filter = nil
        hidden = []
        index = 0
        resort(keeping: target)
        return !items.isEmpty
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
            }
        }
        items.sort { desc ? less($1, $0) : less($0, $1) }
        unfiltered?.sort { desc ? less($1, $0) : less($0, $1) }
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
                             fileSize: item.fileSize, captureDate: item.captureDate, marked: item.marked, rating: item.rating)
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

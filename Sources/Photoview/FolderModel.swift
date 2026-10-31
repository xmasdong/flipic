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

    /// 按拍摄时间排序但还有文件没读 EXIF
    var needsCaptureDates: Bool {
        sortKey == .captureDate && items.contains { $0.captureDate == nil }
    }

    private static let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]

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
                             created: v?.creationDate, fileSize: v?.fileSize ?? 0)
        }
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
        index = url.flatMap { u in items.firstIndex { $0.url == u } } ?? 0
    }

    /// 后台读拍摄时间用：返回尚未读取的文件
    func urlsMissingCaptureDate() -> [URL] {
        items.filter { $0.captureDate == nil }.map(\.url)
    }

    func setCaptureDates(_ dates: [URL: Date]) {
        for i in items.indices {
            if let d = dates[items[i].url] { items[i].captureDate = d }
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
        var item = items[index]
        item = ImageItem(url: item.url.deletingLastPathComponent().appendingPathComponent(newName),
                         pixelSize: item.pixelSize, modified: item.modified, created: item.created,
                         fileSize: item.fileSize, captureDate: item.captureDate)
        items[index] = item
    }

    /// 当前项已移入废纸篓后从列表移除，返回是否还有剩余
    @discardableResult
    func removeCurrent() -> Bool {
        guard items.indices.contains(index) else { return false }
        items.remove(at: index)
        index = min(index, max(items.count - 1, 0))
        return !items.isEmpty
    }
}

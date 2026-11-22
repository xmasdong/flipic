import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 外接硬盘 / 存储卡 / 网络卷的本机 SSD 持久化预览缓存（~/Library/Caches/<BundleID>/ExtDiskCache/）。
///
/// 思路与 Photo Mechanic / Adobe Bridge / Lightroom 智能预览一致，但零数据库依赖：
/// 1. 仅对慢存储（Volumes.isSlowStorage == true）生效，绝不重复缓存 Mac 内置 SSD 上的本地照片。
/// 2. 缓存键 = SHA256(卷稳定标识 | 相对路径 | 文件大小 | 修改时间秒 | 档位)。
///    - 拔盘重插、甚至挂载点改名（/Volumes/Disk → /Volumes/Disk 1）依然命中；
///    - 原图一旦被后期软件修改（大小或 mtime 变化）自动失效，绝不串图；
///    - FolderModel 列目录时已通过 getattrlistbulk 拿到大小与 mtime，通过 register(items:) 注入后，查缓存键 0 次额外 stat() 外接盘。
/// 3. 单个 .fpc 缓存文件采用极简 20 字节二进制头 + JPEG 字节：
///    [0..3]  Magic "FPC1"
///    [4..7]  origW (Float32 LE) — 原图转正后宽
///    [8..11] origH (Float32 LE) — 原图转正后高
///    [12..15] encodedLongEdge (UInt32 LE) — 本缓存图长边像素
///    [16..19] flags (UInt32 LE, 保留)
///    [20..]  JPEG 数据（Display P3 / sRGB）
///    命中本机 SSD 缓存时一次顺序读同时恢复 ImageInfo 与清晰预览，外接盘 0 I/O、0 RAW 耗时解码。
/// 4. 异步后台原子写盘，500 MB LRU 自动淘汰（超限压回 400 MB）；直接版与 App Store 沙盒版通用。
final class ExtDiskCache {
    enum Kind: String {
        case preview = "p"
        case thumb = "t"
    }

    struct FileStamp: Equatable {
        let size: Int64
        let mtime: Int64
    }

    struct Hit {
        let image: CGImage
        let info: ImageInfo
        let encodedLongEdge: Int
    }

    static var shared = ExtDiskCache(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Flipic", isDirectory: true)
            .appendingPathComponent("ExtDiskCache", isDirectory: true)
    }

    /// 设置里的开关（默认开启）
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "extDiskCacheEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "extDiskCacheEnabled") }
    }

    /// 缓存预览图的最大长边：足够 2K/4K/5K 窗口适应屏幕清晰看图，单张约 150–350 KB；放大到 100% 仍读原图
    static let maxPreviewEdge: CGFloat = 2560
    static let defaultMaxBytes: Int64 = 500 << 20    // 500 MB
    private static let magic: [UInt8] = [0x46, 0x50, 0x43, 0x31]   // "FPC1"
    private static let headerBytes = 20

    let directory: URL
    let maxBytes: Int64
    private let trimTargetBytes: Int64

    private let lock = NSLock()
    /// 目录枚举阶段已拿到的 (size, mtime)，避免查缓存键时再去外接盘 stat()
    private var stamps: [URL: FileStamp] = [:]
    /// 正在后台写盘的键（去重 & 限制积压）
    private var pendingWrites = Set<String>()
    /// 上次 touch mtime 的时间（同一键 1 小时内不重复 touch，减少 SSD 写放大）
    private var touchedAt: [String: TimeInterval] = [:]
    private var bytesWrittenSinceTrim: Int64 = 0

    /// 低优先级串行写队列：后台落盘绝不抢前台看图与翻页的 CPU/IO
    private let writeQueue = DispatchQueue(label: "flipic.extcache.write", qos: .background)
    /// 测试统计（命中次数与写盘次数）
    private(set) var debugHits = 0
    private(set) var debugWrites = 0

    init(directory: URL, maxBytes: Int64 = ExtDiskCache.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.trimTargetBytes = max(1, maxBytes * 4 / 5)
    }

    /// 目录列完后批量登记文件指纹（FolderModel 已通过 getattrlistbulk 拿到，零额外外接盘 syscall）
    func register(items: [ImageItem]) {
        guard !items.isEmpty else { return }
        lock.lock()
        if stamps.count > 20_000 { stamps.removeAll(keepingCapacity: true) }
        for item in items {
            let mt = Int64((item.modified?.timeIntervalSince1970 ?? 0).rounded())
            stamps[item.url.standardizedFileURL] = FileStamp(size: Int64(item.fileSize), mtime: mt)
        }
        lock.unlock()
    }

    /// 文件在软件内被旋转/外部改写后，丢弃其缓存指纹与旧盘上条目
    func invalidate(url: URL) {
        let std = url.standardizedFileURL
        lock.lock()
        let oldStamp = stamps.removeValue(forKey: std)
        lock.unlock()
        guard let oldStamp, let vol = Volumes.cachedInfo(for: std) else { return }
        let pKey = cacheKey(url: std, vol: vol, stamp: oldStamp, kind: .preview)
        let tKey = cacheKey(url: std, vol: vol, stamp: oldStamp, kind: .thumb)
        writeQueue.async { [directory] in
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(pKey).fpc"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(tKey).fpc"))
        }
    }

    // MARK: - 读缓存（本机 NVMe SSD 顺序读，通常 < 1–3 ms）

    /// 只读 20 字节二进制头恢复原图尺寸，命中后 info(for:) 连外接盘文件头都不用打开
    func readInfo(for url: URL) -> ImageInfo? {
        guard Self.enabled, Volumes.isSlowStorage(url),
              let path = fileURL(for: url, kind: .preview) ?? fileURL(for: url, kind: .thumb),
              let fh = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? fh.close() }
        guard let hdr = try? fh.read(upToCount: Self.headerBytes),
              let parsed = parseHeader(hdr) else { return nil }
        return ImageInfo(pixelSize: parsed.origSize, isAnimated: parsed.isAnimated)
    }

    /// 从本机 SSD 读外接盘的预览图或缩略图；minLongEdge 要求满足清晰度（如果原图本身比 minLongEdge 小，等于原图尺寸也算命中）
    func load(for url: URL, kind: Kind, minLongEdge: CGFloat) -> Hit? {
        guard Self.enabled, Volumes.isSlowStorage(url),
              let key = keyFor(url: url, kind: kind) else { return nil }
        let file = directory.appendingPathComponent("\(key).fpc")
        guard let data = try? Data(contentsOf: file), data.count > Self.headerBytes,
              let hdr = parseHeader(data) else { return nil }
        let origLong = max(hdr.origSize.width, hdr.origSize.height)
        let need = min(minLongEdge, origLong > 0 ? origLong : minLongEdge)
        // 缓存图比当前窗口需要的明显小太多（例如 1080p 换到 5K 屏），不勉强用，回源重解更清的并覆盖
        guard CGFloat(hdr.encodedLongEdge) >= need * 0.85 else { return nil }
        let jpegSlice = data.subdata(in: Self.headerBytes..<data.count)
        guard let src = CGImageSourceCreateWithData(jpegSlice as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        touchForLRU(key: key, file: file)
        lock.lock(); debugHits += 1; lock.unlock()
        return Hit(image: img, info: ImageInfo(pixelSize: hdr.origSize, isAnimated: hdr.isAnimated),
                   encodedLongEdge: hdr.encodedLongEdge)
    }

    // MARK: - 写缓存（异步后台队列，绝不阻塞看图）

    func store(_ image: CGImage, origSize: CGSize, for url: URL, kind: Kind) {
        guard Self.enabled, Volumes.isSlowStorage(url), !Video.isVideo(url),
              !ImageLoader.hasAlphaChannel(image),
              !(ImageLoader.isHDR(image) && ImageLoader.hdrActive),
              let key = keyFor(url: url, kind: kind) else { return }

        lock.lock()
        // 已经排着写、或者队列积压太多（连翻几十张）时跳过，等用户停下来自然会写入正在看的图
        if pendingWrites.contains(key) || pendingWrites.count >= 24 {
            lock.unlock()
            return
        }
        pendingWrites.insert(key)
        lock.unlock()

        let quality: Double = kind == .preview ? 0.86 : 0.80
        let capEdge: CGFloat = kind == .preview ? Self.maxPreviewEdge : max(FilmstripView.thumbPixel, 240)
        writeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingWrites.remove(key)
                self.lock.unlock()
            }
            let targetImg = Self.downscaleIfNeeded(image, maxEdge: capEdge)
            let encodedLong = max(targetImg.width, targetImg.height)
            let jpeg = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, targetImg, [
                kCGImageDestinationLossyCompressionQuality as String: quality,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(dest), jpeg.length > 0 else { return }

            var payload = Data(capacity: Self.headerBytes + jpeg.length)
            payload.append(contentsOf: Self.magic)
            Self.appendU32LE(&payload, Float(origSize.width).bitPattern)
            Self.appendU32LE(&payload, Float(origSize.height).bitPattern)
            Self.appendU32LE(&payload, UInt32(max(1, encodedLong)))
            Self.appendU32LE(&payload, 0)
            payload.append(jpeg as Data)

            let fm = FileManager.default
            try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let dst = self.directory.appendingPathComponent("\(key).fpc")
            let tmp = self.directory.appendingPathComponent(".\(key)-\(UUID().uuidString).tmp")
            do {
                try payload.write(to: tmp)
                if fm.fileExists(atPath: dst.path) { _ = try? fm.removeItem(at: dst) }
                try fm.moveItem(at: tmp, to: dst)
            } catch {
                try? fm.removeItem(at: tmp)
                return
            }

            var shouldTrim = false
            self.lock.lock()
            self.debugWrites += 1
            self.bytesWrittenSinceTrim += Int64(payload.count)
            if self.bytesWrittenSinceTrim >= min(16 << 20, max(1, self.maxBytes / 4)) {
                self.bytesWrittenSinceTrim = 0
                shouldTrim = true
            }
            self.lock.unlock()
            if shouldTrim { self.trimLRU() }
        }
    }

    /// 启动后后台延迟清一次（如果有历史超限残留）
    func scheduleStartupTrim() {
        writeQueue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.trimLRU() }
    }

    /// 供测试等后台写盘全部落地
    func debugFlushWrites() {
        writeQueue.sync {}
    }

    func debugResetCounters() {
        lock.lock(); debugHits = 0; debugWrites = 0; lock.unlock()
    }

    // MARK: - 管理与 LRU 淘汰

    func diskUsageBytes() -> Int64 {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for u in urls where u.pathExtension == "fpc" {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clearAll(completion: (() -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            if let urls = try? fm.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
                for u in urls { try? fm.removeItem(at: u) }
            }
            self.lock.lock()
            self.touchedAt.removeAll()
            self.bytesWrittenSinceTrim = 0
            self.lock.unlock()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// LRU：超过 maxBytes 时，按最后访问/修改时间删除最旧条目，压回 trimTargetBytes
    func trimLRU() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, size: Int64, mtime: TimeInterval)] = []
        var total: Int64 = 0
        for u in urls where u.pathExtension == "fpc" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sz = Int64(v?.fileSize ?? 0)
            let mt = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries.append((u, sz, mt))
            total += sz
        }
        guard total > maxBytes else { return }
        entries.sort { $0.mtime < $1.mtime }   // 最久没用的排最前
        for e in entries {
            guard total > trimTargetBytes else { break }
            try? fm.removeItem(at: e.url)
            total -= e.size
        }
    }

    // MARK: - 内部辅助

    private func fileURL(for url: URL, kind: Kind) -> URL? {
        guard let key = keyFor(url: url, kind: kind) else { return nil }
        let u = directory.appendingPathComponent("\(key).fpc")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func keyFor(url: URL, kind: Kind) -> String? {
        let std = url.standardizedFileURL
        guard let vol = Volumes.cachedInfo(for: std), let stamp = stampFor(std) else { return nil }
        return cacheKey(url: std, vol: vol, stamp: stamp, kind: kind)
    }

    private func stampFor(_ std: URL) -> FileStamp? {
        lock.lock()
        if let hit = stamps[std] { lock.unlock(); return hit }
        lock.unlock()
        guard let v = try? std.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let sz = v.fileSize else { return nil }
        let s = FileStamp(size: Int64(sz), mtime: Int64((v.contentModificationDate?.timeIntervalSince1970 ?? 0).rounded()))
        lock.lock(); stamps[std] = s; lock.unlock()
        return s
    }

    private func cacheKey(url std: URL, vol: VolumeInfo, stamp: FileStamp, kind: Kind) -> String {
        let rootPath = vol.root.standardizedFileURL.path
        var rel = std.path
        if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)) }
        // exFAT / FAT / NTFS / HFS+ 等常见外接卷大小写不敏感，统一小写保证稳定命中
        let raw = "\(vol.key)|\(rel.lowercased())|\(stamp.size)|\(stamp.mtime)|\(kind.rawValue)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func touchForLRU(key: String, file: URL) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let last = touchedAt[key] ?? 0
        if now - last < 3600 { lock.unlock(); return }
        touchedAt[key] = now
        lock.unlock()
        writeQueue.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
    }

    private func parseHeader(_ data: Data) -> (origSize: CGSize, encodedLongEdge: Int, isAnimated: Bool)? {
        guard data.count >= Self.headerBytes else { return nil }
        return data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            guard b[0] == Self.magic[0], b[1] == Self.magic[1], b[2] == Self.magic[2], b[3] == Self.magic[3] else { return nil }
            func u32(_ off: Int) -> UInt32 {
                UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
            }
            let w = CGFloat(Float(bitPattern: u32(4)))
            let h = CGFloat(Float(bitPattern: u32(8)))
            let long = Int(u32(12))
            let flags = u32(16)
            guard w > 0, h > 0, w.isFinite, h.isFinite, long > 0 else { return nil }
            return (CGSize(width: w, height: h), long, (flags & 1) != 0)
        }
    }

    private static func appendU32LE(_ d: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func downscaleIfNeeded(_ img: CGImage, maxEdge: CGFloat) -> CGImage {
        let long = CGFloat(max(img.width, img.height))
        guard long > maxEdge else { return img }
        let k = maxEdge / long
        let w = max(1, Int((CGFloat(img.width) * k).rounded()))
        let h = max(1, Int((CGFloat(img.height) * k).rounded()))
        let space = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }
}

import Foundation
import CoreServices

/// 盯着正在看的文件夹：Photoshop 之类的软件存了里面的照片，回调一次（0.3 秒内连续写入合成一次）
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var watching: URL?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func watch(_ folder: URL?) {
        guard folder?.standardizedFileURL != watching else { return }
        stop()
        guard let folder else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
        watching = folder.standardizedFileURL
    }

    func stop() {
        watching = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    // MARK: - Flipic 自己写的文件

    /// 打星写进 JPEG/HEIC、旋转写回原图都会改文件：记下写完时的修改时间和大小，
    /// 文件夹有变化时据此认出是自己写的，不当成别的软件改过重新解码
    private static var ownWrites: [URL: Stamp] = [:]
    private static let lock = NSLock()

    struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    /// 读磁盘上的修改时间和大小；新建 URL 读，免得拿到 URL 自己缓存的旧值
    static func stamp(of url: URL) -> Stamp? {
        let v = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let m = v?.contentModificationDate else { return nil }
        return Stamp(modified: m, size: v?.fileSize ?? 0)
    }

    static func noteOwnWrite(_ url: URL) {
        guard let s = stamp(of: url) else { return }
        lock.lock(); ownWrites[url.standardizedFileURL] = s; lock.unlock()
    }

    static func isOwnWrite(_ url: URL, _ s: Stamp) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ownWrites[url.standardizedFileURL] == s
    }
}

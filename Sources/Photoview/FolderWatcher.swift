import AppKit
import CoreServices

/// 盯着正在看的文件夹：Photoshop 之类的软件存了里面的照片，回调一次（0.3 秒内连续写入合成一次）
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var watching: URL?
    private let onChange: () -> Void
    /// 一批变化全是自己写的时回调（只带真正的照片文件，临时文件不算）
    var onOwnWrites: (([URL]) -> Void)?

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func watch(_ folder: URL?) {
        guard folder?.standardizedFileURL != watching else { return }
        stop()
        guard let folder else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            // 这一批变化全是 Flipic 自己写的（保存裁剪时的临时文件、换上去的新文件）：不用再扫一遍文件夹。
            // 几千张照片的文件夹里，扫一遍要卡主线程一百多毫秒，一次保存会触发两次
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // 文件夹里记的修改时间和大小还是要跟上（之后别的软件把文件改回老样子才认得出来），只更新这几个文件
            if count > 0, let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String], let own = FolderWatcher.ownWriteURLs(paths) {
                if !own.isEmpty { watcher.onOwnWrites?(own) }
                return
            }
            watcher.onChange()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
                                                                   | kFSEventStreamCreateFlagFileEvents)) else { return }
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

    /// 保存裁剪、拉直时先写的临时文件（Straighten.tempURL）
    static let tempPrefix = ".flipic-rotate-"

    /// 这批文件事件都是自己造成的（临时文件，或者已经记下的自己写的文件，修改时间和大小对得上）时，
    /// 返回其中真正的照片文件；有别的变化就返回 nil
    static func ownWriteURLs(_ paths: [String]) -> [URL]? {
        guard !paths.isEmpty else { return nil }
        var files: [URL] = []
        for p in paths {
            // replaceItemAt 还会再造一个叫 ".<临时文件名>-xxxx" 的中转文件，所以是「包含」不是「开头」
            if (p as NSString).lastPathComponent.contains(tempPrefix) { continue }
            let url = URL(fileURLWithPath: p)
            guard let s = stamp(of: url), isOwnWrite(url, s) else { return nil }
            if !files.contains(url) { files.append(url) }
        }
        return files
    }

    static func isOwnWrite(_ url: URL, _ s: Stamp) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ownWrites[url.standardizedFileURL] == s
    }
}

/// 最近打开过的文件夹：记在系统的「最近使用的项目」里（访达、Dock 菜单也认），开始页和「文件 › 最近打开」都从这里读
enum Recents {
    static let didChange = Notification.Name("FlipicRecentsDidChange")

    /// 设置 › 通用 › 最近打开。关掉后开始页和「文件 › 最近打开」都不列，也不再往里记（开会投屏时不露出别的客户的文件夹）。
    /// 关掉不删已有记录，再打开时还在；要删用「文件 › 最近打开 › 清除菜单」
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showRecents") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "showRecents")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func note(_ folder: URL) {
        guard enabled else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(folder)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 还在的文件夹，最近的在前，最多 10 个
    static var folders: [URL] {
        guard enabled else { return [] }
        var seen = Set<String>()
        return NSDocumentController.shared.recentDocumentURLs.filter { u in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
                  seen.insert(u.standardizedFileURL.path).inserted else { return false }
            return true
        }.prefix(10).map { $0 }
    }
}

import Foundation

/// 文件所在的卷（磁盘、存储卡、磁盘映像）的信息：只读吗、可移除吗、什么文件系统、卷标识。
/// 批量转换用它决定默认输出位置，挑片标记用它判断要不要往卡里写（见 CardMarks.swift）
struct VolumeInfo {
    var root: URL
    var name: String
    var uuid: String?
    var capacity: Int64
    var readOnly: Bool
    var removable: Bool
    var ejectable: Bool
    var internalDisk: Bool
    var local: Bool
    /// statfs 的文件系统名：apfs、hfs、msdos、exfat、smbfs…
    var fsType: String

    /// 跨挂载点稳定的卷标识：有 UUID 用 UUID；FAT 卡常常没有，退回「卷名 + 容量」
    var key: String {
        if let uuid, !uuid.isEmpty { return "uuid:" + uuid }
        return "name:\(name)|\(capacity)"
    }
}

enum Volumes {
    static func info(for url: URL) -> VolumeInfo? {
        let path = url.standardizedFileURL.path
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let root = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let fsType = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let rootURL = URL(fileURLWithPath: root)
        // 卷信息向文件夹本身要（对这个卷上的任何路径都一样）：沙盒版只放行用户授权过的文件夹，不一定能直接读卷根
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        let keys: Set<URLResourceKey> = [.volumeIsReadOnlyKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeIsInternalKey, .volumeIsLocalKey, .volumeUUIDStringKey,
                                         .volumeNameKey, .volumeTotalCapacityKey]
        let v = try? probe.resourceValues(forKeys: keys)
        // 只读还要看 statfs：挂载标志比资源键更直接
        let ro = (v?.volumeIsReadOnly ?? false) || (fs.f_flags & UInt32(MNT_RDONLY)) != 0
        return VolumeInfo(root: rootURL, name: v?.volumeName ?? rootURL.lastPathComponent,
                          uuid: v?.volumeUUIDString, capacity: Int64(v?.volumeTotalCapacity ?? 0),
                          readOnly: ro, removable: v?.volumeIsRemovable ?? false,
                          ejectable: v?.volumeIsEjectable ?? false,
                          internalDisk: v?.volumeIsInternal ?? true, local: v?.volumeIsLocal ?? true,
                          fsType: fsType)
    }

    /// 这个卷上不该往文件里写挑片标记（访达标签）：
    /// 1. 只读的卷（锁了写保护的卡、只读挂载的磁盘映像、光盘、NTFS）——写不进去；
    /// 2. FAT / exFAT（相机存储卡几乎都是这两种）——它们没有原生的扩展属性，系统用旁边的 `._文件名` 文件（AppleDouble）模拟，
    ///    每打一个标记卡里就多一个 4 KB 的隐藏文件，相机里、Windows 上都看得见。
    /// 不看「是不是可移除」：用 APFS / HFS+ 格式化的外接固态硬盘是工作盘，访达标签写得很好，照旧写；
    /// 反过来，一块 exFAT 的外接盘也会留 `._` 文件，不管它是不是可移除，所以按文件系统判断。
    /// 网络卷（smb / nfs）这一版不动，仍是原来的做法
    static func keepsMarksOffVolume(_ i: VolumeInfo) -> Bool {
        i.readOnly || ["msdos", "exfat"].contains(i.fsType.lowercased())
    }

    /// exFAT / FAT / NTFS / 网络卷等没有原生扩展属性的卷：列目录时绝不请求 .tagNamesKey，
    /// 避免在 macOS 用户态 ExFAT 驱动上触发成千上万次 AppleDouble (._*) 目录查找与机械盘寻道
    static func skipsFinderTags(for url: URL) -> Bool {
        guard let vol = cachedInfo(for: url) else { return false }
        let fs = vol.fsType.lowercased()
        return keepsMarksOffVolume(vol) || !vol.local || (!vol.internalDisk && fs != "apfs" && fs != "hfs")
    }

    /// 按卷缓存的完整卷信息（statfs 拿挂载点和 fsid 当键，一次系统调用），任何线程都能调；
    /// 给 isSlowStorage 和 ExtDiskCache 共用，避免对文件夹里每张图都重复查 URLResourceValues
    static func cachedInfo(for url: URL) -> VolumeInfo? {
        var fs = statfs()
        guard statfs(url.standardizedFileURL.path, &fs) == 0 else { return nil }
        let root = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let key = "\(root)|\(fs.f_fsid.val.0)|\(fs.f_fsid.val.1)"
        slowLock.lock()
        if let hit = infoCache[key] { slowLock.unlock(); return hit }
        slowLock.unlock()
        guard let built = info(for: url) else { return nil }
        slowLock.lock(); infoCache[key] = built; slowLock.unlock()
        return built
    }

    /// 慢存储：外接盘（USB 机械硬盘、读卡器）、可移除 / 可推出的盘、网络卷。
    /// 这些盘随机读贵（机械盘每次寻道约 10ms，USB 带宽也小），后台分析要少开几路、按目录顺序读。
    /// 环境变量 FLIPIC_SLOW_STORAGE=1 / 0 或测试钩子 debugForceSlow 可强制覆盖
    static var debugForceSlow: Bool?
    static func isSlowStorage(_ url: URL) -> Bool {
        if let forced = debugForceSlow ?? slowOverride { return forced }
        return cachedInfo(for: url).map { !$0.internalDisk || $0.removable || $0.ejectable || !$0.local } ?? false
    }

    private static let slowOverride: Bool? = {
        switch ProcessInfo.processInfo.environment["FLIPIC_SLOW_STORAGE"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }()
    private static let slowLock = NSLock()
    private static var infoCache: [String: VolumeInfo] = [:]

    /// 只读，或者是可移除 / 可推出的盘：批量转换默认不往这里写
    static func isReadOnlyOrRemovable(_ url: URL) -> Bool {
        guard let i = info(for: url) else { return false }
        return i.readOnly || i.removable || i.ejectable
    }
}

/// 批量读文件与慢盘单车道 I/O 调度器：
/// - 内置盘（APFS SSD）照旧多核并发拉满；
/// - 外接慢盘 / ExFAT 机械盘 / 网络卷按卷严格单车道顺序读（每块盘同时最多 1 个读盘任务，绝不让多线程抢磁头），
///   按优先级排程：当前正在看的大图（interactive）永远插队最先执行 > 可见缩略图（visible）> 顺序预读（prefetch）> 后台星级/EXIF/清理（background）。
enum DiskIO {
    enum Priority: Int, Comparable {
        case background = 0
        case prefetch = 1
        case visible = 2
        case interactive = 3
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func width(for url: URL?) -> Int {
        guard let url, Volumes.isSlowStorage(url) else { return 0 }
        // 机械盘只要超过 1 路并发就会来回抢磁头，吞吐从 120 MB/s 掉到 5–10 MB/s；严格单路顺序读最快
        return 1
    }

    /// width <= 0 或不小于 n：和 concurrentPerform(iterations: n) 一样；否则 width 路，每路一段连续的下标
    static func forEach(_ n: Int, width: Int, _ body: (Int) -> Void) {
        guard n > 0 else { return }
        guard width > 0, width < n else { DispatchQueue.concurrentPerform(iterations: n, execute: body); return }
        if width == 1 {
            for i in 0..<n { body(i) }
            return
        }
        let per = (n + width - 1) / width
        DispatchQueue.concurrentPerform(iterations: width) { lane in
            for i in lane * per..<min(n, (lane + 1) * per) { body(i) }
        }
    }

    /// 按 urls 里第一个文件所在的卷决定并发
    static func forEach(_ urls: [URL], _ body: (Int) -> Void) {
        forEach(urls.count, width: width(for: urls.first), body)
    }

    /// 按卷串行执行一段慢盘 I/O（支持优先级插队与取消跳过）；内置快盘直接原地执行不排队
    @discardableResult
    static func run<T>(for url: URL, priority: Priority, isCancelled: (() -> Bool)? = nil, _ work: () -> T?) -> T? {
        if isCancelled?() == true { return nil }
        guard Volumes.isSlowStorage(url) else { return work() }
        let key = Volumes.cachedInfo(for: url)?.key ?? "slow-default"
        return SlowVolumeScheduler.shared.perform(volumeKey: key, priority: priority, isCancelled: isCancelled, work)
    }

    /// 开启内核顺序预读（F_RDAHEAD）并以大块（1 MB）一次性顺序读入内存，
    /// 绕开 macOS 用户态 ExFAT 上 ImageIO 几十次 4KB–64KB 碎片小读的 IPC 往返惩罚
    static func readFileData(_ url: URL, maxBytes: Int? = nil) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        _ = Darwin.fcntl(fd, F_RDAHEAD, 1)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let fileSize = Int(st.st_size)
        let target = maxBytes.map { min($0, fileSize) } ?? fileSize
        guard target > 0 else { return nil }
        var data = Data(count: target)
        let got = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < target {
                let want = min(1 << 20, target - offset)
                let n = Darwin.read(fd, base + offset, want)
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
        guard got > 0 else { return nil }
        if got < target { data.count = got }
        return data
    }

    /// 从指定偏移量起大块顺序读最多 maxBytes（RAW 内嵌 JPEG 在 4 MB 之后时使用）
    static func readFileSlice(_ url: URL, offset: Int, maxBytes: Int) -> Data? {
        guard offset >= 0, maxBytes > 0 else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        _ = Darwin.fcntl(fd, F_RDAHEAD, 1)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        let fileSize = Int(st.st_size)
        guard offset < fileSize else { return nil }
        let target = min(maxBytes, fileSize - offset)
        var data = Data(count: target)
        let got = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var done = 0
            while done < target {
                let want = min(1 << 20, target - done)
                let n = Darwin.pread(fd, base + done, want, off_t(offset + done))
                if n <= 0 { break }
                done += n
            }
            return done
        }
        guard got > 0 else { return nil }
        if got < target { data.count = got }
        return data
    }

    /// 测试统计：慢盘调度器峰值并发数（应始终 ≤ 1）与调度总次数
    static var debugSlowMaxConcurrent: Int { SlowVolumeScheduler.shared.debugMaxConcurrent }
    static var debugSlowScheduled: Int { SlowVolumeScheduler.shared.debugTotalScheduled }
    static func debugResetSlowStats() { SlowVolumeScheduler.shared.debugResetStats() }
}

/// 按卷维护的优先级单车道门控：同卷任意时刻最多 1 个线程真正碰磁盘，
/// 高优先级任务（当前看图 / 缩放）永远插在后台任务（星级 / EXIF / 清理 / 离屏预热）之前拿到磁头。
private final class SlowVolumeScheduler {
    static let shared = SlowVolumeScheduler()

    private final class Waiter {
        let priority: DiskIO.Priority
        let seq: UInt64
        let sem = DispatchSemaphore(value: 0)
        init(priority: DiskIO.Priority, seq: UInt64) { self.priority = priority; self.seq = seq }
    }

    private final class Lane {
        var busy = false
        var waiters: [Waiter] = []
    }

    private let lock = NSLock()
    private var lanes: [String: Lane] = [:]
    private var nextSeq: UInt64 = 0
    private var activeCount = 0
    private(set) var debugMaxConcurrent = 0
    private(set) var debugTotalScheduled = 0

    func debugResetStats() {
        lock.lock()
        debugMaxConcurrent = 0
        debugTotalScheduled = 0
        lock.unlock()
    }

    func perform<T>(volumeKey: String, priority: DiskIO.Priority, isCancelled: (() -> Bool)?, _ work: () -> T?) -> T? {
        if isCancelled?() == true { return nil }
        let waiter: Waiter?
        lock.lock()
        let lane = lanes[volumeKey] ?? {
            let l = Lane()
            lanes[volumeKey] = l
            return l
        }()
        if !lane.busy {
            lane.busy = true
            waiter = nil
        } else {
            nextSeq &+= 1
            let w = Waiter(priority: priority, seq: nextSeq)
            lane.waiters.append(w)
            waiter = w
        }
        lock.unlock()

        if let waiter { waiter.sem.wait() }
        defer { release(volumeKey: volumeKey) }

        if isCancelled?() == true { return nil }
        lock.lock()
        activeCount += 1
        debugTotalScheduled += 1
        if activeCount > debugMaxConcurrent { debugMaxConcurrent = activeCount }
        lock.unlock()
        defer {
            lock.lock()
            activeCount -= 1
            lock.unlock()
        }
        return work()
    }

    private func release(volumeKey: String) {
        lock.lock()
        guard let lane = lanes[volumeKey] else { lock.unlock(); return }
        if lane.waiters.isEmpty {
            lane.busy = false
            lock.unlock()
            return
        }
        // 选出优先级最高的等待者；同为 interactive 时后到先服务（快速连翻优先最新那张），其余先进先出（保持目录顺序读）
        var bestIdx = 0
        for i in 1..<lane.waiters.count {
            let a = lane.waiters[i], b = lane.waiters[bestIdx]
            if a.priority != b.priority {
                if a.priority > b.priority { bestIdx = i }
            } else if a.priority == .interactive {
                if a.seq > b.seq { bestIdx = i }
            } else if a.seq < b.seq {
                bestIdx = i
            }
        }
        let next = lane.waiters.remove(at: bestIdx)
        lock.unlock()
        next.sem.signal()
    }
}

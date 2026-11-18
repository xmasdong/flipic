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

    /// 慢存储：外接盘（USB 机械硬盘、读卡器）、可移除 / 可推出的盘、网络卷。
    /// 这些盘随机读贵（机械盘每次寻道约 10ms，USB 带宽也小），后台分析要少开几路、按目录顺序读。
    /// 按卷缓存（statfs 拿挂载点和 fsid 当键，一次系统调用），任何线程都能调；
    /// 环境变量 FLIPIC_SLOW_STORAGE=1 / 0 强制（测试用）
    static func isSlowStorage(_ url: URL) -> Bool {
        if let forced = slowOverride { return forced }
        var fs = statfs()
        guard statfs(url.standardizedFileURL.path, &fs) == 0 else { return false }
        let root = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let key = "\(root)|\(fs.f_fsid.val.0)|\(fs.f_fsid.val.1)"
        slowLock.lock()
        if let hit = slowCache[key] { slowLock.unlock(); return hit }
        slowLock.unlock()
        let slow = info(for: url).map { !$0.internalDisk || $0.removable || $0.ejectable || !$0.local } ?? false
        slowLock.lock(); slowCache[key] = slow; slowLock.unlock()
        return slow
    }

    private static let slowOverride: Bool? = {
        switch ProcessInfo.processInfo.environment["FLIPIC_SLOW_STORAGE"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }()
    private static let slowLock = NSLock()
    private static var slowCache: [String: Bool] = [:]

    /// 只读，或者是可移除 / 可推出的盘：批量转换默认不往这里写
    static func isReadOnlyOrRemovable(_ url: URL) -> Bool {
        guard let i = info(for: url) else { return false }
        return i.readOnly || i.removable || i.ejectable
    }
}

/// 批量读文件（元数据、文件头）的并发：内置盘照旧铺满核心；慢存储只开 2 路，
/// 每路按目录顺序读一段连续的文件，机械盘少来回寻道
enum DiskIO {
    static func width(for url: URL?) -> Int {
        guard let url, Volumes.isSlowStorage(url) else { return 0 }
        return 2
    }

    /// width <= 0 或不小于 n：和 concurrentPerform(iterations: n) 一样；否则 width 路，每路一段连续的下标
    static func forEach(_ n: Int, width: Int, _ body: (Int) -> Void) {
        guard n > 0 else { return }
        guard width > 0, width < n else { DispatchQueue.concurrentPerform(iterations: n, execute: body); return }
        let per = (n + width - 1) / width
        DispatchQueue.concurrentPerform(iterations: width) { lane in
            for i in lane * per..<min(n, (lane + 1) * per) { body(i) }
        }
    }

    /// 按 urls 里第一个文件所在的卷决定并发
    static func forEach(_ urls: [URL], _ body: (Int) -> Void) {
        forEach(urls.count, width: width(for: urls.first), body)
    }
}

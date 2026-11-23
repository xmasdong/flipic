import AppKit
import Darwin
import CryptoKit

/// `Flipic --iomeasure <文件夹> <mode> <输出目录> [秒数]`：量打开一个文件夹时从磁盘读了多少。
/// mode：viewer（默认设置）、viewer-date（按拍摄时间排）、viewer-bigthumb（缩略图栏最大档）、
/// workbench（当作工作台项目打开，Pro）；viewer 模式启动时带 BENCH_PREPARE=1 就顺带量按内容查找的提前分析。
/// 每秒记一次：本进程 ri_diskio_bytesread（真正落到磁盘的读）、文件夹里每个文件有多少页进了页缓存（mincore，
/// 卷刚挂上时缓存是空的，所以就是读过的字节，含预读；整个读进内存的大文件读完很快被系统清出缓存，所以这个数只是下限，以 diskRead 为准）、同时开着的照片文件数（每 5ms 看一次本进程的 fd）。
/// 只观察，不改读图的代码；改过的设置结束时还原。读停下来 25 秒（至少跑满 30 秒）或到时间就退出，
/// 最后一行 IOMEASURE summary。要冷缓存：每次跑之前把放照片的磁盘映像卸下再挂上
enum IOMeasure {
    private struct Snap {
        var t: Double
        var diskRead: UInt64
        var residentBytes: Int64
        var filesTouched: Int
        var openNow: Int
    }

    private static var lines: [String] = []
    private static var logURL: URL?
    private static func log(_ s: String) {
        print("IOMEASURE \(s)")
        lines.append(s)
        if let logURL { try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8) }
    }

    static func diskBytesRead() -> UInt64 {
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? ri.ri_diskio_bytesread : 0
    }

    /// 这个文件有多少字节在页缓存里（只映射不访问，不会触发读盘）
    static func residentBytes(_ path: String) -> (resident: Int64, size: Int64) {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return (0, 0) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return (0, 0) }
        let size = Int(st.st_size)
        guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), base != MAP_FAILED else { return (0, Int64(size)) }
        defer { munmap(base, size) }
        let page = Int(getpagesize())
        let pages = (size + page - 1) / page
        var vec = [CChar](repeating: 0, count: pages)
        guard mincore(base, size, &vec) == 0 else { return (0, Int64(size)) }
        var n = 0
        for v in vec where v & 1 != 0 { n += 1 }
        return (Int64(min(n * page, size)), Int64(size))
    }

    /// 本进程现在开着的、在 folder 下的文件
    static func openFiles(under folder: String) -> [String] {
        let pid = getpid()
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        let n = Int(got) / MemoryLayout<proc_fdinfo>.stride
        var out: [String] = []
        for k in 0..<n where fds[k].proc_fdtype == PROX_FDTYPE_VNODE {
            var vi = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, fds[k].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard r > 0 else { continue }
            let path = withUnsafeBytes(of: vi.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if path.hasPrefix(folder) { out.append(path) }
        }
        return out
    }

    // MARK: - 跑

    /// 在 AppDelegate 里调用；viewer 是看图窗口
    static func run(folder: String, mode: String, outDir: String, seconds: Double, viewer: ViewerViewController?) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        logURL = URL(fileURLWithPath: outDir).appendingPathComponent("iomeasure-\(mode).log")
        let dir = URL(fileURLWithPath: folder).standardizedFileURL
        // 文件夹里所有文件（按路径），先 stat 好，量的时候不再列目录
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let paths = names.map { dir.appendingPathComponent($0).path }
        var sizes: [String: Int64] = [:]
        for p in paths { sizes[p] = (try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0 }
        let folderBytes = sizes.values.reduce(0, +)
        let isRaw: (String) -> Bool = { CleanupUnit.isRaw(URL(fileURLWithPath: $0)) }
        let rawCount = paths.filter(isRaw).count
        let d = UserDefaults.standard
        let saved: [String: Any?] = ["sortKey": d.object(forKey: "sortKey"), "thumbSize": d.object(forKey: "thumbSize")]
        func restore() {
            for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        }
        log("mode=\(mode) folder=\(dir.path) files=\(paths.count) (raw \(rawCount), other \(paths.count - rawCount)) bytes=\(folderBytes)"
            + " env BENCH_PREPARE=\(ProcessInfo.processInfo.environment["BENCH_PREPARE"] ?? "-")")
        let vol = Volumes.info(for: dir)
        log("slowStorage=\(Volumes.isSlowStorage(dir) ? 1 : 0) skipsTags=\(Volumes.skipsFinderTags(for: dir) ? 1 : 0) env FLIPIC_SLOW_STORAGE=\(ProcessInfo.processInfo.environment["FLIPIC_SLOW_STORAGE"] ?? "-")"
            + " volume internal=\(vol?.internalDisk == true ? 1 : 0) removable=\(vol?.removable == true ? 1 : 0) ejectable=\(vol?.ejectable == true ? 1 : 0) local=\(vol?.local == true ? 1 : 0) fs=\(vol?.fsType ?? "-")")
        DiskIO.debugResetSlowStats()
        Rating.debugResetStats()

        // 开始之前就已经在缓存里的（应该是 0：卷刚挂上）
        var before: Int64 = 0
        for p in paths { before += residentBytes(p).resident }
        log("resident before open: \(before) bytes; fd sampler sanity: \(openFiles(under: "/").count) vnode fds open, e.g. \(openFiles(under: "/").prefix(2).joined(separator: ", "))")

        // fd 采样线程：同时开着几个照片文件、一共开过哪些
        let lock = NSLock()
        var maxOpen = 0, openNow = 0
        var seenOpen = Set<String>()
        var pausedForScan = false
        var stop = false
        // fd 里的路径是解开符号链接的（/private/tmp），standardizedFileURL 是 /tmp
        let prefix = dir.resolvingSymlinksInPath().path.replacingOccurrences(of: "/tmp/", with: "/private/tmp/", options: .anchored) + "/"
        Thread.detachNewThread {
            while true {
                lock.lock(); let s = stop, paused = pausedForScan; lock.unlock()
                if s { break }
                if !paused {
                    let list = openFiles(under: prefix)
                    lock.lock()
                    openNow = Set(list).count
                    maxOpen = max(maxOpen, openNow)
                    seenOpen.formUnion(list)
                    lock.unlock()
                }
                usleep(5000)
            }
        }

        // 打开
        #if FLIPIC_PRO
        var wbVC: WorkbenchViewController?
        #endif
        switch mode {
        case "viewer":
            viewer?.open(url: dir)
        case "viewer-date":
            d.set(SortKey.captureDate.rawValue, forKey: "sortKey")
            viewer?.open(url: dir)
        case "viewer-bigthumb":
            d.set(Double(FilmstripView.thumbSizes.max() ?? 128), forKey: "thumbSize")
            viewer?.open(url: dir)
        case "workbench":
            #if FLIPIC_PRO
            let file = (outDir as NSString).appendingPathComponent("workbench-iomeasure.json")
            try? fm.removeItem(atPath: file)
            WorkbenchStore.fileOverride = file
            // 清理检查的缓存按文件夹路径存在 Caches/Flipic/Cleanup：删掉这个文件夹的，量的是第一次打开
            if let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let cdir = base.appendingPathComponent("Flipic/Cleanup")
                // 和 CleanupScanner.cacheFile 同一个算法
                let name = SHA256.hash(data: Data(dir.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".plist"
                if (try? fm.removeItem(at: cdir.appendingPathComponent(name))) != nil { log("removed cleanup cache \(name)") }
            }
            let store = WorkbenchStore.shared
            let ids = store.add(folders: [dir])
            store.setUI { $0.lastProject = ids.first }
            log("unlocked=\(License.isUnlocked ? 1 : 0) project=\(ids.first?.uuidString ?? "-")")
            WorkbenchWindowController.showShared()
            wbVC = WorkbenchWindowController.shared?.workbench
            #else
            log("workbench needs a Pro build")
            #endif
        default:
            log("unknown mode \(mode)")
        }
        let t0 = CACurrentMediaTime()
        let disk0 = diskBytesRead()
        var snaps: [Snap] = []
        var firstTouch: [String: Double] = [:]
        var lastChange = 0.0
        var events: [String] = []
        var lastState = ""

        func stateText() -> String {
            #if FLIPIC_PRO
            if let vc = wbVC {
                let st: String
                switch vc.center.state {
                case .photos: st = "photos"
                case .loading: st = "loading"
                default: st = "\(vc.center.state)"
                }
                return "wb state=\(st) photos=\(vc.photos.count) thumbs=\(vc.center.debugVisibleThumbs)/\(vc.center.debugVisibleCount) ratings=\(vc.ratingsLoaded ? 1 : 0) scan=\(vc.scan?.done ?? 0)/\(vc.scan?.total ?? 0)\(vc.scan?.finished == true ? " done" : "")"
            }
            #endif
            guard let v = viewer else { return "-" }
            return "viewer count=\(v.folder.count) sort=\(v.folder.sortKey) needsDates=\(v.folder.needsCaptureDates ? 1 : 0)"
        }

        func tick() {
            let t = CACurrentMediaTime() - t0
            lock.lock(); pausedForScan = true; let now = openNow; lock.unlock()
            var res: Int64 = 0, touched = 0
            var resRaw: Int64 = 0, resOther: Int64 = 0
            for p in paths {
                let r = residentBytes(p).resident
                res += r
                if r > 0 {
                    touched += 1
                    if firstTouch[p] == nil { firstTouch[p] = t }
                    if isRaw(p) { resRaw += r } else { resOther += r }
                }
            }
            lock.lock(); pausedForScan = false; let mx = maxOpen, seen = seenOpen.count; lock.unlock()
            let disk = diskBytesRead() - disk0
            if let last = snaps.last, disk > last.diskRead + (256 << 10) || res > last.residentBytes { lastChange = t }
            let s = Snap(t: t, diskRead: disk, residentBytes: res, filesTouched: touched, openNow: now)
            snaps.append(s)
            let st = stateText()
            if st != lastState { events.append(String(format: "%.1fs %@", t, st)); lastState = st }
            log(String(format: "t=%5.1fs diskRead=%7.1fMB resident=%7.1fMB (raw %.1f / other %.1f) filesNow=%d/%d ever=\(firstTouch.count) openNow=%d maxOpen=%d seenOpen=%d | %@",
                       t, mb(disk), mb(res), mb(resRaw), mb(resOther), touched, paths.count, now, mx, seen, st))
            let idleFor = t - lastChange
            if t >= seconds || (t >= 30 && idleFor >= 25) {
                finish(t: t)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
        }

        func finish(t: Double) {
            lock.lock(); stop = true; let mx = maxOpen, seen = seenOpen.count; lock.unlock()
            restore()
            guard let last = snaps.last else { exit(1) }
            // 每个文件读了多少：按类型分，读了一半以上的算「整个读」
            var rawFull = 0, rawPart = 0, otherFull = 0, otherPart = 0
            var resRaw: Int64 = 0, resOther: Int64 = 0, rawBytes: Int64 = 0, otherBytes: Int64 = 0
            for p in paths {
                let (r, sz) = residentBytes(p)
                let frac = sz > 0 ? Double(r) / Double(sz) : 0
                if isRaw(p) {
                    rawBytes += sz; resRaw += r
                    if frac > 0.5 { rawFull += 1 } else if r > 0 { rawPart += 1 }
                } else {
                    otherBytes += sz; resOther += r
                    if frac > 0.5 { otherFull += 1 } else if r > 0 { otherPart += 1 }
                }
            }
            // 读到 50% / 90% / 100% 用了多久
            func timeTo(_ frac: Double) -> Double {
                snaps.first { Double($0.residentBytes) >= Double(last.residentBytes) * frac }?.t ?? -1
            }
            let touchTimes = firstTouch.values.sorted()
            log("events: " + events.joined(separator: " → "))
            log(String(format: "per-type: raw %d files %.1fMB read %.1fMB (%.0f%%) full=%d partial=%d | other %d files %.1fMB read %.1fMB (%.0f%%) full=%d partial=%d",
                       rawCount, mb(rawBytes), mb(resRaw), pct(resRaw, rawBytes), rawFull, rawPart,
                       paths.count - rawCount, mb(otherBytes), mb(resOther), pct(resOther, otherBytes), otherFull, otherPart))
            log(String(format: "summary mode=%@ folderMB=%.1f residentMB=%.1f (%.0f%%) diskReadMB=%.1f filesTouched(ever)=%d/%d maxOpen=%d seenOpen=%d "
                       + "slowMaxConc=%d slowOps=%d sidecarReads=%d extCacheHits=%d extCacheWrites=%d "
                       + "t50=%.1fs t90=%.1fs t100=%.1fs lastTouch=%.1fs readsIdleSince=%.1fs ranFor=%.1fs",
                       mode, mb(folderBytes), mb(last.residentBytes), pct(last.residentBytes, folderBytes), mb(last.diskRead),
                       firstTouch.count, paths.count, mx, seen,
                       DiskIO.debugSlowMaxConcurrent, DiskIO.debugSlowScheduled, Rating.debugSidecarReads,
                       ExtDiskCache.shared.debugHits, ExtDiskCache.shared.debugWrites,
                       timeTo(0.5), timeTo(0.9), timeTo(1.0),
                       touchTimes.last ?? -1, lastChange, t))
            exit(0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
    }

    private static func mb(_ b: Int64) -> Double { Double(b) / 1_048_576 }
    private static func mb(_ b: UInt64) -> Double { Double(b) / 1_048_576 }
    private static func pct(_ a: Int64, _ b: Int64) -> Double { b > 0 ? Double(a) * 100 / Double(b) : 0 }
}

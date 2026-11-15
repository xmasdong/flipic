import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --cardmarktest <工作文件夹>`：存储卡上的标记不往卡里写。
/// 用 hdiutil 造磁盘映像（exFAT、FAT32，可写和只读挂载，另有 APFS、HFS+ 当对照），走界面用的 toggleMark / 列目录 / 导出到文件夹，
/// 再用 find、xattr、shasum 独立核对。记录存在工作文件夹里的私有位置，不碰真正的记录。最后一行 CARDTEST summary 是汇总
enum CardMarkSelfTest {
    static var checks = 0
    static var failures = 0
    /// 还挂着的映像：不管怎么结束都要卸掉
    static var attached: [URL] = []
    /// 自测会改「导出到文件夹」的复制 / 移动选择，结束时还原
    static var savedMoves: Bool?
    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("CARDTEST \(ok ? "ok  " : "FAIL") \(what)")
    }
    static func info(_ s: String) { print("CARDTEST info \(s)") }

    static func sh(_ exe: String, _ args: [String]) -> String { ExportSelfTest.run(exe, args) }
    static func hdiutil(_ args: [String]) -> String { sh("/usr/bin/hdiutil", args) }

    static func makeImage(_ dmg: URL, fs: String, name: String) -> Bool {
        _ = hdiutil(["create", "-size", "64m", "-fs", fs, "-volname", name, "-ov", dmg.path])
        return FileManager.default.fileExists(atPath: dmg.path)
    }

    static func attach(_ dmg: URL, at mount: URL, readOnly: Bool) -> Bool {
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        var args = ["attach", dmg.path, "-mountpoint", mount.path, "-nobrowse", "-noverify", "-noautoopen"]
        if readOnly { args.append("-readonly") }
        let out = hdiutil(args)
        // FSKit 挂载的 exFAT 有时在 hdiutil 返回后才出现在 mount 清单里
        for _ in 0..<40 {
            if mountLine(mount) != nil { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        info("attach: mount list has no line for \(mount.path); hdiutil said: \(out.prefix(200)); mount output lines \(sh("/sbin/mount", []).split(separator: "\n").count)")
        return false
    }

    static func detach(_ mount: URL) {
        for _ in 0..<5 {
            _ = hdiutil(["detach", mount.path, "-force"])
            if mountLine(mount) == nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try? FileManager.default.removeItem(at: mount)
    }

    static func mountLine(_ mount: URL) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(mount.path, &buf) != nil ? String(cString: buf) : mount.path
        return sh("/sbin/mount", []).split(separator: "\n").map(String.init).first { $0.contains(" on \(real) (") }
    }

    /// 卷上所有文件（含隐藏的）的清单，用来对比标记前后有没有多出东西
    static func snapshot(_ mount: URL) -> String { sh("/usr/bin/find", [mount.path]).split(separator: "\n").sorted().joined(separator: "\n") }
    static func appleDouble(_ mount: URL) -> [String] { sh("/usr/bin/find", [mount.path, "-name", "._*"]).split(separator: "\n").map(String.init) }
    static func xattrs(_ file: URL) -> String { sh("/usr/bin/xattr", [file.path]).trimmingCharacters(in: .whitespacesAndNewlines) }
    static func sha(_ file: URL) -> String { sh("/usr/bin/shasum", ["-a", "256", file.path]).split(separator: " ").first.map(String.init) ?? "-" }

    static func tinyJPEG(_ url: URL, seed: Int) {
        let ctx = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(seed % 5) / 5, green: CGFloat((seed * 3) % 7) / 7, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
    }

    /// 在卷里放 DCIM/100TEST/IMG_0001~0003.JPG，外加和 0003 同名的 .DNG（RAW + JPG 一对）
    static func populate(_ mount: URL) -> URL {
        let dir = mount.appendingPathComponent("DCIM/100TEST")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...3 { tinyJPEG(dir.appendingPathComponent(String(format: "IMG_%04d.JPG", i)), seed: i) }
        try? FileManager.default.copyItem(at: dir.appendingPathComponent("IMG_0003.JPG"), to: dir.appendingPathComponent("IMG_0003.DNG"))
        // 这台电脑上新建的文件都带 com.apple.provenance，在 exFAT / FAT 上系统为它留下 ._ 文件；那是造测试卡的副作用，
        // 不是标记造成的。先清掉，后面「卡里不该多出任何东西」的对比才有意义
        _ = sh("/usr/bin/find", [mount.path, "-name", "._*", "-delete"])
        return dir
    }
}

extension ViewerViewController {
    /// 界面上的异步收尾（后台写标记失败后回主线程改回去、弹提示）要主线程空着才会跑，所以整个测试放在后台线程里，
    /// 碰界面的地方都用 DispatchQueue.main.sync 转到主线程
    func runCardMarkTest(outDir: String) {
        Thread.detachNewThread { self.runCardMarkBody(outDir: outDir) }
    }

    private func runCardMarkBody(outDir: String) {
        typealias T = CardMarkSelfTest
        func M<R>(_ f: () -> R) -> R { DispatchQueue.main.sync(execute: f) }
        /// 主线程上看 folder 的代理：下面的 folder.xxx 都经过它
        struct FolderProxy {
            let vc: ViewerViewController
            var count: Int { DispatchQueue.main.sync { vc.folder.count } }
            var markedCount: Int { DispatchQueue.main.sync { vc.folder.markedCount } }
            var totalCount: Int { DispatchQueue.main.sync { vc.folder.totalCount } }
            var matchingCount: Int { DispatchQueue.main.sync { vc.folder.matchingCount } }
            var items: [ImageItem] { DispatchQueue.main.sync { vc.folder.items } }
            var allItems: [ImageItem] { DispatchQueue.main.sync { vc.folder.allItems } }
            func setMarkedOnly(_ on: Bool) -> Bool { DispatchQueue.main.sync { vc.folder.setMarkedOnly(on) } }
        }
        let folder = FolderProxy(vc: self)
        var debugLastFlash: String { M { self.debugLastFlash } }
        func goTo(_ i: Int) { M { self.goTo(i) } }
        func toggleMark(_ s: Any?) { M { self.toggleMark(s) } }
        func setRating(_ n: Int) { M { self.setRating(n) } }
        func toggleTagColor(_ c: TagColor) { M { self.toggleTagColor(c) } }
        func exportToFolder(_ s: Any?) { M { self.exportToFolder(s) } }
        func ratingTargets(for u: URL) -> [URL] { M { self.ratingTargets(for: u) } }
        var isProcessing: Bool { M { self.isProcessing } }
        let fm = FileManager.default
        let work = URL(fileURLWithPath: outDir).resolvingSymlinksInPath()
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        T.savedMoves = Self.exportFolderMoves
        let storeFile = work.appendingPathComponent("private-store/card-marks.json")
        CardMarks.storeURLOverride = storeFile
        CardMarks.reloadFromDisk()
        let mounts = work.appendingPathComponent("mnt")

        func settle(_ t: Double = 0.4) {
            ratingQueue.sync {}
            Thread.sleep(forTimeInterval: t)
        }
        func waitIdle() {
            let end = Date().addingTimeInterval(15)
            while isProcessing && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
            settle(0.3)
        }
        func openFolder(_ dir: URL) {
            M { self.open(url: dir) }
            settle(0.6)
        }
        func idx(_ name: String) -> Int? { folder.items.firstIndex { $0.url.lastPathComponent == name } }
        func mark(_ name: String) {
            if let i = idx(name) { goTo(i); settle(0.2); toggleMark(nil); settle(0.5) }
        }
        func markedNames() -> [String] { folder.allItems.filter(\.marked).map { $0.url.lastPathComponent }.sorted() }
        func storeText() -> String { (try? String(contentsOf: storeFile, encoding: .utf8)) ?? "" }
        func rule(_ u: URL) -> String {
            guard let i = Volumes.info(for: u) else { return "no info" }
            return "fs=\(i.fsType) ro=\(i.readOnly) removable=\(i.removable) ejectable=\(i.ejectable) internal=\(i.internalDisk) uuid=\(i.uuid ?? "nil") → keepsMarksOff=\(Volumes.keepsMarksOffVolume(i)) key=\(i.key)"
        }
        let markedMsg = { (n: Int) in L10n.f("msg.marked", "已标记 · 共 %d 张", n) }
        let cardMsg = { (n: Int) in L10n.f("msg.markedCard", "已标记 · 共 %d 张。标记记在这台电脑上，没有写进存储卡", n) }

        // ================= 一、exFAT 存储卡（可写）
        do {
            let dmg = work.appendingPathComponent("exfat.dmg")
            guard T.makeImage(dmg, fs: "ExFAT", name: "EOS_DIGITAL") else { T.check(false, "could not create exFAT image"); return finishCardTest() }
            let a = mounts.appendingPathComponent("a")
            guard T.attach(dmg, at: a, readOnly: false) else { T.check(false, "could not attach exFAT image"); return finishCardTest() }
            T.attached.append(a)
            let dir = T.populate(a)
            T.info("exFAT rw: \(rule(dir))")
            let info = Volumes.info(for: dir)
            T.check(info?.fsType == "exfat" && Volumes.keepsMarksOffVolume(info!) && !(info?.readOnly ?? true), "exFAT rw: classified as a card (marks kept off the volume)")
            CardMarks.noticeShown = false
            openFolder(dir)
            T.check(folder.count == 4, "exFAT: 4 files listed (\(folder.count))")
            let before = T.snapshot(a)
            mark("IMG_0001.JPG")
            T.check(folder.markedCount == 1 && debugLastFlash == cardMsg(1), "exFAT: first mark in the session says it is kept on this Mac: '\(debugLastFlash)'")
            mark("IMG_0002.JPG")
            T.check(folder.markedCount == 2 && debugLastFlash == markedMsg(2), "exFAT: second mark does not repeat the notice: '\(debugLastFlash)'")
            mark("IMG_0002.JPG")   // 取消
            T.check(folder.markedCount == 1 && debugLastFlash == L10n.f("msg.unmarked", "已取消标记 · 共 %d 张", 1), "exFAT: unmark works '\(debugLastFlash)'")
            mark("IMG_0003.JPG")   // 一对：JPG 和 DNG 一起
            T.check(markedNames() == ["IMG_0001.JPG", "IMG_0003.DNG", "IMG_0003.JPG"], "exFAT: RAW+JPG pair marked together \(markedNames())")
            T.check(T.appleDouble(a).isEmpty, "exFAT: no ._ file on the card \(T.appleDouble(a))")
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            T.check(files.allSatisfy { T.xattrs($0).isEmpty } && !files.isEmpty, "exFAT: no xattr on any file (xattr CLI)")
            T.check(T.snapshot(a) == before, "exFAT: file listing of the card identical before and after marking")
            T.check(storeText().replacingOccurrences(of: "\\/", with: "/").contains("dcim/100test/img_0001.jpg") && storeText().contains("img_0003.dng") && !storeText().contains("img_0002"), "store: JSON has the marks, relative to the card root, keyed by volume")
            T.info("store json: \(storeText().replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))")
            // 只看已标记
            T.check(folder.setMarkedOnly(true) && folder.count == 3 && folder.matchingCount == 3 && folder.markedCount == 3, "exFAT: marked filter shows 3, counts agree (count \(folder.count), marked \(folder.markedCount), total \(folder.totalCount))")
            _ = folder.setMarkedOnly(false)

            // 卸载再插到另一个挂载点：标记回来
            detachAndRemember(a, &T.attached)
            CardMarks.reloadFromDisk()
            T.check(T.mountLine(a) == nil, "exFAT: detached")
            let b = mounts.appendingPathComponent("b-different-mountpoint")
            guard T.attach(dmg, at: b, readOnly: false) else { T.check(false, "re-attach failed"); return finishCardTest() }
            T.attached.append(b)
            let dirB = b.appendingPathComponent("DCIM/100TEST")
            openFolder(dirB)
            T.check(markedNames() == ["IMG_0001.JPG", "IMG_0003.DNG", "IMG_0003.JPG"], "exFAT: marks survive detach + re-attach at a different mount point \(markedNames())")
            T.check(folder.setMarkedOnly(true) && folder.count == 3, "exFAT: marked filter after re-attach shows \(folder.count)")

            // 导出到 APFS 文件夹：原样复制、一对一起、副本带正常标签
            let dest = work.appendingPathComponent("apfs-dest")
            M { self.debugExportTarget = dest }
            Self.exportFolderMoves = false
            exportToFolder(nil)
            waitIdle()
            M { self.debugExportTarget = nil }
            let copied = ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).sorted()
            T.check(copied == ["IMG_0001.JPG", "IMG_0003.DNG", "IMG_0003.JPG"], "export: marked photos + the RAW partner copied, unmarked left behind \(copied)")
            T.check(copied.allSatisfy { T.sha(dest.appendingPathComponent($0)) == T.sha(dirB.appendingPathComponent($0)) && T.sha(dest.appendingPathComponent($0)) != "-" }, "export: copies are byte-identical (sha256) to the originals on the card")
            T.check(copied.allSatisfy { Marks.isMarked(URL(fileURLWithPath: dest.appendingPathComponent($0).path)) && (TagSelfTest.rawTags(dest.appendingPathComponent($0)) ?? []).contains("\(Marks.tagName)\n2") },
                    "export: every copy carries the Flipic Finder tag (independent xattr read)")
            let m2 = FolderModel(); _ = m2.open(url: dest)
            T.check(m2.markedCount == 3, "export: the new folder lists all 3 as marked (\(m2.markedCount))")
            T.check(T.appleDouble(b).isEmpty && T.snapshot(b).contains("IMG_0002.JPG"), "export: nothing was written to the card by exporting")
            // 移动：卡上的记录跟着清掉
            let dest2 = work.appendingPathComponent("apfs-moved")
            let moved = Self.transfer([dirB.appendingPathComponent("IMG_0001.JPG")], to: dest2, move: false)
            T.check(moved.done.count == 1 && Marks.isMarked(URL(fileURLWithPath: dest2.appendingPathComponent("IMG_0001.JPG").path)), "transfer (the Pro send-to path uses the same function): copy carries the tag")
            _ = folder.setMarkedOnly(false)

            // 老版本留在卡上的访达标签：认得出来
            let legacy = dirB.appendingPathComponent("IMG_0002.JPG")
            _ = Marks.writeTags(["\(Marks.tagName)\n2"], to: legacy)
            openFolder(dirB)
            T.check(markedNames().contains("IMG_0002.JPG") && Marks.isMarked(URL(fileURLWithPath: legacy.path)), "legacy: a Finder tag left on the card by an older version still counts as marked \(markedNames())")
            mark("IMG_0002.JPG")
            T.check(!markedNames().contains("IMG_0002.JPG") && (TagSelfTest.rawTags(legacy) ?? []).isEmpty, "legacy: unmarking on a writable card removes the old tag (as before)")
            // 再放一个老标签，留给只读那一轮
            _ = Marks.writeTags(["\(Marks.tagName)\n2"], to: legacy)
            detachAndRemember(b, &T.attached)
            CardMarks.reloadFromDisk()

            // ================= 二、同一张卡，只读挂载
            let c = mounts.appendingPathComponent("c-readonly")
            guard T.attach(dmg, at: c, readOnly: true) else { T.check(false, "read-only attach failed"); return finishCardTest() }
            T.attached.append(c)
            let dirC = c.appendingPathComponent("DCIM/100TEST")
            T.check((T.mountLine(c) ?? "").contains("read-only"), "read-only: mount reports read-only")
            T.info("exFAT ro: \(rule(dirC))")
            let roInfo = Volumes.info(for: dirC)
            T.check(roInfo?.readOnly == true && Volumes.keepsMarksOffVolume(roInfo!), "read-only: classified as do-not-write")
            CardMarks.noticeShown = false
            openFolder(dirC)
            T.check(markedNames() == ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.DNG", "IMG_0003.JPG"], "read-only: store marks + legacy tag both listed \(markedNames())")
            let snapRO = T.snapshot(c)
            let adRO = T.appleDouble(c)   // 只剩上一轮写老标签时留下的 ._IMG_0002.JPG
            mark("IMG_0001.JPG")   // 取消（记录里的）
            T.check(!markedNames().contains("IMG_0001.JPG") && !storeText().contains("img_0001.jpg\""), "read-only: unmark of an app-side mark works without touching the card")
            mark("IMG_0001.JPG")   // 再标上
            T.check(markedNames().contains("IMG_0001.JPG") && storeText().contains("img_0001.jpg"), "read-only: marking works on a read-only card (kept on this Mac)")
            mark("IMG_0002.JPG")   // 取消老标签：做不到
            T.check(debugLastFlash == L10n.t("msg.markReadOnly", "这张卡是只读的，原来打的标记没法取消") && markedNames().contains("IMG_0002.JPG"),
                    "read-only: unmarking a legacy-tagged file explains why it cannot: '\(debugLastFlash)'")
            let legacyFile = dirC.appendingPathComponent("IMG_0002.JPG")
            T.info("read-only direct: tags on legacy file=\(Marks.readTags(legacyFile)) setResult(unmark)=\(Marks.setResult(false, for: legacyFile)) Rating.write=\(Rating.write(3, to: dirC.appendingPathComponent("IMG_0001.JPG"))) FinderTags.set=\(FinderTags.set(.red, on: true, for: dirC.appendingPathComponent("IMG_0001.JPG")))")
            if let i = idx("IMG_0001.JPG") { goTo(i) }
            settle(0.2)
            setRating(3)
            settle(0.6)
            T.check(debugLastFlash == L10n.t("rating.readOnly", "这张卡是只读的，评分没有写入"), "read-only: rating failure message '\(debugLastFlash)'")
            toggleTagColor(.red)
            settle(0.6)
            T.check(debugLastFlash == L10n.t("tag.readOnly", "这张卡是只读的，颜色标签没有写入"), "read-only: colour tag failure message '\(debugLastFlash)'")
            T.check(T.snapshot(c) == snapRO && T.appleDouble(c) == adRO && adRO.count <= 1, "read-only: card untouched (listing identical; only the old-version legacy tag's ._ file, \(adRO.count))")
            let prefix = BatchConvert.defaultOutputFolder(for: dirC.appendingPathComponent("IMG_0001.JPG"), ext: "jpg")
            let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first!.path
            T.check(prefix.redirected && prefix.url.path.hasPrefix(pictures), "batch convert default folder on a read-only card is under ~/Pictures: \(prefix.url.path)")
            detachAndRemember(c, &T.attached)
        }

        // ================= 三、FAT32 存储卡
        do {
            let dmg = work.appendingPathComponent("fat32.dmg")
            if T.makeImage(dmg, fs: "MS-DOS FAT32", name: "NIKON_D850") {
                let a = mounts.appendingPathComponent("fat-a")
                if T.attach(dmg, at: a, readOnly: false) {
                    T.attached.append(a)
                    let dir = T.populate(a)
                    T.info("FAT32 rw: \(rule(dir))")
                    T.check(Volumes.info(for: dir)?.fsType == "msdos" && CardMarks.usesAppSide(dir), "FAT32: classified as a card")
                    CardMarks.noticeShown = false
                    let before = T.snapshot(a)
                    openFolder(dir)
                    mark("IMG_0001.JPG"); mark("IMG_0003.JPG")
                    T.check(markedNames().count == 3 && debugLastFlash == markedMsg(3), "FAT32: marked \(markedNames())")
                    T.check(T.appleDouble(a).isEmpty && T.snapshot(a) == before, "FAT32: no ._ file, listing unchanged")
                    let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                    T.check(files.allSatisfy { T.xattrs($0).isEmpty }, "FAT32: no xattr on any file")
                    detachAndRemember(a, &T.attached)
                    CardMarks.reloadFromDisk()
                    let b = mounts.appendingPathComponent("fat-b")
                    if T.attach(dmg, at: b, readOnly: false) {
                        T.attached.append(b)
                        openFolder(b.appendingPathComponent("DCIM/100TEST"))
                        T.check(markedNames().count == 3, "FAT32: marks survive re-attach at another mount point \(markedNames())")
                        detachAndRemember(b, &T.attached)
                    }
                }
            } else { T.check(false, "could not create a FAT32 image") }
        }

        // ================= 四、对照：APFS / HFS+ 磁盘映像和普通文件夹照旧用访达标签
        for (fs, label) in [("APFS", "WORKSSD"), ("HFS+", "WORKHFS")] {
            let dmg = work.appendingPathComponent("\(label).dmg")
            guard T.makeImage(dmg, fs: fs, name: label) else { T.info("\(fs): image not available, skipped"); continue }
            let a = mounts.appendingPathComponent("w-\(label)")
            guard T.attach(dmg, at: a, readOnly: false) else { T.info("\(fs): attach failed, skipped"); continue }
            T.attached.append(a)
            let dir = T.populate(a)
            T.info("\(fs) rw: \(rule(dir))")
            T.check(!CardMarks.usesAppSide(dir), "\(fs) volume: not treated as a card, keeps Finder tags")
            CardMarks.noticeShown = false
            openFolder(dir)
            mark("IMG_0001.JPG")
            let f = dir.appendingPathComponent("IMG_0001.JPG")
            T.check(markedNames() == ["IMG_0001.JPG"] && (TagSelfTest.rawTags(f) ?? []) == ["\(Marks.tagName)\n2"] && debugLastFlash == markedMsg(1),
                    "\(fs): mark is the Finder tag exactly as before, no card notice ('\(debugLastFlash)')")
            T.check(!CardMarks.isStoreMarked(f) && !storeText().contains(Volumes.info(for: dir)?.uuid ?? "?"), "\(fs): nothing recorded in the app-side store for this volume")
            detachAndRemember(a, &T.attached)
        }
        do {
            let dir = work.appendingPathComponent("plain/DCIM")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            T.tinyJPEG(dir.appendingPathComponent("a.jpg"), seed: 1)
            T.tinyJPEG(dir.appendingPathComponent("b.jpg"), seed: 2)
            T.info("APFS temp folder: \(rule(dir))")
            T.check(!CardMarks.usesAppSide(dir), "control: plain APFS folder is not a card")
            CardMarks.noticeShown = false
            openFolder(dir)
            mark("a.jpg")
            let f = dir.appendingPathComponent("a.jpg")
            T.check((TagSelfTest.rawTags(f) ?? []) == ["\(Marks.tagName)\n2"] && markedNames() == ["a.jpg"] && debugLastFlash == markedMsg(1), "control: APFS folder marks with the Finder tag, normal message '\(debugLastFlash)'")
            mark("a.jpg")
            T.check((TagSelfTest.rawTags(f) ?? []).isEmpty && markedNames().isEmpty, "control: unmark removes the tag")
        }

        // ================= 五、记录：90 天清理、卷标识回退
        do {
            let now = Date().timeIntervalSince1970
            let json = """
            {"version":1,"volumes":{"uuid:OLD":{"name":"OLDCARD","lastSeen":\(now - 100 * 86400),"marks":["dcim/a.jpg"]},"uuid:NEW":{"name":"NEWCARD","lastSeen":\(now - 10 * 86400),"marks":["dcim/b.jpg"]}}}
            """
            try? fm.createDirectory(at: storeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.write(to: storeFile, atomically: true, encoding: .utf8)
            CardMarks.reloadFromDisk()
            CardMarks.forceLoadForTest()
            let text = storeText()
            T.check(!text.contains("OLDCARD") && text.contains("NEWCARD"), "prune: a volume not seen for 100 days is dropped, one seen 10 days ago is kept")
            let v = VolumeInfo(root: URL(fileURLWithPath: "/Volumes/X"), name: "NOUUID", uuid: nil, capacity: 64_000_000_000, readOnly: false, removable: true, ejectable: true, internalDisk: false, local: true, fsType: "msdos")
            T.check(v.key == "name:NOUUID|64000000000", "volume key falls back to name + capacity when there is no UUID: \(v.key)")
        }
        T.info("cleanup: detaching and deleting images")
        for m in T.attached { T.detach(m) }
        T.attached.removeAll()
        for n in ["exfat.dmg", "fat32.dmg", "WORKSSD.dmg", "WORKHFS.dmg"] { try? fm.removeItem(at: work.appendingPathComponent(n)) }
        T.check(!fm.fileExists(atPath: work.appendingPathComponent("exfat.dmg").path) && T.sh("/sbin/mount", []).contains(work.path) == false, "cleanup: no image left mounted or on disk")
        CardMarks.storeURLOverride = nil
        finishCardTest()
    }

    private func detachAndRemember(_ m: URL, _ list: inout [URL]) {
        CardMarkSelfTest.detach(m)
        list.removeAll { $0 == m }
    }

    private func finishCardTest() {
        typealias T = CardMarkSelfTest
        for m in T.attached { T.detach(m) }
        if let v = T.savedMoves { Self.exportFolderMoves = v }
        UserDefaults.standard.synchronize()
        print("CARDTEST summary checks=\(T.checks) failures=\(T.failures)")
        fflush(stdout)
        exit(T.failures == 0 ? 0 : 1)
    }
}

import AppKit
import Darwin

/// `Flipic --trashtest <文件夹>`：验证删除到底落在哪儿（盘上废纸篓 / 本机废纸篓 / 失败分支）。
/// 结果直接打到 stdout；跑完把文件放回原处再删干净，不留在废纸篓里。
enum TrashSelfTest {
    private static var allMoved: [URL: URL] = [:]

    static func run(folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("trashtest-a.jpg")
        let b = folder.appendingPathComponent("trashtest-b.xmp")
        let c = folder.appendingPathComponent("trashtest-missing.jpg")
        try? Data("a".utf8).write(to: a)
        try? Data("b".utf8).write(to: b)
        try? fm.removeItem(at: c)

        print("trashtest folder=\(folder.path)")
        print("trashtest external=\(Trash.externalVolume(of: folder) != nil) volume=\(Trash.volumeName(of: folder) ?? "-")")
        print("trashtest volumeTrash=\(Trash.volumeTrashFolder(forFile: folder)?.path ?? "-")")
        print("trashtest localTrash=\(Trash.localTrashFolder.path)")

        let old = Trash.copyExternalToLocal
        Trash.copyExternalToLocal = false
        step("1-default-drive-trash", [a]) {
            Trash.copyExternalToLocal = true
            step("2-copy-to-local-trash", [b]) {
                step("3-missing-file", [c]) {
                    Trash.copyExternalToLocal = old
                    scanCheck()
                    ledger()
                    restoreCheck()
                    cleanup()
                    print("trashtest done")
                    exit(0)
                }
            }
        }
    }

    private static func step(_ name: String, _ urls: [URL], then: @escaping () -> Void) {
        var done = false
        Trash.trash(urls) { out in
            for (k, v) in out.moved { allMoved[k] = v }
            let dests = out.moved.values.map(\.path).sorted().joined(separator: ",")
            print("trashtest \(name): moved=\(out.moved.count) failed=\(out.failed.count) local=\(out.usedLocalTrash ? 1 : 0) volume=\(out.volumeName ?? "-") dest=[\(dests)]")
            print("trashtest \(name) summary=\(Trash.summary(out, count: out.moved.count))")
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !done { print("trashtest \(name): TIMEOUT") }
        then()
    }

    /// `--trashscan [数量]`：只扫描并列出废纸篓里的照片，给排查和自测用
    static func scanOnly(limit: Int) {
        let found = TrashBrowserWindowController.scan(days: TrashBrowserWindowController.scanDays, limit: limit)
        print("trashscan found=\(found.count)")
        for f in found {
            print("trashscan \(f.place) | \(f.url.lastPathComponent) | original=\(f.original?.path ?? "-")")
        }
        exit(0)
    }

    /// 废纸篓浏览：刚才删掉的两个文件应该扫得到
    private static func scanCheck() {
        // 本机废纸篓列不出目录，靠记录找回：先把刚才那次删除记下来
        ViewerViewController.lastTrash = ViewerViewController.TrashRecord(moved: allMoved, photo: nil)
        let found = TrashBrowserWindowController.scan(days: 90, limit: 100)
        let mine = found.filter { $0.url.lastPathComponent.hasPrefix("trashtest-") }
        print("trashtest 4b-browser-scan: found=\(mine.count) place=\(mine.first?.place ?? "-") originKnown=\(mine.filter { $0.original != nil }.count)")
    }

    /// 记录存盘 / 读回：模拟退出 Flipic 再打开（装上更新也是这条路径）
    private static func ledger() {
        ViewerViewController.lastTrash = ViewerViewController.TrashRecord(moved: allMoved, photo: nil)
        let saved = FileManager.default.fileExists(atPath: TrashLedger.fileURL.path)
        let loaded = TrashLedger.load()
        print("trashtest 4-ledger-save: saved=\(saved ? 1 : 0) reloaded=\(loaded?.moved.count ?? -1) of \(allMoved.count)")
        ViewerViewController.lastTrash = nil
        let cleared = !FileManager.default.fileExists(atPath: TrashLedger.fileURL.path)
        print("trashtest 5-ledger-clear: cleared=\(cleared ? 1 : 0)")

        // 废纸篓被清空以后，旧记录不该再冒出来
        ViewerViewController.lastTrash = ViewerViewController.TrashRecord(moved: allMoved, photo: nil)
        for url in allMoved.values { try? FileManager.default.removeItem(at: url) }
        let afterEmpty = TrashLedger.load()
        print("trashtest 6-ledger-after-empty: reloaded=\(afterEmpty?.moved.count ?? -1)")
        ViewerViewController.lastTrash = nil

        // 盘没插着：记录先留着，接上盘还能放回
        let ghost = URL(fileURLWithPath: "/Volumes/NotPlugged/.Trashes/501/ghost.jpg")
        let ghostOrig = URL(fileURLWithPath: "/tmp/ghost-original.jpg")
        ViewerViewController.lastTrash = ViewerViewController.TrashRecord(moved: [ghostOrig: ghost], photo: nil)
        let offline = TrashLedger.load()
        print("trashtest 7-ledger-offline-drive: reloaded=\(offline?.moved.count ?? -1)")
        ViewerViewController.lastTrash = nil
    }

    /// 「放回原处」真跑一遍：删掉→从废纸篓挪回原路径
    private static func restoreCheck() {
        let fm = FileManager.default
        let dir = (allMoved.keys.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("restore-check")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("restore-me.jpg")
        try? Data("x".utf8).write(to: src)
        var trashed = src
        var out: NSURL?
        do {
            try fm.trashItem(at: src, resultingItemURL: &out)
            if let t = out as URL? { trashed = t }
        } catch {
            print("trashtest 8-restore-original: trash-failed")
            return
        }
        let found = TrashBrowserWindowController.Found(url: trashed, date: Date(), place: "test", original: src)
        let done = TrashBrowserWindowController.moveBackToOriginals([found])
        let home = fm.fileExists(atPath: src.path)
        print("trashtest 8-restore-original: moved=\(done) back=\(home ? 1 : 0)")
        try? fm.removeItem(at: src)
        try? fm.removeItem(at: dir)
    }

    /// 把测试删掉的文件挪回原处，再删掉测试文件夹，别污染真实废纸篓
    private static func cleanup() {
        let fm = FileManager.default
        for (orig, trashed) in allMoved where !fm.fileExists(atPath: orig.path) {
            try? fm.moveItem(at: trashed, to: orig)
        }
        if let dir = allMoved.keys.first?.deletingLastPathComponent() {
            try? fm.removeItem(at: dir)
        }
        print("trashtest cleanup: restored=\(allMoved.count)")
    }
}

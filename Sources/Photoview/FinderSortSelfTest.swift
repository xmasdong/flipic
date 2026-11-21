import AppKit

/// `Flipic --findersorttest <工作文件夹>`：「跟随访达」读 .DS_Store 和访达全局默认，打开文件夹按访达的排序翻页。
/// <工作文件夹>/real/ 下放几份真实 .DS_Store 的副本（只读解析并打印）。最后一行 FINDERSORT summary
extension ViewerViewController {
    func runFinderSortTest(outDir: String) {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1 }; print("FINDERSORT \(ok ? "ok  " : "FAIL") \(what)") }
        let d = UserDefaults.standard, fm = FileManager.default
        let savedKeys = ["sortKey", "sortReversed", "sortFollowsFinder"].map { ($0, d.object(forKey: $0)) }
        func desc(_ o: FinderSort.Order) -> String { "\(o.key)\(o.reversed ? " reversed" : "")" }
        let base = URL(fileURLWithPath: outDir)

        // 1. 真实 .DS_Store 副本
        let realDir = base.appendingPathComponent("real")
        let globals = FinderSort.globals()
        let g = FinderSort.resolve([:], globals: globals)
        print("FINDERSORT globals style=\(globals["FXPreferredViewStyle"] ?? "-") -> \(desc(g))")
        for f in ((try? fm.contentsOfDirectory(atPath: realDir.path)) ?? []).sorted() where f.hasSuffix(".DS_Store") {
            let bytes = [UInt8]((try? Data(contentsOf: realDir.appendingPathComponent(f))) ?? Data())
            let names = f.hasPrefix("home_root") ? [".", "Desktop", "Downloads", "Documents", "Pictures"] : ["."]
            for n in names {
                let t0 = CFAbsoluteTimeGetCurrent()
                let rec = DSStore.record(in: bytes, named: n)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                let r = rec.isEmpty ? "none" : desc(FinderSort.resolve(rec, globals: globals))
                print("FINDERSORT real \(f) [\(n)] bytes=\(bytes.count) codes=\(rec.keys.sorted()) vstl=\(rec["vstl"] ?? "-") -> \(r) \(String(format: "%.2f", ms))ms")
            }
        }
        let home = fm.homeDirectoryForCurrentUser
        for n in ["Downloads", "Desktop"] {
            let t0 = CFAbsoluteTimeGetCurrent()
            let o = FinderSort.resolve(home.appendingPathComponent(n))
            print("FINDERSORT resolve ~/\(n) -> \(desc(o)) \(String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        }

        // 2. 默认：没选过排序方式才跟随
        for k in ["sortKey", "sortFollowsFinder"] { d.removeObject(forKey: k) }
        check(FolderModel.followsFinder, "没选过排序方式：默认跟随访达")
        d.set(SortKey.size.rawValue, forKey: "sortKey")
        check(!FolderModel.followsFinder, "选过排序方式：不跟随")
        d.removeObject(forKey: "sortKey")
        d.removeObject(forKey: "sortReversed")

        // 3. 自己造 .DS_Store
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func rec(_ name: String, _ code: String, _ type: String, _ data: [UInt8]) -> [UInt8] {
            let u = Array(name.utf16)
            return be32(u.count) + u.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] } + Array(code.utf8) + Array(type.utf8) + data
        }
        func plist(_ name: String, _ code: String, _ p: [String: Any]) -> [UInt8] {
            let b = [UInt8]((try? PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0)) ?? Data())
            return rec(name, code, "blob", be32(b.count) + b)
        }
        func style(_ name: String, _ s: String) -> [UInt8] { rec(name, "vstl", "type", Array(s.utf8)) }
        /// 一个叶子，或者给了 sep 时两层：顶层节点（sep）左右各挂一个叶子
        func bud1(_ a: [[UInt8]], sep: [UInt8]? = nil, _ b: [[UInt8]] = []) -> Data {
            var f = [UInt8](repeating: 0, count: 4 + 20480)
            func put(_ at: Int, _ bytes: [UInt8]) { f.replaceSubrange((at + 4)..<(at + 4 + bytes.count), with: bytes) }
            f.replaceSubrange(0..<20, with: be32(1) + Array("Bud1".utf8) + be32(2048) + be32(2048) + be32(2048))
            let addrs = [2048 | 11, 4096 | 5, 8192 | 12, 12288 | 12, 16384 | 12]
            var root = be32(addrs.count) + be32(0) + addrs.flatMap(be32) + [UInt8](repeating: 0, count: 4 * (256 - addrs.count))
            root += be32(1) + [4] + Array("DSDB".utf8) + be32(1) + [UInt8](repeating: 0, count: 128)
            put(2048, root)
            put(4096, be32(2) + be32(sep == nil ? 0 : 1) + be32(a.count + b.count + (sep == nil ? 0 : 1)) + be32(sep == nil ? 1 : 3) + be32(4096))
            func leaf(_ r: [[UInt8]]) -> [UInt8] { be32(0) + be32(r.count) + r.flatMap { $0 } }
            if let sep {
                put(8192, be32(4) + be32(1) + be32(3) + sep)
                put(12288, leaf(a)); put(16384, leaf(b))
            } else { put(8192, leaf(a)) }
            return Data(f)
        }

        let cases = base.appendingPathComponent("cases"), stage = base.appendingPathComponent("stage")
        for u in [cases, stage] { try? fm.removeItem(at: u); try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
        let folders = ["listAdded", "listSize", "iconMod", "nameDesc", "kind", "truncated", "garbage", "noRecord", "listNoPlist"]
        // 上一级的 .DS_Store：两层 B 树，记录按文件夹名
        let parent = bud1([style("listAdded", "Nlsv"),
                           plist("listAdded", "lsvp", ["sortColumn": "dateAdded", "viewOptionsVersion": 1,
                                                       "columns": ["dateAdded": ["ascending": false], "name": ["ascending": true]]]),
                           plist("nameDesc", "lsvp", ["sortColumn": "name", "columns": ["name": ["ascending": false]]]),
                           style("nameDesc", "Nlsv"), style("listNoPlist", "Nlsv")],
                          sep: rec("kind", "vSrn", "long", be32(1)),
                          [style("listSize", "Nlsv"),
                           plist("listSize", "lsvP", ["sortColumn": "size", "columns": [["identifier": "name", "ascending": true],
                                                                                         ["identifier": "size", "ascending": true]]]),
                           plist("kind", "icvp", ["arrangeBy": "kind"]), style("kind", "icnv")])
        try? parent.write(to: cases.appendingPathComponent(".DS_Store"))
        let iconMod = bud1([rec(".", "vSrn", "long", be32(1)), plist(".", "icvp", ["arrangeBy": "dateModified"]), style(".", "icnv"),
                            rec("a.jpg", "Iloc", "blob", be32(16) + [UInt8](repeating: 0, count: 16))])
        let names = ["c.jpg", "a.jpg", "b.jpg"]      // 放进去的先后
        let px = ["a.jpg": 32, "c.jpg": 96, "b.jpg": 256]
        let age = ["b.jpg": 0.0, "c.jpg": 1000, "a.jpg": 2000]   // 修改时间 b 最新、a 最旧
        for f in folders {
            let dir = cases.appendingPathComponent(f), st = stage.appendingPathComponent(f)
            for u in [dir, st] { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
            for n in names {
                let s = px[n]!
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                for i in 0..<(s * s) { rep.bitmapData![i * 4] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 7); rep.bitmapData![i * 4 + 3] = 255 }
                try? rep.representation(using: .jpeg, properties: [:])?.write(to: st.appendingPathComponent(n))
            }
            let ds = dir.appendingPathComponent(".DS_Store")
            switch f {
            case "iconMod": try? iconMod.write(to: ds)
            case "truncated": try? iconMod.prefix(8200).write(to: ds)
            case "garbage": try? Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7919 >> 3) }).write(to: ds)
            case "noRecord": try? bud1([plist("a.jpg", "icvp", ["arrangeBy": "size"]), style("other", "icnv")]).write(to: ds)
            default: break
            }
        }

        // 4. 坏文件不崩：随机截断、改字节
        var rng = SystemRandomNumberGenerator()
        let good = [UInt8](iconMod), goodParent = [UInt8](parent)
        var survived = 0
        for i in 0..<2000 {
            var b = i % 2 == 0 ? good : goodParent
            if i % 3 == 0 { b = Array(b.prefix(Int.random(in: 0..<b.count, using: &rng))) }
            for _ in 0..<Int.random(in: 1...8, using: &rng) where !b.isEmpty {
                b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = DSStore.record(in: b, named: i % 2 == 0 ? "." : "listSize")
            survived += 1
        }
        check(survived == 2000, "2000 份截断、乱改过的 .DS_Store 都没崩")
        check(DSStore.record(in: [UInt8](iconMod.prefix(8200)), named: ".").isEmpty, "截断的文件读不到记录")
        check(DSStore.record(in: [], named: ".").isEmpty, "空文件读不到记录")

        var k = 0
        func moveNext() {
            guard k < names.count else { verify(); return }
            for f in folders {
                let n = names[k], dst = cases.appendingPathComponent(f).appendingPathComponent(n)
                try? fm.moveItem(at: stage.appendingPathComponent(f).appendingPathComponent(n), to: dst)
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age[n]!)], ofItemAtPath: dst.path)
            }
            k += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { moveNext() }
        }
        func order() -> String { folder.items.map { String($0.url.lastPathComponent.prefix(1)) }.joined() }
        func verify() {
            let sizes = ["a.jpg", "c.jpg", "b.jpg"].map { fileSize(cases.appendingPathComponent("listSize"), $0) }
            check(sizes[0] < sizes[1] && sizes[1] < sizes[2], "文件大小 a < c < b \(sizes)")
            // 表：各排序方式升序的顺序（降序反过来）
            let asc: [SortKey: String] = [.name: "abc", .added: "cab", .modified: "acb", .size: "acb"]
            func expected(_ o: FinderSort.Order) -> String? {
                asc[o.key].map { o.key.largestFirst != o.reversed ? String($0.reversed()) : $0 }
            }
            let want: [String: FinderSort.Order] = ["listAdded": (.added, false), "listSize": (.size, true), "iconMod": (.modified, false),
                                                    "nameDesc": (.name, true), "kind": (.name, false), "truncated": g, "garbage": g,
                                                    "noRecord": g, "listNoPlist": FinderSort.resolve(["vstl": "Nlsv"], globals: globals)]
            for f in folders {
                let w = want[f]!
                let t0 = CFAbsoluteTimeGetCurrent()
                open(url: cases.appendingPathComponent(f))
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                let got = (folder.sortKey, folder.sortReversed)
                check(got == w && order() == expected(w), "\(f): \(desc(got)) 顺序 \(order())，应为 \(desc(w)) \(expected(w) ?? "?")（打开 \(String(format: "%.1f", ms))ms）")
            }
            check(d.object(forKey: "sortKey") == nil && d.object(forKey: "sortReversed") == nil, "跟随访达没有写进记住的排序方式")

            // 跟随访达时点倒序：只对这个文件夹，下次打开又按访达
            open(url: cases.appendingPathComponent("listAdded"))
            folder.sortReversed.toggle(); applySortForTest()
            check(order() == "cab" && d.object(forKey: "sortReversed") == nil, "倒序只改这次 \(order())")
            open(url: cases.appendingPathComponent("listSize"))
            open(url: cases.appendingPathComponent("listAdded"))
            check(order() == "bac" && !folder.sortReversed, "再打开又按访达的 \(order())")

            // 菜单：选一种排序方式就不再跟随，选「跟随访达」又跟随
            let item = NSMenuItem(title: "", action: #selector(setSortKey(_:)), keyEquivalent: "")
            item.tag = SortKey.size.rawValue; setSortKey(item)
            check(!FolderModel.followsFinder && d.integer(forKey: "sortKey") == SortKey.size.rawValue && order() == "bca", "选文件大小：不再跟随 \(order())")
            open(url: cases.appendingPathComponent("iconMod"))
            check(folder.sortKey == .size && order() == "bca", "选过排序方式后打开别的文件夹不跟访达 \(order())")
            item.tag = -1; setSortKey(item)
            check(FolderModel.followsFinder && folder.sortKey == .modified && order() == "bca" && d.integer(forKey: "sortKey") == SortKey.size.rawValue,
                  "选跟随访达：按访达的修改时间，记住的文件大小不动 \(desc((folder.sortKey, folder.sortReversed)))")
            folder.sortKey = .name; applySortForTest()
            check(!FolderModel.followsFinder && order() == "abc", "改回文件名 \(order())")

            // 菜单项
            if let sortMenu = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).compactMap(\.submenu)
                .first(where: { $0.items.contains { $0.action == #selector(setSortKey(_:)) } }) {
                FolderModel.followsFinder = true; folder.refreshFinderSort()
                let line = sortMenu.items.map { m -> String in
                    if m.isSeparatorItem { return "---" }
                    _ = validateMenuItem(m)
                    return "\(m.title)[\(m.state == .on ? "x" : m.state == .mixed ? "-" : " ")]"
                }.joined(separator: " ")
                print("FINDERSORT menu \(line)")
                check(sortMenu.items.first?.tag == -1 && sortMenu.items.first?.state == .on, "菜单第一项是跟随访达并打勾")
                check(sortMenu.items.first { $0.tag == SortKey.modified.rawValue && $0.action == #selector(setSortKey(_:)) }?.state == .mixed,
                      "访达实际用的修改时间标短横")
            } else { check(false, "找到排序菜单") }

            for (key, v) in savedKeys { if let v { d.set(v, forKey: key) } else { d.removeObject(forKey: key) } }
            print("FINDERSORT summary checks=\(checks) failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        func fileSize(_ dir: URL, _ n: String) -> Int {
            ((try? dir.appendingPathComponent(n).resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        }
        moveNext()
    }

    private func applySortForTest() {
        folder.resort(keeping: folder.current?.url)
        filmstrip.collectionView.reloadData()
    }
}

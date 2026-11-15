import AppKit
import Darwin

/// `Flipic --listbench <文件夹>`：量打开文件夹（列目录、取标签、排序）要多久，连量 7 次
enum TagSelfTest {
    static func listBench(folder: URL) -> Never {
        var times: [Double] = []
        var count = 0
        for _ in 0..<7 {
            let m = FolderModel()
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = m.open(url: folder)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            count = m.count
        }
        let s = times.sorted()
        print(String(format: "listbench files=%d min=%.0fms median=%.0fms max=%.0fms all=%@", count, s[0], s[s.count / 2], s[s.count - 1],
                     times.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        exit(0)
    }

    // MARK: - 检查记录

    static var checks = 0
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("TAGTEST \(ok ? "ok  " : "FAIL") \(what)")
    }
    static func info(_ s: String) { print("TAGTEST info \(s)") }

    /// 独立的读法：用系统自带的 xattr 和 plutil 命令读回标签（不走我们自己的 getxattr），没有这个属性返回 nil
    static func rawTags(_ url: URL) -> [String]? {
        func run(_ exe: String, _ args: [String], input: Data? = nil) -> (Int32, Data) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            if input != nil { p.standardInput = inp }
            do { try p.run() } catch { return (-1, Data()) }
            if let input { inp.fileHandleForWriting.write(input); try? inp.fileHandleForWriting.close() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, data)
        }
        let (st, hex) = run("/usr/bin/xattr", ["-px", "com.apple.metadata:_kMDItemUserTags", url.path])
        guard st == 0 else { return nil }
        let digits = String(decoding: hex, as: UTF8.self).filter { $0.isHexDigit }
        var bytes = Data()
        var i = digits.startIndex
        while i < digits.endIndex {
            let j = digits.index(i, offsetBy: 2)
            bytes.append(UInt8(digits[i..<j], radix: 16) ?? 0)
            i = j
        }
        let (st2, json) = run("/usr/bin/plutil", ["-convert", "json", "-o", "-", "-"], input: bytes)
        guard st2 == 0, let arr = try? JSONSerialization.jsonObject(with: json) as? [String] else { return nil }
        return arr
    }

    private static func copy(_ src: URL, to dir: URL, as name: String? = nil) -> URL {
        let dst = dir.appendingPathComponent(name ?? src.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    private static func settle(_ q: DispatchQueue, _ seconds: Double = 0.1) {
        q.sync {}
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - 第一部分：读写文件和筛选（不开窗口）

    static func runFiles(work: URL, photos: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let src = photos.appendingPathComponent("sky.jpg")
        let names = FinderTags.writeNames
        info("system fileLabels=\(NSWorkspace.shared.fileLabels) lang=\(Locale.preferredLanguages.prefix(2))")
        info("writeNames=" + TagColor.allCases.map { "\($0.index):\(names[$0] ?? "-")" }.joined(separator: " "))

        // 1. 每种颜色：打上、独立读回、去掉
        for c in TagColor.allCases {
            let f = copy(src, to: work, as: "one-\(c.index).jpg")
            let name = names[c] ?? "?"
            check(FinderTags.colors(fromTagNames: [name]).contains(c), "name '\(name)' recognised as colour \(c.index)")
            check(FinderTags.set(c, on: true, for: f), "set \(c) returns true")
            let raw = rawTags(f)
            check(raw == ["\(name)\n\(c.index)"], "set \(c): xattr (read by xattr+plutil) = \(raw ?? [])")
            let system = try? URL(fileURLWithPath: f.path).resourceValues(forKeys: [.tagNamesKey])
            check(system?.tagNames == [name], "set \(c): system tagNames = \(system?.tagNames ?? [])")
            check(FinderTags.set(c, on: false, for: f), "clear \(c) returns true")
            check(rawTags(f) == nil, "clear \(c): xattr gone")
        }

        // 2. 和系统自己的写法一模一样：用系统接口打同名标签，两边存的内容逐字节一样
        for c in TagColor.allCases {
            let a = copy(src, to: work, as: "sys-\(c.index).jpg")
            let b = copy(src, to: work, as: "ours-\(c.index).jpg")
            try? (a as NSURL).setResourceValue([names[c] ?? ""], forKey: .tagNamesKey)
            FinderTags.set(c, on: true, for: b)
            check(rawTags(a) == rawTags(b) && rawTags(a) != nil, "colour \(c.index): same xattr as system-written tag \(rawTags(a) ?? [])")
        }

        // 3. 保留别的标签；标记和颜色互不混淆
        let keep = copy(src, to: work, as: "keep.jpg")
        _ = Marks.writeTags(["Work\n5", "\(Marks.tagName)\n2", "OK to publish", "待修\n0"], to: keep)
        check(Marks.isMarked(URL(fileURLWithPath: keep.path)), "keep: marked before")
        check(FinderTags.colors(of: keep).isEmpty, "keep: Flipic mark/custom tags are not colours")
        FinderTags.set(.red, on: true, for: keep)
        FinderTags.set(.blue, on: true, for: keep)
        var t = rawTags(keep) ?? []
        check(t.contains("Work\n5") && t.contains("\(Marks.tagName)\n2") && t.contains("OK to publish") && t.contains("待修\n0"), "keep: custom + mark survive adding colours")
        check(FinderTags.colors(of: keep) == TagColorSet([.red, .blue]), "keep: colours = red,blue")
        FinderTags.set(.red, on: false, for: keep)
        check(FinderTags.colors(of: keep) == TagColorSet([.blue]), "keep: toggling red off leaves blue")
        FinderTags.set(.green, on: true, for: keep)
        FinderTags.clearColors(for: keep)
        t = rawTags(keep) ?? []
        check(Set(t) == ["Work\n5", "\(Marks.tagName)\n2", "OK to publish", "待修\n0"], "keep: clear removes only colours, left \(t)")
        FinderTags.set(.green, on: true, for: keep)
        Marks.set(false, for: keep)
        check(!Marks.isMarked(URL(fileURLWithPath: keep.path)) && FinderTags.colors(of: keep) == TagColorSet([.green]), "keep: unmarking leaves the green colour tag")
        Marks.set(true, for: keep)
        check(FinderTags.colors(of: keep) == TagColorSet([.green]) && Marks.isMarked(URL(fileURLWithPath: keep.path)), "keep: marking leaves green")
        let plainGreen = copy(src, to: work, as: "plaingreen.jpg")
        try? (plainGreen as NSURL).setResourceValue([names[.green] ?? "Green"], forKey: .tagNamesKey)
        check(!Marks.isMarked(URL(fileURLWithPath: plainGreen.path)) && FinderTags.colors(of: plainGreen) == TagColorSet([.green]), "a user's plain green tag is not our mark")

        // 4. 别的写法：访达在别的语言、别的电脑上写的名字，读得出颜色
        let foreign = copy(src, to: work, as: "foreign.jpg")
        _ = Marks.writeTags(["Red\n6", "Rot\n6", "Vert\n2", "Бирюзовый\n4", "Grey\n1"], to: foreign)
        check(FinderTags.colors(of: foreign) == TagColorSet([.red, .green, .gray]), "foreign-language names recognised, unknown colour name ignored: \(FinderTags.colors(of: foreign).colors)")

        // 5. 只读：写不进去返回 false，文件上的标签不变
        let ro = copy(src, to: work, as: "readonly.jpg")
        _ = Marks.writeTags(["Work\n5"], to: ro)
        chmod(ro.path, 0o444)
        let okRO = FinderTags.set(.red, on: true, for: ro)
        check(!okRO, "read-only file (chmod 444): set returns false")
        check(rawTags(ro) == ["Work\n5"], "read-only file: tags unchanged \(rawTags(ro) ?? [])")
        chmod(ro.path, 0o644)
        readOnlyVolume(work: work, src: src)

        // 6. 筛选：整个列表按颜色过滤，和已标记、星级是同一个单选筛选
        let fdir = work.appendingPathComponent("filter")
        try? fm.createDirectory(at: fdir, withIntermediateDirectories: true)
        let plan: [(String, [TagColor], Bool)] = [("a", [.red], false), ("b", [.red, .blue], true), ("c", [.green], false), ("d", [], true), ("e", [.red], false)]
        for (n, cols, mark) in plan {
            let f = copy(src, to: fdir, as: "\(n).jpg")
            for c in cols { FinderTags.set(c, on: true, for: f) }
            if mark { Marks.set(true, for: f) }
        }
        let m = FolderModel()
        m.open(url: fdir)
        check(m.items.map(\.url.lastPathComponent) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"], "filter folder listed")
        check(m.items.map { $0.tagColors.colors.map(\.index) } == [[6], [6, 4], [2], [], [6]], "listing reads colours from the directory enumeration: \(m.items.map { $0.tagColors.colors.map(\.index) })")
        check(m.setFilter(.colorTag(.red)) && m.items.map(\.url.lastPathComponent) == ["a.jpg", "b.jpg", "e.jpg"], "filter red shows a,b,e")
        check(m.matchingCount == 3 && m.totalCount == 5, "filter red: matchingCount=3 totalCount=5")
        check(!m.setFilter(.colorTag(.purple)) && m.filter == .colorTag(.red) && m.count == 3, "filter purple (none): refused, list unchanged")
        check(m.setFilter(.marked) && m.filter == .marked && m.items.map(\.url.lastPathComponent) == ["b.jpg", "d.jpg"], "marked filter replaces the colour filter")
        check(m.setFilter(.colorTag(.blue)) && m.items.map(\.url.lastPathComponent) == ["b.jpg"], "colour filter replaces the marked filter")
        check(m.setFilter(.minRating(1)) == false || m.filter == .minRating(1), "star filter also replaces (or is refused when empty)")
        m.setFilter(nil)
        check(m.count == 5, "filter cleared shows all")
        m.setTagColors(TagColorSet([.purple]), url: m.items[3].url)
        check(m.setFilter(.colorTag(.purple)) && m.count == 1, "setTagColors feeds the filter")
    }

    /// 只读的磁盘映像：和访问不了的 U 盘一样
    private static func readOnlyVolume(work: URL, src: URL) {
        let fm = FileManager.default
        let dmg = work.appendingPathComponent("ro.dmg"), mount = work.appendingPathComponent("romount")
        func sh(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        let stage = work.appendingPathComponent("rostage")
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = copy(src, to: stage, as: "ro.jpg")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard sh(["create", "-quiet", "-srcfolder", stage.path, "-fs", "HFS+", "-volname", "FlipicRO", "-ov", dmg.path]) == 0,
              sh(["attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path]) == 0 else {
            info("hdiutil read-only image unavailable here, only the chmod case ran")
            return
        }
        defer { _ = sh(["detach", "-quiet", "-force", mount.path]) }
        let f = mount.appendingPathComponent("ro.jpg")
        check(!FinderTags.set(.red, on: true, for: f), "read-only disk image: set returns false")
        check(rawTags(f) == nil, "read-only disk image: file untouched")
    }
}

extension ViewerViewController {
    /// --tagtest <工作文件夹> <照片文件夹>：颜色标签和复制文件名从文件到界面走一遍，每步打 TAGTEST 行，最后一行是汇总
    func runTagTest(outDir: String, photos: String) {
        typealias T = TagSelfTest
        let fm = FileManager.default
        let out = URL(fileURLWithPath: outDir), photoDir = URL(fileURLWithPath: photos)
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        T.runFiles(work: out.appendingPathComponent("files"), photos: photoDir)

        // 第二部分：看图界面。照片放进自己的文件夹
        let dir = out.appendingPathComponent("viewer")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["bright", "dark", "sky", "field", "dusk", "red"] { try? fm.copyItem(at: photoDir.appendingPathComponent("\(n).jpg"), to: dir.appendingPathComponent("\(n).jpg")) }
        try? fm.copyItem(at: photoDir.appendingPathComponent("sky.jpg"), to: dir.appendingPathComponent("pair.jpg"))
        try? fm.copyItem(at: photoDir.appendingPathComponent("sky.jpg"), to: dir.appendingPathComponent("pair.dng"))
        // 先把几张的标签准备成要截图的样子
        func tag(_ name: String, _ colors: [TagColor], mark: Bool = false, extra: [String] = []) {
            let f = dir.appendingPathComponent(name)
            for c in colors { FinderTags.set(c, on: true, for: f) }
            if mark { Marks.set(true, for: f) }
            if !extra.isEmpty { _ = Marks.writeTags(Marks.readTags(f) + extra, to: f) }
        }
        tag("bright.jpg", [.red])
        tag("dark.jpg", TagColor.allCases)
        tag("sky.jpg", [.blue], mark: true)
        tag("field.jpg", [.green], extra: ["Work\n5", "OK to publish"])
        tag("dusk.jpg", [.yellow, .orange, .purple], mark: true)
        tag("red.jpg", [.red, .orange])

        let savedThumb = UserDefaults.standard.object(forKey: "thumbSize")
        let savedSort = (folder.sortKey, folder.sortReversed)
        folder.sortKey = .name
        folder.sortReversed = false
        let savedLevel = InfoLevel.current
        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }
        }
        func shot(_ name: String) { captureWindow(to: "\(outDir)/\(name)-\(lang).png", raw: true) }
        func key(_ code: UInt16, _ ch: String, _ mods: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: code) { imageView.keyDown(with: e) }
        }
        func disk(_ name: String) -> TagColorSet { FinderTags.colors(of: dir.appendingPathComponent(name)) }
        func settle() { ratingQueue.sync {}; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        // 像点缩略图那样去到某一张：多选收回成只选这一张
        func goName(_ n: String) { if let i = folder.items.firstIndex(where: { $0.url.lastPathComponent == n }) { filmstripClicked(i, []) } }
        // 列表里的地址是规整过的（/private/tmp 变成 /tmp），直接改列表时要用列表里的那个地址
        func mURL(_ n: String) -> URL { folder.allItems.first { $0.url.lastPathComponent == n }?.url ?? dir.appendingPathComponent(n) }
        func menuItem(_ m: NSMenu, tag: Int) -> NSMenuItem? { m.items.first { $0.tag == tag && $0.action != nil } }

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 800, width: 1180, height: 780), display: true)
        }
        open(url: dir)
        at(1.5) {
            T.check(self.folder.count == 8, "viewer folder has 8 items (\(self.folder.count))")
            // 列目录时就带着颜色
            let dark = self.folder.items.first { $0.url.lastPathComponent == "dark.jpg" }
            T.check(dark?.tagColors == TagColorSet(TagColor.allCases), "dark.jpg shows all seven colours from the listing")
            goName("bright.jpg")
        }
        at(0.5) {
            T.check(self.debugTagBadge.colors == [.red] && !self.debugTagBadge.hidden, "viewer badge shows red for bright.jpg")
            shot("tags-viewer-bright")
            goName("dark.jpg")
        }
        at(0.5) { shot("tags-viewer-dark") ; goName("sky.jpg") }
        at(0.5) { shot("tags-viewer-sky-marked"); goName("field.jpg") }
        at(0.5) { shot("tags-viewer-field-custom") }
        // 其他缩略图大小
        for size: CGFloat in [48, 96] {
            at(0.2) { FilmstripView.thumbSize = size; SettingsWindowController.notify("thumbs") }
            at(0.8) { shot("tags-filmstrip-\(Int(size))") }
        }
        at(0.2) { if let s = savedThumb { UserDefaults.standard.set(s, forKey: "thumbSize") } else { UserDefaults.standard.removeObject(forKey: "thumbSize") }; SettingsWindowController.notify("thumbs"); goName("bright.jpg") }

        // 按键 6 7 8 9：设置、再按去掉
        at(0.6) {
            T.check(Shortcuts.owner(of: KeyCombo(keyCode: 22, chars: "6")) == .tagRed && Shortcuts.owner(of: KeyCombo(keyCode: 26, chars: "7")) == .tagYellow
                    && Shortcuts.owner(of: KeyCombo(keyCode: 28, chars: "8")) == .tagGreen && Shortcuts.owner(of: KeyCombo(keyCode: 25, chars: "9")) == .tagBlue,
                    "keys 6/7/8/9 resolve to tagRed/tagYellow/tagGreen/tagBlue")
            T.check(ShortcutAction.Group.pick.actions.contains(.tagRed) && ShortcutAction.Group.pick.actions.contains(.tagBlue), "tag actions are in the pick group of the shortcuts list")
            goName("pair.jpg")
        }
        at(0.4) {
            key(22, "6"); settle()
            T.check(disk("pair.jpg") == TagColorSet([.red]) && disk("pair.dng") == TagColorSet([.red]), "key 6 on a RAW+JPG pair tags both files")
            T.check(self.folder.current?.tagColors == TagColorSet([.red]), "model updated at once")
            key(22, "6"); settle()
            T.check(disk("pair.jpg").isEmpty && disk("pair.dng").isEmpty, "key 6 again removes it from both files")
            key(26, "7"); key(28, "8"); key(25, "9"); settle()
            T.check(disk("pair.jpg") == TagColorSet([.yellow, .green, .blue]), "keys 7 8 9 add yellow green blue, others kept: \(disk("pair.jpg").colors)")
            // 菜单：勾选状态、橙紫灰只能走菜单
            let menu = ViewerViewController.buildTagMenu()
            for it in menu.items { it.target = self }
            let y = menuItem(menu, tag: TagColor.yellow.index), o = menuItem(menu, tag: TagColor.orange.index)
            T.check(y.map { self.validateMenuItem($0) } == true && y?.state == .on && o?.state == .off, "menu: yellow checked, orange not")
            T.check(menu.items.filter { $0.image != nil }.count == 7 && menu.items.last?.title == L10n.t("menu.tagsClear", "清除颜色标签"), "menu: 7 swatch items + clear item")
            if let o { self.setTagColorMenu(o) }
            if let p = menuItem(menu, tag: TagColor.purple.index) { self.setTagColorMenu(p) }
            if let g = menuItem(menu, tag: TagColor.gray.index) { self.setTagColorMenu(g) }
            if let r = menuItem(menu, tag: TagColor.red.index) { self.setTagColorMenu(r) }
            settle()
            T.check(disk("pair.jpg") == TagColorSet(TagColor.allCases) && disk("pair.dng") == TagColorSet(TagColor.allCases), "(jpg=\(disk("pair.jpg").colors.map(\.index)) dng=\(disk("pair.dng").colors.map(\.index))) menu sets orange/purple/gray too: all seven on both files")
            T.check(self.debugTagBadge.colors.count == 7, "viewer badge shows seven dots")
        }
        // 多选：选中三张，一起打
        at(0.4) {
            goName("bright.jpg")
            self.filmstripClicked(1, .shift)   // bright .. dark
            self.filmstripClicked(2, .shift)
        }
        at(0.3) {
            key(26, "7"); settle()
            T.check(disk("bright.jpg").contains(.yellow) && disk("dark.jpg").contains(.yellow) && disk("dusk.jpg").contains(.yellow) && !disk("field.jpg").contains(.yellow), "multi-select: yellow applied to the three selected (dusk already had it), not to field")
            T.check(self.stripPicked.count == 3, "three selected: \(self.stripPicked.count)")
            key(26, "7"); settle()
            T.info("after second 7: bright=\(disk("bright.jpg").colors.map(\.index)) dark=\(disk("dark.jpg").colors.map(\.index)) dusk=\(disk("dusk.jpg").colors.map(\.index)) picked=\(self.stripPicked.count) model=\(self.folder.items.prefix(3).map { $0.tagColors.colors.map(\.index) })")
            T.check(!disk("bright.jpg").contains(.yellow) && !disk("dark.jpg").contains(.yellow) && !disk("dusk.jpg").contains(.yellow), "multi-select: pressing again removes from all selected")
            T.check(disk("bright.jpg").contains(.red), "multi-select: other colours untouched")
        }
        // 清除颜色：自定义标签和标记留着
        at(0.3) {
            goName("field.jpg")
            self.folder.setMarked(true, url: mURL("field.jpg"))
            Marks.set(true, for: dir.appendingPathComponent("field.jpg"))
        }
        at(0.3) {
            T.check(disk("field.jpg") == TagColorSet([.green]) && self.folder.current?.marked == true, "field.jpg starts green + marked + custom tags")
            key(22, "6"); settle()
            T.check(disk("field.jpg") == TagColorSet([.green, .red]), "field.jpg: green+red (\(disk("field.jpg").colors.map(\.index)) picked=\(self.stripPicked.count) cur=\(self.folder.current?.url.lastPathComponent ?? "-"))")
            self.clearTagColors(nil); settle()
            let raw = TagSelfTest.rawTags(dir.appendingPathComponent("field.jpg")) ?? []
            T.check(disk("field.jpg").isEmpty && Set(raw) == ["Work\n5", "OK to publish", "\(Marks.tagName)\n2"], "clear removes colours only, kept \(raw)")
        }
        // 写不进去：界面回滚并提示
        at(0.3) {
            goName("red.jpg")
            chmod(dir.appendingPathComponent("red.jpg").path, 0o444)
            key(28, "8")
            T.check(self.folder.current?.tagColors.contains(.green) == true, "failure path: UI changes at once (optimistic)")
        }
        at(0.1) {
            settle()
            T.check(self.folder.current?.tagColors == TagColorSet([.red, .orange]), "failure path: model rolled back to red+orange: \(self.folder.current?.tagColors.colors ?? [])")
            T.check(self.debugTagBadge.colors == [.red, .orange], "failure path: badge rolled back")
            T.check(self.debugFlashText.contains("red.jpg"), "failure path: message names the file: \(self.debugFlashText)")
            shot("tags-failure-message")
            chmod(dir.appendingPathComponent("red.jpg").path, 0o644)
        }
        // 筛选
        at(0.3) {
            T.check(self.folder.markedCount == 3, "marked count before filtering: \(self.folder.markedCount)")
            self.applyTagFilter(.red)
            T.check(self.folder.filter == .colorTag(.red) && self.folder.count == 5 && self.folder.totalCount == 8, "filter red shows \(self.folder.count) of \(self.folder.totalCount)")
            T.check(!self.debugFilterPill.hidden && self.debugFilterPill.text.contains(TagColor.red.title) && self.debugFilterPill.text.contains("5 / 8"), "filter pill: \(self.debugFilterPill.text)")
            shot("tags-filter-red")
            let before = self.folder.count
            let menu = ViewerViewController.buildTagFilterMenu()
            let it = menuItem(menu, tag: TagColor.red.index)!
            _ = self.validateMenuItem(it)
            T.check(it.state == .on, "filter menu: red checked while active")
            self.applyTagFilter(.red)   // 再选一次回到全部
            T.check(self.folder.filter == nil && self.folder.count == 8 && before == 5, "choosing red again returns to all photos")
            self.applyTagFilter(.red)
            self.toggleMarkedOnly(nil)
            T.check(self.folder.filter == .marked, "marked-only replaces the colour filter (single filter at a time)")
            self.applyTagFilter(.green)
            T.check(self.folder.filter == .colorTag(.green), "colour filter replaces marked-only")
            self.applyTagFilter(nil)
            let before2 = (self.folder.filter, self.folder.count)
            // 没有符合的颜色：不切换，提示
            for f in ["bright", "dark", "sky", "field", "dusk", "red", "pair"] { for ext in ["jpg", "dng"] {
                let u = dir.appendingPathComponent("\(f).\(ext)")
                if fm.fileExists(atPath: u.path) { FinderTags.set(.purple, on: false, for: u); self.folder.setTagColors(FinderTags.colors(of: u), url: mURL(u.lastPathComponent)) }
            } }
            self.applyTagFilter(.purple)
            T.check(self.folder.filter == before2.0 && self.folder.count == before2.1 && self.debugFlashText.contains(TagColor.purple.title), "filter with no match: list unchanged, message: \(self.debugFlashText)")
        }
        // 信息面板
        at(0.3) { goName("field.jpg"); key(28, "8"); settle() }   // field: green + Work + OK to publish (+ mark)
        at(0.2) {
            InfoLevel.current = .common
            if self.exifPanel.isHidden { self.toggleInfoPanel(nil) }
        }
        at(0.8) {
            let text = self.exifPanel.debugText
            T.check(text.contains(L10n.t("info.tags", "标签")) && text.contains(FinderTags.writeNames[.green] ?? "?") && text.contains("Work") && text.contains("OK to publish") && !text.contains(Marks.tagName), "info panel (common) lists tag row: \(text.components(separatedBy: " | ").suffix(6).joined(separator: " | "))")
            shot("tags-info-common")
            InfoLevel.current = .all
        }
        at(0.6) {
            let text = self.exifPanel.debugText
            T.check(text.contains(L10n.t("info.tags", "标签")) && text.contains(FinderTags.writeNames[.green] ?? "?") && text.contains("Work"), "info panel (all) lists tag row")
            shot("tags-info-all")
            goName("dark.jpg")
        }
        at(0.8) {
            shot("tags-info-all-dark")
            InfoLevel.current = .common
        }
        at(0.5) { shot("tags-info-common-dark") }
        // 复制文件名
        at(0.3) {
            if !self.exifPanel.isHidden { self.toggleInfoPanel(nil) }
            self.applyTagFilter(nil)
            let pb = NSPasteboard.withUniqueName()
            goName("sky.jpg")
            self.copyFileNames(to: pb)
            T.check(pb.string(forType: .string) == "sky.jpg", "copy names: single = \(pb.string(forType: .string) ?? "nil")")
            T.check(self.debugFlashText.contains("1"), "copy names: message \(self.debugFlashText)")
            self.filmstripClicked(0, [])
            self.filmstripClicked(2, .shift)
            self.copyFileNames(to: pb)
            let names = self.folder.items[0...2].map(\.url.lastPathComponent).joined(separator: "\n")
            T.check(pb.string(forType: .string) == names, "copy names: multi-selection one per line, in list order = \(names.replacingOccurrences(of: "\n", with: ","))")
            pb.releaseGlobally()
        }
        at(0.3) {
            // 已标记：当前 sky、dusk、field 是标记过的（sky.jpg、dusk.jpg、field.jpg）
            let pb = NSPasteboard.withUniqueName()
            let item = NSMenuItem(title: "", action: #selector(ViewerViewController.copyMarkedFileNames(_:)), keyEquivalent: "")
            T.check(self.validateMenuItem(item), "copy marked names: enabled while photos are marked")
            self.copyMarkedFileNames(to: pb)
            let got = pb.string(forType: .string) ?? "nil"
            let expect = self.folder.allItems.filter(\.marked).map(\.url.lastPathComponent).joined(separator: "\n")
            T.check(got == expect && got.split(separator: "\n").count == 3, "copy marked names: \(got.replacingOccurrences(of: "\n", with: ","))")
            // 换成按修改时间倒序，顺序跟着排序走
            self.folder.sortReversed.toggle()
            self.folder.resort(keeping: self.folder.current?.url)
            self.filmstrip.collectionView.reloadData()
            let pb2 = NSPasteboard.withUniqueName()
            self.copyMarkedFileNames(to: pb2)
            let rev = self.folder.allItems.filter(\.marked).map(\.url.lastPathComponent).joined(separator: "\n")
            T.check(pb2.string(forType: .string) == rev && rev != expect, "copy marked names follows the current sort order (reversed: \(rev.replacingOccurrences(of: "\n", with: ",")))")
            self.folder.sortReversed.toggle()
            self.folder.resort(keeping: self.folder.current?.url)
            self.filmstrip.collectionView.reloadData()
            // 合并显示：藏起来的搭档不单独成行，用显示着的那个的名字
            Marks.set(true, for: dir.appendingPathComponent("pair.dng"))
            self.folder.setMarked(true, url: mURL("pair.dng"))
            self.folder.setHidden([mURL("pair.dng")])
            self.filmstrip.collectionView.reloadData()
            let pb3 = NSPasteboard.withUniqueName()
            self.copyMarkedFileNames(to: pb3)
            let lines = (pb3.string(forType: .string) ?? "").split(separator: "\n").map(String.init)
            T.check(lines.filter { $0.hasPrefix("pair.") } == ["pair.jpg"], "merged pair: one line using the shown file's name: \(lines)")
            self.folder.setHidden([])
            self.filmstrip.collectionView.reloadData()
            // 一张都没标记：菜单项灰掉，不动剪贴板
            for it in self.folder.allItems where it.marked { self.folder.setMarked(false, url: it.url) }
            T.check(!self.validateMenuItem(item), "copy marked names: disabled when nothing is marked")
            let pb4 = NSPasteboard.withUniqueName()
            self.copyMarkedFileNames(to: pb4)
            T.check(pb4.string(forType: .string) == nil, "copy marked names: nothing written when nothing is marked")
            for p in [pb, pb2, pb3, pb4] { p.releaseGlobally() }
            // 菜单位置：编辑菜单里拷贝的后面
            if let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.action == #selector(ViewerViewController.copyFileNames(_:)) } == true })?.submenu,
               let i = edit.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) }) {
                T.check(edit.items[i + 1].action == #selector(ViewerViewController.copyFileNames(_:)) && edit.items[i + 2].action == #selector(ViewerViewController.copyMarkedFileNames(_:))
                        && edit.items[i + 1].keyEquivalent.isEmpty, "Edit menu: copy names items follow Copy, no shortcut: \(edit.items[i + 1].title) / \(edit.items[i + 2].title)")
            } else {
                T.check(false, "Edit menu items found")
            }
            // 照片菜单和右键菜单里都有「颜色标签」「只看颜色标签」
            func hasSub(_ m: NSMenu?, _ title: String) -> Bool { m?.items.contains { $0.title == title && $0.submenu != nil } == true }
            let photoMenu = NSApp.mainMenu?.items.first { hasSub($0.submenu, L10n.t("menu.tags", "颜色标签")) }?.submenu
            T.check(photoMenu != nil && hasSub(photoMenu, L10n.t("menu.tagFilter", "只看颜色标签")) && hasSub(photoMenu, L10n.t("menu.rating", "评分")), "Photo menu has tags + tag filter next to rating")
            T.check(hasSub(self.imageView.menu, L10n.t("menu.tags", "颜色标签")), "context menu has the Color Tags submenu")
            // 菜单上也看一眼
            if let sub = photoMenu?.items.first(where: { $0.title == L10n.t("menu.tags", "颜色标签") })?.submenu {
                T.info("tag submenu: " + sub.items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: " | "))
            }
        }
        at(0.5) {
            if let s = savedThumb { UserDefaults.standard.set(s, forKey: "thumbSize") } else { UserDefaults.standard.removeObject(forKey: "thumbSize") }
            InfoLevel.current = savedLevel
            self.folder.sortKey = savedSort.0
            self.folder.sortReversed = savedSort.1
            print("TAGTEST summary lang=\(lang) checks=\(T.checks) failures=\(T.failures)")
            fflush(stdout)
            exit(T.failures == 0 ? 0 : 1)
        }
        runNext()
    }
}

import AppKit
import UniformTypeIdentifiers

/// --thumbmenutest <工作文件夹>：缩略图右键菜单。不启动任何真的后期软件（用 debugOpenedFiles / debugPickApplication / debugConfirmMany），
/// 后期软件用工作文件夹里的假 .app 文件夹代替。用测试包自己的 bundle id 跑，不碰真实偏好设置
extension ViewerViewController {
    static func makeThumbMenuPhotos(workDir: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: workDir)
        try? fm.removeItem(at: root)
        let dir = root.appendingPathComponent("photos")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("apps/Lightroom.app"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("apps/Capture One.app"), withIntermediateDirectories: true)
        // a1-a6 是要截图的几张，q01-q24 凑够 30 张测「超过 20 张先确认」；a2 有同名 RAW
        let names = (1...6).map { "a\($0)" } + (1...24).map { String(format: "q%02d", $0) }
        for (k, n) in names.enumerated() {
            let w = 480, h = 320
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            let hue = CGFloat(k % 10) / 10
            let c = NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.75, alpha: 1)
            ctx.setFillColor(c.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.35, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 3))
            guard let img = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(n + ".jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        fm.createFile(atPath: dir.appendingPathComponent("a2.dng").path, contents: Data(count: 64))
    }

    func runThumbMenuTest(workDir: String) {
        guard let window = view.window else { NSLog("THUMBMENU no window"); NSApp.terminate(nil); return }
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
            checks += 1
            if !ok { failures += 1; NSLog("THUMBMENU FAIL %@", msg()) }
        }
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let root = URL(fileURLWithPath: workDir)
        let lightroom = root.appendingPathComponent("apps/Lightroom.app")
        let captureOne = root.appendingPathComponent("apps/Capture One.app")
        let savedEditor = UserDefaults.standard.object(forKey: "editorAppPath")
        defer {
            if let v = savedEditor { UserDefaults.standard.set(v, forKey: "editorAppPath") } else { UserDefaults.standard.removeObject(forKey: "editorAppPath") }
        }
        if filmstrip.isHidden || filmstripHeight.constant == 0 { toggleFilmstrip(nil) }
        folder.sortKey = .name
        folder.sortReversed = false
        let cv = filmstrip.collectionView
        let spin = { (t: Double) in RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        spin(0.5)
        func idx(_ n: String) -> Int { folder.items.firstIndex { $0.url.lastPathComponent == n } ?? -1 }
        func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }
        NSLog("THUMBMENU lang=%@ items=%d editor-window=%@", lang, folder.items.count, window.title)
        check(folder.items.count >= 30, "folder has \(folder.items.count) items")

        // 右键点在第 i 张上：和真的右键一样走 menu(for:)
        func rightClick(_ n: String) -> (NSMenu?, NSPoint) {
            let i = idx(n)
            filmstrip.scrollTo(index: i)
            spin(0.3)
            guard let v = cv.item(at: IndexPath(item: i, section: 0))?.view else { return (nil, .zero) }
            let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return (cv.menu(for: e), p)
        }
        func selectedNames() -> [String] { cv.selectionIndexPaths.map(\.item).sorted().map { folder.items[$0].url.lastPathComponent } }
        func editItem(_ m: NSMenu) -> NSMenuItem? { m.items.first { $0.action == #selector(openInEditor(_:)) } }
        func title(_ m: NSMenu) -> String { guard let it = editItem(m) else { return "" }; _ = validateMenuItem(it); return it.title }
        func openWithItem(_ m: NSMenu) -> NSMenuItem? { m.items.first { $0.submenu?.delegate === self } }
        func openWithList() -> NSMenu { let m = NSMenu(); populateOpenWithMenu(m); return m }
        func choose(_ it: NSMenuItem) { _ = NSApp.sendAction(it.action!, to: it.target, from: it) }
        func select(_ from: String, _ to: String) {
            filmstripClicked(idx(from), [])
            if from != to { filmstripClicked(idx(to), .shift) }
        }

        debugOpenedFiles = []
        UserDefaults.standard.set(lightroom.path, forKey: "editorAppPath")

        // 1 右键点在 3 张多选里的一张：选区不动，菜单对 3 张
        select("a2.jpg", "a4.jpg")
        let curBefore = folder.index
        let fitBefore = imageView.fitDiagnostics
        var (menu, _) = rightClick("a3.jpg")
        check(menu != nil, "menu inside selection is nil")
        check(menu === imageView.menu, "filmstrip menu is not the main image menu")
        check(selectedNames() == ["a2.jpg", "a3.jpg", "a4.jpg"], "selection after right click inside: \(selectedNames())")
        check(folder.index == curBefore, "current changed by right click inside: \(curBefore) -> \(folder.index)")
        check(imageView.fitDiagnostics == fitBefore, "zoom changed by right click")
        check(names(actionURLs) == ["a2.jpg", "a3.jpg", "a4.jpg"], "actionURLs \(names(actionURLs))")
        let t3 = menu.map(title) ?? ""
        NSLog("THUMBMENU [%@] edit title (3 selected, editor set): %@", lang, t3)
        check(t3.contains("3") && t3.contains("Lightroom"), "title 3: \(t3)")
        if let m = menu, let ow = openWithItem(m) {
            check(ow.submenu?.delegate === self, "open-with delegate")
            let list = openWithList()
            let titles = list.items.map { $0.isSeparatorItem ? "|" : $0.title }
            NSLog("THUMBMENU [%@] open-with (3 selected): %@", lang, titles.joined(separator: " / "))
            check(list.items.first?.title == "Lightroom" && list.items.first?.state == .on, "editor first/checked: \(titles)")
            check(list.items.last?.title == L10n.t("menu.openWithOther", "其他…"), "last is Other…")
            // 选软件：3 张一次交出去，同名 RAW 优先，设好的后期软件不变
            debugOpenCalls = []
            choose(list.items[0])
            check(debugOpenCalls.count == 1, "calls \(debugOpenCalls.count)")
            check(names(debugOpenCalls.first?.files ?? []) == ["a2.dng", "a3.jpg", "a4.jpg"], "files \(names(debugOpenCalls.first?.files ?? []))")
            check(debugOpenCalls.first?.app.path == lightroom.path, "app")
            // 列表里另一个软件（不是后期软件的，比如系统默认的预览）
            if let other = list.items.first(where: { $0.representedObject != nil && $0.title != "Lightroom" }), let appURL = other.representedObject as? URL {
                debugOpenCalls = []
                choose(other)
                check(debugOpenCalls.count == 1 && debugOpenCalls[0].files.count == 3 && debugOpenCalls[0].app == appURL, "other app call \(debugOpenCalls.count)")
                check(Self.storedEditorAppURL?.path == lightroom.path, "editor changed by open-with: \(Self.storedEditorAppURL?.path ?? "nil")")
                NSLog("THUMBMENU other listed app = %@", other.title)
            } else { NSLog("THUMBMENU no other listed app to try") }
            // 其他…：用选软件的面板（这里换成假的），一次开 3 张，也不改后期软件
            var pickerAsked = 0
            debugPickApplication = { done in pickerAsked += 1; done(captureOne) }
            debugOpenCalls = []
            choose(list.items.last!)
            check(pickerAsked == 1, "picker asked \(pickerAsked)")
            check(debugOpenCalls.count == 1 && debugOpenCalls[0].files.count == 3 && debugOpenCalls[0].app.path == captureOne.path, "other… call")
            check(Self.storedEditorAppURL?.path == lightroom.path, "editor changed by Other…")
            debugPickApplication = nil
        } else { check(false, "no open-with item in filmstrip menu") }
        // 主菜单（大图上的右键）和菜单栏的「编辑」同样对多选
        debugOpenCalls = []
        openInEditor(nil)
        check(debugOpenCalls.count == 1 && names(debugOpenCalls[0].files) == ["a2.dng", "a3.jpg", "a4.jpg"], "⌘E multi")
        let mainTitle = imageView.menu.map(title) ?? ""
        check(mainTitle == t3, "main image menu title differs: \(mainTitle)")

        // 2 右键点在选区外：只选这一张，成为当前照片
        (menu, _) = rightClick("a6.jpg")
        check(selectedNames() == ["a6.jpg"], "selection after right click outside: \(selectedNames())")
        check(folder.current?.url.lastPathComponent == "a6.jpg", "current after right click outside: \(folder.current?.url.lastPathComponent ?? "-")")
        check(actionURLs.map(\.lastPathComponent) == ["a6.jpg"], "actionURLs outside")
        let t1 = menu.map(title) ?? ""
        NSLog("THUMBMENU [%@] edit title (1 selected, editor set): %@", lang, t1)
        check(t1.contains("Lightroom") && !t1.contains("3"), "title 1: \(t1)")
        debugOpenCalls = []
        if let m = menu, let ow = openWithItem(m) { _ = ow; choose(openWithList().items[0]) }
        check(debugOpenCalls.count == 1 && names(debugOpenCalls[0].files) == ["a6.jpg"], "single open-with")

        // 2b 右键点在单选的那一张上（已是当前）：照旧
        (menu, _) = rightClick("a6.jpg")
        check(menu != nil && selectedNames() == ["a6.jpg"], "right click on current single")
        // 2c 两张多选，右键点在选区外的一张：收成这一张
        select("a3.jpg", "a4.jpg")
        check(selectedNames() == ["a3.jpg", "a4.jpg"], "2-select \(selectedNames())")
        (menu, _) = rightClick("a5.jpg")
        check(selectedNames() == ["a5.jpg"], "outside from 2-select: \(selectedNames())")

        // 3 空隙里右键：没有菜单、选区不动
        select("a2.jpg", "a4.jpg")
        let ipI = IndexPath(item: idx("a3.jpg"), section: 0)
        if let v = cv.item(at: ipI)?.view {
            let r = v.convert(v.bounds, to: nil)
            let gap = NSPoint(x: r.maxX + 4, y: r.midY)
            if cv.indexPathForItem(at: cv.convert(gap, from: nil)) == nil {
                let e = NSEvent.mouseEvent(with: .rightMouseDown, location: gap, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                check(cv.menu(for: e) == nil, "menu in gap")
                check(selectedNames() == ["a2.jpg", "a3.jpg", "a4.jpg"], "selection after gap right click")
            } else { NSLog("THUMBMENU gap point hits an item, gap check skipped") }
        }

        // 4 没设后期软件：标题带张数，选「在后期软件中编辑」走选软件的面板，选完用它打开选中的全部
        UserDefaults.standard.removeObject(forKey: "editorAppPath")
        select("a1.jpg", "a3.jpg")
        (menu, _) = rightClick("a2.jpg")
        let tu = menu.map(title) ?? ""
        NSLog("THUMBMENU [%@] edit title (3 selected, no editor): %@", lang, tu)
        check(tu.contains("3") && !tu.contains("Lightroom"), "unset title: \(tu)")
        let listUnset = openWithList()
        check(listUnset.items.first?.state != .on, "nothing should be checked when no editor is set")
        var asked = 0
        debugPickApplication = { done in asked += 1; done(lightroom) }
        debugOpenCalls = []
        if let it = menu.flatMap(editItem) { choose(it) }
        check(asked == 1, "picker asked for unset editor: \(asked)")
        check(debugOpenCalls.count == 1 && debugOpenCalls[0].files.count == 3, "unset editor open: \(debugOpenCalls.count)")
        check(Self.storedEditorAppURL?.path == lightroom.path, "⌘E path remembers picked editor")
        debugPickApplication = nil

        // 5 超过 20 张先确认：取消什么都不开，确认一次开完
        UserDefaults.standard.set(lightroom.path, forKey: "editorAppPath")
        var asks: [Int] = []
        var answer = false
        debugConfirmMany = { n in asks.append(n); return answer }
        select("a1.jpg", "q19.jpg")   // 文件夹里 26 个文件，a2.jpg 和 a2.dng 送出去时是同一个 RAW，所以是 25 张
        check(stripPicked.count == 26, "picked \(stripPicked.count)")
        (menu, _) = rightClick("a3.jpg")
        let t25 = menu.map(title) ?? ""
        check(t25.contains("25"), "title 25: \(t25)")
        debugOpenCalls = []
        if let it = menu.flatMap(editItem) { choose(it) }
        check(asks == [25], "asked \(asks)")
        check(debugOpenCalls.isEmpty, "cancel still opened \(debugOpenCalls.count)")
        answer = true
        if let it = menu.flatMap(editItem) { choose(it) }
        check(asks == [25, 25] && debugOpenCalls.count == 1 && debugOpenCalls[0].files.count == 25, "confirmed open: asks=\(asks) calls=\(debugOpenCalls.count)")
        // 打开方式里也一样
        asks = []; debugOpenCalls = []; answer = false
        choose(openWithList().items[0])
        check(asks == [25] && debugOpenCalls.isEmpty, "open-with cancel: asks=\(asks) calls=\(debugOpenCalls.count)")
        // 刚好 20 张不问，21 张问
        asks = []; debugOpenCalls = []; answer = false
        select("a1.jpg", "q14.jpg")   // 21 个文件 = 20 张
        check(stripPicked.count == 21, "picked \(stripPicked.count) (want 21 files)")
        openInEditor(nil)
        check(asks.isEmpty && debugOpenCalls.count == 1, "20 should not ask: asks=\(asks) calls=\(debugOpenCalls.count)")
        select("a1.jpg", "q15.jpg")   // 22 个文件 = 21 张
        debugOpenCalls = []
        openInEditor(nil)
        check(asks == [21] && debugOpenCalls.isEmpty, "21 should ask: asks=\(asks) calls=\(debugOpenCalls.count)")
        debugConfirmMany = nil

        // 6 截图：真的弹出菜单，1 张和 3 张各一张
        func popAndShoot(_ n: String, file: String) {
            let (m, p) = rightClick(n)
            guard let m else { check(false, "no menu to shoot"); return }
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            // 程序不在前台时菜单会被系统很快收掉：多试几次
            for attempt in 1...6 {
                NSApp.activate(ignoringOtherApps: true)
                spin(0.3)
                var got = false
                let shoot = Timer(timeInterval: 0.8, repeats: false) { _ in
                    got = Self.captureMenuWindows(of: window, to: file) > 0
                    m.cancelTracking()
                }
                RunLoop.main.add(shoot, forMode: .common)
                let t0 = Date()
                NSMenu.popUpContextMenu(m, with: e, for: cv)
                shoot.invalidate()
                if got { break }
                NSLog("THUMBMENU menu dismissed early (%.1fs), attempt %d", Date().timeIntervalSince(t0), attempt)
            }
        }
        UserDefaults.standard.set(lightroom.path, forKey: "editorAppPath")
        // 窗口后面垫一块纯色，截图里不带桌面
        let backdrop = NSWindow(contentRect: window.screen?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        backdrop.isReleasedWhenClosed = false
        backdrop.order(.below, relativeTo: window.windowNumber)
        window.makeKeyAndOrderFront(nil)
        filmstripClicked(idx("a1.jpg"), [])
        spin(0.3)
        flash("", seconds: 0.05); spin(0.4)
        popAndShoot("a4.jpg", file: "\(workDir)/shot-\(lang)-1.png")
        select("a3.jpg", "a5.jpg")
        spin(1.8)
        popAndShoot("a4.jpg", file: "\(workDir)/shot-\(lang)-3.png")
        check(selectedNames() == ["a3.jpg", "a4.jpg", "a5.jpg"], "selection after shot popup")
        check(FileManager.default.fileExists(atPath: "\(workDir)/shot-\(lang)-1.png") && FileManager.default.fileExists(atPath: "\(workDir)/shot-\(lang)-3.png"), "shots written")

        backdrop.close()
        NSLog("THUMBMENU checks=%d failures=%d", checks, failures)
        NSApp.terminate(nil)
    }

    /// 截下窗口和弹出的菜单（菜单是单独的浮动窗口）；窗口后面垫一块纯色，桌面上别的东西不进图
    @discardableResult
    static func captureMenuWindows(of window: NSWindow, to path: String) -> Int {
        guard let screen = window.screen ?? NSScreen.main else { return 0 }
        func cg(_ f: NSRect) -> CGRect { CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height) }
        var rect = cg(window.frame)
        var menus = 0
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in infos where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) >= 101 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
                rect = rect.union(CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
                menus += 1
            }
        }
        rect = rect.insetBy(dx: -30, dy: -30).intersection(cg(screen.frame))
        guard menus > 0, let img = CGWindowListCreateImage(rect, [.optionOnScreenOnly], kCGNullWindowID, .bestResolution),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return 0
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return menus
    }
}

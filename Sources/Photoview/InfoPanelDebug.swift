import AppKit

extension ViewerViewController {
    /// --infopaneltest <截图文件夹> <照片文件夹>：逐张打开信息面板，在「常用」「全部」两级各截一张窗口；
    /// 内容比面板高的再截一张滚到底的，说明能展开的再截一张展开的。最后测 ⇧I、菜单项和快速翻页时面板里的字跟不跟得上。
    /// 文件名带界面语言（-zh-Hans / -en），换语言用 -AppleLanguages 启动。测完恢复原来的级别
    func runInfoShot(outDir: String, folder path: String) {
        let savedLevel = InfoLevel.current
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }
        }
        func shot(_ name: String) { captureWindow(to: "\(outDir)/\(name)-\(lang).png", raw: true) }
        func log(_ tag: String) {
            let o = exifPanel.debugOverflow
            NSLog("INFOSHOT %@ [%@] panel=%.0f content=%.0f visible=%.0f | %@", tag, lang, exifPanel.frame.height, o.content, o.visible, exifPanel.debugText)
        }

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 800, width: 1180, height: 780), display: true)
        }
        open(url: URL(fileURLWithPath: path))
        at(1.5) {
            NSLog("INFOSHOT files=%d lang=%@", self.folder.count, lang)
            if self.exifPanel.isHidden { self.toggleInfoPanel(nil) }
            let names = self.folder.items.map { $0.url.deletingPathExtension().lastPathComponent }
            var queue: [(Double, () -> Void)] = []
            for (i, name) in names.enumerated() {
                queue.append((0.2, { self.goTo(i); InfoLevel.current = .common }))
                queue.append((1.0, {
                    NSLog("INFOSHOT hist %@ %@", name, self.exifPanel.debugHistogram?.debugSummary ?? "none")
                    log("\(name) common")
                    shot("\(name)-common")
                    if self.exifPanel.debugText.contains(L10n.t("info.expand", "展开")) { self.exifPanel.debugToggleCaption() }
                }))
                queue.append((0.4, {
                    if self.exifPanel.debugText.contains(L10n.t("info.collapse", "收起")) {
                        log("\(name) common-expanded")
                        shot("\(name)-common-expanded")
                        self.exifPanel.debugScrollToBottom()
                    }
                }))
                queue.append((0.4, {
                    if self.exifPanel.debugText.contains(L10n.t("info.collapse", "收起")) {
                        shot("\(name)-common-expanded-bottom")
                        self.exifPanel.debugToggleCaption()
                    }
                    InfoLevel.current = .all
                }))
                queue.append((0.5, {
                    log("\(name) all")
                    shot("\(name)-all")
                }))
                // 一屏放不下的，一屏一屏往下滚着截
                for page in 2...5 {
                    queue.append((0.25, {
                        if self.exifPanel.debugScroll(toPage: page) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shot("\(name)-all-p\(page)") }
                        }
                    }))
                }
            }
            // ⇧I：面板关着时按，应该打开并切换级别；I 只开关面板
            queue.append((0.3, {
                func key(_ mods: NSEvent.ModifierFlags) -> NSEvent? {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: self.view.window?.windowNumber ?? 0, context: nil,
                                     characters: mods.contains(.shift) ? "I" : "i", charactersIgnoringModifiers: mods.contains(.shift) ? "I" : "i",
                                     isARepeat: false, keyCode: 34)
                }
                func state() -> String { "open=\(self.exifPanel.isHidden ? 0 : 1) level=\(InfoLevel.current == .all ? "all" : "common")" }
                InfoLevel.current = .common
                if !self.exifPanel.isHidden { self.toggleInfoPanel(nil) }
                NSLog("INFOSHOT key 0 start %@ owner(⇧I)=%@ owner(I)=%@", state(),
                      key(.shift).flatMap { Shortcuts.action(for: $0) }?.rawValue ?? "nil", key([]).flatMap { Shortcuts.action(for: $0) }?.rawValue ?? "nil")
                self.view.window?.makeFirstResponder(self.imageView)
                if let e = key(.shift) { self.imageView.keyDown(with: e) }
                NSLog("INFOSHOT key 1 after ⇧I (closed) %@", state())
                if let e = key(.shift) { self.imageView.keyDown(with: e) }
                NSLog("INFOSHOT key 2 after ⇧I (open) %@", state())
                if let e = key([]) { self.imageView.keyDown(with: e) }
                NSLog("INFOSHOT key 3 after I %@", state())
                if let e = key([]) { self.imageView.keyDown(with: e) }
                NSLog("INFOSHOT key 4 after I %@", state())
                func find(_ m: NSMenu?) -> NSMenuItem? {
                    for it in m?.items ?? [] {
                        if it.action == #selector(ViewerViewController.toggleInfoLevel(_:)) { return it }
                        if let hit = find(it.submenu) { return hit }
                    }
                    return nil
                }
                if let it = find(NSApp.mainMenu) {
                    InfoLevel.current = .all
                    _ = self.validateMenuItem(it)
                    let on = it.state == .on
                    InfoLevel.current = .common
                    _ = self.validateMenuItem(it)
                    NSLog("INFOSHOT menu title=%@ in=%@ checked(all)=%d checked(common)=%d", it.title, it.menu?.title ?? "-", on ? 1 : 0, it.state == .on ? 1 : 0)
                } else {
                    NSLog("INFOSHOT menu item missing")
                }
                NSLog("INFOSHOT shortcuts view group: %@", ShortcutAction.Group.view.actions.map { "\($0.title)=\(Shortcuts.combo(for: $0)?.display ?? "-")" }.joined(separator: "; "))
            }))
            // 选了说明里的字以后：Esc 把焦点还给照片（面板不关），方向键照常翻页
            queue.append((0.3, { self.goTo(0); if self.exifPanel.isHidden { self.toggleInfoPanel(nil) } }))
            queue.append((0.8, {
                func key(_ code: UInt16) -> NSEvent? {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: self.view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code)
                }
                func responder() -> String { self.view.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil" }
                guard let text = self.exifPanel.debugFirstText else { NSLog("INFOSHOT focus: no caption text on first photo"); return }
                self.view.window?.makeFirstResponder(text)
                text.selectAll(nil)
                NSLog("INFOSHOT focus 0 selected=%d responder=%@", text.selectedRange().length, responder())
                if let e = key(53) { text.keyDown(with: e) }
                NSLog("INFOSHOT focus 1 after Esc responder=%@ panel open=%d", responder(), self.exifPanel.isHidden ? 0 : 1)
                if let t = self.exifPanel.debugFirstText {
                    self.view.window?.makeFirstResponder(t)
                    let before = self.folder.index
                    if let e = key(124) { t.keyDown(with: e) }
                    NSLog("INFOSHOT focus 2 after → responder=%@ index %d → %d", responder(), before, self.folder.index)
                }
            }))
            // 拷贝单张照片：剪贴板第一项除了文件地址还答应给图片数据（TIFF），来要的时候才解码。
            // 挑带方向的（文件名里有 orient）、大图（copytest）和 RAW 各测一遍：拷贝用了多久、要 TIFF 用了多久（解码、编码各多少）、解出来多大、四个角是什么颜色
            for (i, name) in names.enumerated() where name.contains("orient") || name.contains("copytest") || CleanupUnit.isRaw(self.folder.items[i].url) {
                queue.append((0.3, { self.goTo(i) }))
                queue.append((0.8, {
                    let pb = NSPasteboard.withUniqueName()
                    let t0 = CFAbsoluteTimeGetCurrent()
                    self.copyPhotos(to: pb)
                    let copyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    let provider = PhotoPasteboardProvider.debugLast
                    let items = pb.pasteboardItems ?? []
                    NSLog("INFOSHOT copyimg %@ copy=%.1fms items=%d item0 types=%@ decodes after copy=%d", name, copyMs, items.count,
                          items.first?.types.map(\.rawValue).joined(separator: ",") ?? "-", provider?.debugDecodes ?? -1)
                    let t1 = CFAbsoluteTimeGetCurrent()
                    let tiff = items.first?.data(forType: .tiff)
                    let tiffMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
                    var decoded = "undecodable"
                    if let tiff, let src = CGImageSourceCreateWithData(tiff as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                       let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                        func corner(_ x: Int, _ y: Int) -> String {
                            guard let c = img.cropping(to: CGRect(x: x, y: y, width: 8, height: 8)), let d = ctx.data else { return "?" }
                            ctx.draw(c, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                            let p = d.bindMemory(to: UInt8.self, capacity: 4)
                            return "(\(p[0]),\(p[1]),\(p[2]))"
                        }
                        let w = img.width, h = img.height
                        decoded = "\(w)x\(h) type=\(CGImageSourceGetType(src) as String? ?? "-") corners TL=\(corner(4, 4)) TR=\(corner(w - 12, 4)) BL=\(corner(4, h - 12)) BR=\(corner(w - 12, h - 12))"
                    }
                    let shown = self.loader.info(for: self.folder.items[i].url)?.pixelSize ?? .zero
                    NSLog("INFOSHOT copyimg %@ tiff request=%.0fms (source=%@ decode=%.0fms encode=%.0fms) bytes=%d %@ | viewer size=%.0fx%.0f | decodes=%d",
                          name, tiffMs, provider?.debugSource ?? "-", provider?.debugDecodeMs ?? 0, provider?.debugEncodeMs ?? 0, tiff?.count ?? 0, decoded,
                          shown.width, shown.height, provider?.debugDecodes ?? -1)
                    pb.releaseGlobally()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSLog("INFOSHOT copyimg %@ after release live providers=%d", name, PhotoPasteboardProvider.debugLiveCount)
                    }
                }))
            }
            // 快速连翻：每 40 毫秒翻一张，翻之前看面板里是不是别的照片的字
            var stale = 0, samples = 0
            for round in 0..<3 {
                for i in names.indices {
                    queue.append((round == 0 && i == 0 ? 0.6 : 0.04, {
                        if let shown = self.exifPanel.shownURL, let cur = self.folder.current?.url {
                            samples += 1
                            if shown != cur { stale += 1 }
                        }
                        self.goTo(i)
                    }))
                }
            }
            queue.append((0.6, {
                let shown = self.exifPanel.shownURL?.lastPathComponent ?? "nil", cur = self.folder.current?.url.lastPathComponent ?? "nil"
                NSLog("INFOSHOT flip samples=%d other-photo-text=%d (应为上一张还没换完的瞬间) final shown=%@ current=%@ match=%d", samples, stale, shown, cur, shown == cur ? 1 : 0)
                log("after-flip")
                NSLog("INFOSHOT hist after-flip shown=%d", self.exifPanel.debugHistogram != nil ? 1 : 0)
                // 右键菜单：放映项、复制图片的位置和可用状态；复制图片往剪贴板放了什么（用单独的剪贴板，不动用户的）
                if let menu = self.imageView.menu {
                    let rows = menu.items.map { it -> String in
                        if it.isSeparatorItem { return "—" }
                        let on = it.action == nil || self.validateMenuItem(it)
                        return it.title + (on ? "" : "(off)")
                    }
                    NSLog("INFOSHOT context menu: %@", rows.joined(separator: " | "))
                }
                let pb = NSPasteboard.withUniqueName()
                self.copyPhotos(to: pb)
                for item in pb.pasteboardItems ?? [] {
                    NSLog("INFOSHOT copy item types=%@ url=%@", item.types.map(\.rawValue).joined(separator: ","), item.string(forType: .fileURL) ?? "-")
                }
                NSLog("INFOSHOT copy items=%d", pb.pasteboardItems?.count ?? 0)
                pb.releaseGlobally()
                InfoLevel.current = savedLevel
                // COPYQUIT=1：留一个还没兑现的图片数据在（单独的）剪贴板上，正常退出，看系统退出时会不会来要
                if ProcessInfo.processInfo.environment["COPYQUIT"] != nil {
                    PhotoPasteboardProvider.debugLog = true
                    let pending = NSPasteboard.withUniqueName()
                    self.copyPhotos(to: pending)
                    NSLog("INFOSHOT copyquit promise left on %@ live providers=%d, terminating", pending.name.rawValue, PhotoPasteboardProvider.debugLiveCount)
                    NSApp.terminate(nil)
                    return
                }
                NSLog("INFOSHOT done")
                exit(0)
            }))
            steps = queue   // 这一步跑完后 runNext 接着往下取
        }
        runNext()
    }
}

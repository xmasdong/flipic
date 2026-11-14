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
                InfoLevel.current = savedLevel
                NSLog("INFOSHOT done")
                exit(0)
            }))
            steps = queue   // 这一步跑完后 runNext 接着往下取
        }
        runNext()
    }
}

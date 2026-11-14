import AppKit

extension ViewerViewController {
    /// --translationtest <截图文件夹> <照片文件夹> [--tr-download]：照片说明翻译从界面到结果走一遍。
    /// 每张照片：看有没有「翻译」按钮 → 点 → 等结果 → 截图、记下译文 → 隐藏 / 再显示（第二次走缓存，记时间）；
    /// 再强制走 macOS 15–25 的那条路翻一次；再开自动翻译逐张看；最后自动翻译开着快速连翻，查有没有译文排到别的照片下面。
    /// 语言没下载的（按钮带下载提示）默认不点；加 --tr-download 才点一下，看系统的询问出没出来（不会替用户同意下载）。
    /// 界面语言用 -AppleLanguages 换。测完恢复自动翻译的设置
    func runTranslationTest(outDir: String, folder path: String) {
        let savedAuto = CaptionTranslation.autoTranslate, savedLevel = InfoLevel.current
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let clickDownload = CommandLine.arguments.contains("--tr-download")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            NSLog("TRANSLATE %@ [%@] %@", ok ? "ok" : "FAIL", lang, what)
        }
        func log(_ s: String) { NSLog("TRANSLATE    [%@] %@", lang, s) }
        func shot(_ name: String) { captureWindow(to: "\(outDir)/\(lang)-\(name).png", raw: true) }
        var steps: [(Double, () -> Void)] = []
        func at(_ dt: Double, _ f: @escaping () -> Void) { steps.append((dt, f)) }
        /// 等翻译跑完（不是 running）再往下，最多等 20 秒
        func settled(_ f: @escaping () -> Void) { steps.append((-1, f)) }
        func runNext() {
            guard !steps.isEmpty else { return }
            let (dt, f) = steps.removeFirst()
            if dt >= 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + dt) { f(); runNext() }
                return
            }
            let start = Date()
            func poll() {
                if self.exifPanel.debugTranslationState != "running" || Date().timeIntervalSince(start) > (clickDownload ? 90 : 20) { f(); runNext(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
            }
            poll()
        }
        var state: String { exifPanel.debugTranslationState }
        let tTranslate = L10n.t("info.translate", "翻译"), tHide = L10n.t("info.hideTranslation", "隐藏译文"), tLabel = L10n.t("info.translationLabel", "译文")
        func parts() -> [String] { exifPanel.debugText.components(separatedBy: " | ") }

        if let w = view.window {
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            w.setFrame(NSRect(x: vis.minX + 40, y: vis.maxY - 880, width: 1180, height: 860), display: true)
        }
        CaptionTranslation.autoTranslate = false
        CaptionTranslation.debugClearCache()
        InfoLevel.current = .common
        open(url: URL(fileURLWithPath: path))

        var names: [String] = []
        /// 每张照片的译文（手动点出来的那次），后面的自动翻译和连翻拿它对
        var truth: [URL: [String]] = [:]
        var sources: [URL: [String]] = [:]
        var clickedAt = Date()

        at(1.5) {
            if self.exifPanel.isHidden { self.toggleInfoPanel(nil) }
            names = self.folder.items.map { $0.url.deletingPathExtension().lastPathComponent }
            log("files=\(names.count) target=\(CaptionTranslation.targetLanguage) available=\(CaptionTranslation.isAvailable ? 1 : 0) auto=0")
            var queue: [(Double, () -> Void)] = []
            func q(_ dt: Double, _ f: @escaping () -> Void) { queue.append((dt, f)) }
            func qSettled(_ f: @escaping () -> Void) { queue.append((-1, f)) }

            // ---- 1. 逐张：按钮、点击、结果、隐藏 / 再显示
            for (i, name) in names.enumerated() {
                q(0.3) { self.goTo(i) }
                q(1.2) {
                    let p = parts()
                    log("\(name): state=\(state) detected=\(self.exifPanel.debugTranslationSource) button=\(p.contains(tTranslate) ? 1 : 0)")
                    expect((state == "idle" || state == "idle-download") == p.contains(tTranslate), "\(name): button shown exactly when translatable (state \(state))")
                    expect(!p.contains(tLabel), "\(name): no translation before clicking")
                    if state == "idle-download" {
                        shot("\(name)-needs-download")
                        if clickDownload {
                            clickedAt = Date()
                            self.exifPanel.debugClickTranslate()
                            log("\(name): clicked a pair that is not installed, route=\(CaptionTranslation.debugLastRoute) state=\(state)")
                        }
                    } else if state == "idle" {
                        shot("\(name)-before")
                        clickedAt = Date()
                        self.exifPanel.debugClickTranslate()
                        expect(state == "running" && parts().contains(L10n.t("info.translating", "正在翻译…")), "\(name): quiet progress text while running")
                    }
                }
                if clickDownload {
                    // 系统的下载询问：等几秒看它出没出来，截下来；不替用户点
                    q(4.0) {
                        guard state == "running" else { return }
                        let w = self.view.window
                        let others = NSApp.windows.filter { $0 !== w && $0.isVisible }.map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height)) sheet=\($0.isSheet ? 1 : 0)" }
                        log("\(name): 4 s after the click state=\(state) attachedSheet=\(w?.attachedSheet.map { "\(type(of: $0))" } ?? "nil") childWindows=\(w?.childWindows?.count ?? 0) otherWindows=\(others)")
                        shot("\(name)-download-prompt")
                    }
                    q(0.1) {
                        guard state == "running" else { return }
                        log("\(name): waiting up to 90 s for the person to answer the system prompt (the test never accepts it)")
                    }
                }
                qSettled {
                    guard let url = self.folder.current?.url else { return }
                    let ms = Date().timeIntervalSince(clickedAt) * 1000
                    if let t = self.exifPanel.debugTranslation {
                        truth[url] = t.shown
                        sources[url] = t.source
                        expect(self.exifPanel.shownURL == url, "\(name): translated in \(String(format: "%.0f", ms)) ms via \(CaptionTranslation.debugLastRoute)")
                        for (a, b) in zip(t.source, t.shown) { log("\(name): 「\(a)」 → 「\(b)」") }
                        let p = parts()
                        expect(p.contains(tHide) && p.contains(tLabel) && !p.contains(tTranslate), "\(name): button reads \(tHide), label \(tLabel) shown")
                        // 原文还在上面
                        expect(t.source.allSatisfy { s in p.contains { $0.hasPrefix(s) } }, "\(name): original text still shown above")
                        // 网址原样、和前面的字隔开、可以点
                        for (a, b) in zip(t.source, t.shown) {
                            for (r, u) in InfoTextView.links(in: a) {
                                let link = (a as NSString).substring(with: r)
                                let ok = b.contains(" " + link) || b.hasPrefix(link) || b.contains("\n" + link)
                                let clickable = p.contains { $0.hasPrefix(b) && $0.contains("[links: ") && $0.contains(u.absoluteString) }
                                expect(ok && clickable, "\(name): URL \(link) kept intact, separated and clickable in the translation")
                            }
                        }
                    } else if state.hasPrefix("failed") {
                        expect(false, "\(name): \(state)")
                    } else {
                        log("\(name): after waiting \(String(format: "%.1f", ms / 1000)) s state=\(state) button=\(parts().contains(tTranslate) ? 1 : 0) sheet=\(self.view.window?.attachedSheet != nil ? 1 : 0)")
                    }
                }
                q(0.4) {
                    guard self.exifPanel.debugTranslation != nil else { return }
                    shot("\(name)-translated")
                    if self.exifPanel.debugScroll(toPage: 2) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shot("\(name)-translated-p2") }
                    }
                }
                q(0.4) {
                    guard self.exifPanel.debugTranslation != nil else { return }
                    self.exifPanel.debugClickTranslate()
                    let p = parts()
                    expect(state == "idle" && p.contains(tTranslate) && !p.contains(tLabel), "\(name): hide removes the translation, button back to \(tTranslate)")
                    if i == 0 { shot("\(name)-hidden") }
                    let t0 = CFAbsoluteTimeGetCurrent()
                    self.exifPanel.debugClickTranslate()
                    let us = (CFAbsoluteTimeGetCurrent() - t0) * 1_000_000
                    expect(state == "shown" && self.exifPanel.debugTranslation.map { $0.shown } == self.folder.current.flatMap { truth[$0.url] },
                           "\(name): show again comes from the cache, \(String(format: "%.0f", us)) µs including the panel rebuild")
                }
            }

            // ---- 2. 翻走再翻回来：缓存里有的，面板一排出来译文就在
            q(0.3) { self.goTo(0) }
            q(0.8) {}
            for (i, name) in names.enumerated() {
                q(0.3) { self.goTo(i) }
                q(0.8) {
                    guard let url = self.folder.current?.url, let want = truth[url] else { return }
                    expect(self.exifPanel.debugTranslation.map { $0.shown } == want, "\(name): flipping back shows the cached translation without a click")
                }
            }

            // ---- 3. 语言装好了也走一次 translationTask（macOS 15–25 只有这条路）
            q(0.3) {
                CaptionTranslation.debugClearCache()
                CaptionTranslation.debugForceHosted = true
                InfoLevel.current = .all
                InfoLevel.current = .common
            }
            for (i, name) in names.enumerated() {
                q(0.3) { self.goTo(i) }
                q(1.0) {
                    guard state == "idle" else { return }
                    clickedAt = Date()
                    self.exifPanel.debugClickTranslate()
                }
                qSettled {
                    guard let url = self.folder.current?.url, let want = truth[url] else { return }
                    let ms = Date().timeIntervalSince(clickedAt) * 1000
                    expect(self.exifPanel.debugTranslation.map { $0.shown } == want && CaptionTranslation.debugLastRoute == "translationTask",
                           "\(name): same result through the SwiftUI translationTask route (\(CaptionTranslation.debugLastRoute), \(String(format: "%.0f", ms)) ms, state \(state))")
                }
            }
            q(0.2) { CaptionTranslation.debugForceHosted = false }

            // ---- 4. 自动翻译：不点，译文自己出来；没下载语言的不动
            q(0.3) {
                CaptionTranslation.debugClearCache()
                CaptionTranslation.autoTranslate = true
                self.goTo(names.count - 1)
            }
            q(1.5) {}
            for (i, name) in names.enumerated() {
                q(0.3) { self.goTo(i); clickedAt = Date() }
                q(0.5) {}
                qSettled {
                    guard let url = self.folder.current?.url else { return }
                    if let want = truth[url] {
                        expect(self.exifPanel.debugTranslation.map { $0.shown } == want, "\(name): auto-translate shows it without a click (state \(state))")
                        if i == 0 || name.contains("long") { shot("\(name)-auto") }
                    } else {
                        expect(self.exifPanel.debugTranslation == nil && self.view.window?.attachedSheet == nil && state != "running",
                               "\(name): auto-translate leaves it alone (state \(state)), no system prompt")
                    }
                }
            }

            // ---- 5. 自动翻译开着快速连翻：缓存清空一轮、有缓存两轮。每 10 毫秒看一眼面板
            var samples = 0, withTranslation = 0, wrong = 0
            var sampling = false
            func sample() {
                guard sampling else { return }
                samples += 1
                if let t = self.exifPanel.debugTranslation {
                    withTranslation += 1
                    // 面板里排着的原文是哪张的，译文就得是哪张的
                    let shown = self.exifPanel.shownURL
                    if shown == nil || truth[shown!] != t.shown || sources[shown!] != t.source { wrong += 1 }
                    let p = parts()
                    if !t.source.allSatisfy({ s in p.contains { $0.hasPrefix(s) } }) { wrong += 1 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { sample() }
            }
            q(0.3) { CaptionTranslation.debugClearCache(); sampling = true; sample() }
            for round in 0..<4 {
                for i in names.indices {
                    // 第 3 轮慢一点（半秒一张），让一部分翻译真的跑完再被翻走
                    q(round == 2 ? 0.5 : 0.04) { self.goTo(i) }
                }
            }
            q(1.5) {
                sampling = false
                let url = self.folder.current?.url
                expect(wrong == 0 && (withTranslation > 0 || truth.count < 2), "rapid flipping with auto-translate: \(samples) samples, \(withTranslation) with a translation on screen, \(wrong) under the wrong photo")
                expect(self.exifPanel.shownURL == url && (url.flatMap { truth[$0] } == self.exifPanel.debugTranslation.map { $0.shown }),
                       "after flipping: panel shows the current photo with its own translation (state \(state))")
                shot("after-flip")
            }
            q(0.3) {
                CaptionTranslation.autoTranslate = savedAuto
                InfoLevel.current = savedLevel
                NSLog("TRANSLATE end [%@] failures=%d translated=%d of %d photos", lang, failures, truth.count, names.count)
                exit(0)
            }
            steps = queue
        }
        runNext()
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// 最近一个在前面的看图窗口（测试入口和只需要一个窗口的地方用它）
    var windowController: ViewerWindowController!
    /// 所有打开着的看图窗口；关掉的从这里移除
    private var controllers: [ViewerWindowController] = []

    /// 从访达打开照片时开新窗口（可以同时开几个），关掉就换掉当前窗口的内容；默认开
    static var openInNewWindow: Bool {
        get { !UserDefaults.standard.bool(forKey: "openInSameWindow") }
        set { UserDefaults.standard.set(!newValue, forKey: "openInSameWindow") }
    }

    /// 当前在前面的看图窗口
    private var activeController: ViewerWindowController? {
        (NSApp.keyWindow?.windowController as? ViewerWindowController)
            ?? (NSApp.mainWindow?.windowController as? ViewerWindowController)
            ?? windowController
    }

    var activeViewer: ViewerViewController? { activeController?.contentViewController as? ViewerViewController }

    /// 新开一个看图窗口：从当前窗口错开一点叠在上面，第一个窗口沿用记住的位置
    @discardableResult
    func newViewerWindow() -> ViewerWindowController {
        let wc = ViewerWindowController()
        if let ref = activeController?.window, ref.isVisible, let w = wc.window {
            w.setFrame(ref.frame, display: false)
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: ref.frame.minX, y: ref.frame.maxY)))
        }
        controllers.append(wc)
        NotificationCenter.default.addObserver(self, selector: #selector(viewerWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: wc.window)
        wc.showWindow(nil)
        windowController = wc
        return wc
    }

    @objc private func viewerWindowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: w)
        controllers.removeAll { $0.window === w }
        if windowController?.window === w { windowController = controllers.last }
    }

    @objc func newWindowAction(_ sender: Any?) {
        newViewerWindow().openFolderPanel()
    }
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--peekopentest"), i + 1 < CommandLine.arguments.count {
            // --peekopentest <照片>：按设置打开单张照片，记录是否直接进入贴合预览；再按空格回到普通窗口
            let file = CommandLine.arguments[i + 1]
            buildMenu()
            windowController = ViewerWindowController()
            windowController.showWindow(nil)
            let vc = windowController.contentViewController as? ViewerViewController
            windowController.open(URL(fileURLWithPath: file))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NSLog("PEEKOPEN setting=%d after open: %@", ViewerViewController.openInPeek ? 1 : 0, vc?.debugPeekState ?? "-")
                if CommandLine.arguments.contains("--press-next") {
                    vc?.debugPressNext()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        NSLog("PEEKOPEN after → (next photo): %@", vc?.debugPeekState ?? "-")
                        vc?.debugPressNext()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NSLog("PEEKOPEN after → again: %@", vc?.debugPeekState ?? "-")
                            NSApp.terminate(nil)
                        }
                    }
                    return
                }
                if CommandLine.arguments.contains("--press-esc") {
                    vc?.debugPressEsc()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSLog("PEEKOPEN after Esc: windowVisible=%d", self.windowController.window?.isVisible == true ? 1 : 0)
                        NSApp.terminate(nil)
                    }
                    return
                }
                vc?.debugPressSpace()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSLog("PEEKOPEN after Space: %@", vc?.debugPeekState ?? "-")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--setrating"), i + 2 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]) {
            // --setrating <星级> <文件...>：测试前准备星级
            for path in CommandLine.arguments[(i + 2)...] where !path.hasPrefix("-") {
                NSLog("SETRATING %@ %d ok=%d", (path as NSString).lastPathComponent, n, Rating.write(n, to: URL(fileURLWithPath: path)) ? 1 : 0)
            }
            NSApp.terminate(nil)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--bothtest"), i + 1 < CommandLine.arguments.count {
            // --bothtest <文件...>：同一张照片上标记和评星互不影响（评星改写文件后标签还在）
            for path in CommandLine.arguments[(i + 1)...] where !path.hasPrefix("-") {
                let url = URL(fileURLWithPath: path)
                func tags() -> String { ((try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []).joined(separator: ",") }
                NSLog("BOTH %@ start tags=[%@] rating=%d", url.lastPathComponent, tags(), Rating.read(url))
                NSLog("BOTH %@ mark ok=%d tags=[%@]", url.lastPathComponent, Marks.set(true, for: url) ? 1 : 0, tags())
                NSLog("BOTH %@ rate3 ok=%d tags=[%@] rating=%d", url.lastPathComponent, Rating.write(3, to: url) ? 1 : 0, tags(), Rating.read(url))
                NSLog("BOTH %@ unmark ok=%d tags=[%@] rating=%d", url.lastPathComponent, Marks.set(false, for: url) ? 1 : 0, tags(), Rating.read(url))
                NSLog("BOTH %@ mark ok=%d, rate0 ok=%d tags=[%@] rating=%d", url.lastPathComponent, Marks.set(true, for: url) ? 1 : 0,
                      Rating.write(0, to: url) ? 1 : 0, tags(), Rating.read(url))
            }
            NSApp.terminate(nil)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--multiwintest"), i + 1 < CommandLine.arguments.count {
            // --multiwintest <文件...>：模拟从访达逐个打开、一次打开多张、关掉一个、改设置、关掉开关后替换
            let files = CommandLine.arguments[(i + 1)...].filter { !$0.hasPrefix("-") && !$0.hasPrefix("(") }.map { URL(fileURLWithPath: $0) }
            buildMenu()
            newViewerWindow()
            let saved = UserDefaults.standard.object(forKey: "openInSameWindow")
            let savedThumb = UserDefaults.standard.object(forKey: "thumbSize")
            AppDelegate.openInNewWindow = true
            func report(_ tag: String) {
                let ws = controllers.compactMap { $0.window }.filter { $0.isVisible }
                NSLog("MULTI %@ windows=%d titles=[%@]", tag, ws.count, ws.map { $0.title }.joined(separator: " | "))
            }
            var t = 0.0
            func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            at(1.0) { self.application(NSApp, open: [files[0]]); }
            at(1.0) { report("1-open first (expect 1, reuses empty window)") }
            at(0.2) { self.application(NSApp, open: [files[1]]) }
            at(1.0) { report("2-open second (expect 2)") }
            at(0.2) { self.application(NSApp, open: Array(files[2...])) }
            at(1.5) { report("3-open several at once (expect 2 + rest)") }
            at(0.2) { self.controllers.first?.window?.performClose(nil) }
            at(0.6) { report("4-closed one (expect one fewer)") }
            at(0.2) { FilmstripView.thumbSize = 96; SettingsWindowController.notify("thumbs") }
            at(0.8) {
                let heights = self.controllers.compactMap { ($0.contentViewController as? ViewerViewController)?.debugFilmstripHeight }
                NSLog("MULTI 5-thumb size 96 in every window: heights=%@", heights.map { "\(Int($0))" }.joined(separator: ","))
            }
            at(0.2) { AppDelegate.openInNewWindow = false; self.application(NSApp, open: [files[0]]) }
            at(1.0) { report("6-setting off: open replaces (expect same count)") }
            at(0.3) {
                if let saved { UserDefaults.standard.set(saved, forKey: "openInSameWindow") } else { UserDefaults.standard.removeObject(forKey: "openInSameWindow") }
                if let savedThumb { UserDefaults.standard.set(savedThumb, forKey: "thumbSize") } else { UserDefaults.standard.removeObject(forKey: "thumbSize") }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--listtest"), i + 1 < CommandLine.arguments.count {
            // --listtest <文件>：打开一个文件，列出同文件夹里能翻到的图片，逐张确认解码出画面
            buildMenu()
            windowController = ViewerWindowController()
            windowController.showWindow(nil)
            windowController.open(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            let vc = windowController.contentViewController as? ViewerViewController
            vc?.runListTest()
            return
        }
        if CommandLine.arguments.contains("--selfupdatetest") || CommandLine.arguments.contains("--selfupdatenow") {
            // 用 FLIPIC_UPDATE_FEED 指向的版本信息走一遍自动更新。
            // --selfupdatetest：只到替换完成，打印结果后退出；--selfupdatenow：完整流程，包括显示进度窗口和重新打开
            let realRun = CommandLine.arguments.contains("--selfupdatenow")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSLog("SELFUPDATE running=%@ version=%@ team=%@", Bundle.main.bundleURL.path, UpdateChecker.currentVersion,
                      Updater.teamID(of: Bundle.main.bundleURL) == nil ? "none" : "present")
                if !realRun {
                    Updater.shared.onFinishedForTest = { result in
                        switch result {
                        case .success(let app):
                            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
                            let v = info?["CFBundleShortVersionString"] as? String ?? "?"
                            NSLog("SELFUPDATE result=success installed=%@ version=%@ spctl=%d", app.path, v,
                                  Updater.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]))
                        case .failure(let f):
                            NSLog("SELFUPDATE result=failure %@", "\(f)")
                        }
                        NSApp.terminate(nil)
                    }
                }
                UpdateChecker.check { result in
                    switch result {
                    case .newer(let r): Updater.shared.install(r)
                    default: NSLog("SELFUPDATE feed says no newer version"); NSApp.terminate(nil)
                    }
                }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--exifdump") {
            // --exifdump <文件...>：打印照片信息面板会显示的各项（诊断用）
            for path in CommandLine.arguments[(i + 1)...] where !path.hasPrefix("-") && !path.hasPrefix("(") {
                print("== " + (path as NSString).lastPathComponent)
                for e in ExifReader.read(url: URL(fileURLWithPath: path)) {
                    print("  \(e.label): \(e.value)" + (e.link != nil ? "  [link]" : ""))
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--cleanup-report"), i + 1 < CommandLine.arguments.count {
            CleanupDebug.report(folder: CommandLine.arguments[i + 1])
            return
        }
        buildMenu()
        #if FLIPIC_PRO
        License.install()
        Pairs.install()
        NotificationCenter.default.addObserver(forName: License.didChange, object: nil, queue: .main) { _ in Pairs.install() }
        #endif
        newViewerWindow()
        NSApp.activate(ignoringOtherApps: true)

        #if FLIPIC_PRO
        if let i = CommandLine.arguments.firstIndex(of: "--revoketest"), i + 1 < CommandLine.arguments.count {
            RevokeTest.run(keyFile: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--protest2"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    (self?.windowController?.contentViewController as? ViewerViewController)?.runProTest2()
                }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--protest"), i + 3 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            let keyFile = CommandLine.arguments[i + 3]
            for (name, stars) in [("a.jpg", 5), ("b.jpg", 4), ("c.jpg", 4)] {
                _ = Rating.write(stars, to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    (self?.windowController?.contentViewController as? ViewerViewController)?.runProTest(outDir: outDir, keyFile: keyFile)
                }
            }
            return
        }
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--xhs-shots"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.windowController?.runXhsShots(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--infoshot"), i + 2 < CommandLine.arguments.count {
            // --infoshot <截图路径> <文件夹>：打开照片信息面板截图
            let out = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    let vc = self?.windowController?.contentViewController as? ViewerViewController
                    vc?.toggleInfoPanel(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { vc?.debugCapture(to: out); NSApp.terminate(nil) }
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--thumbtest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runThumbTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--pantest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runPanTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--pausetest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runPauseTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--hdrtest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runHDRTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--slidestriptest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runSlideStripTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--updatetest"), i + 2 < CommandLine.arguments.count {
            // --updatetest <截图路径> <文件夹>：自动检查关着时不联网；版本比较；有新版时顶部提示；点 × 后这个版本不再提醒
            let shot = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            let d = UserDefaults.standard
            let saved = (d.object(forKey: "autoCheckUpdates"), d.object(forKey: "skippedUpdateVersion"), d.object(forKey: "lastUpdateCheck"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                let vc = self?.windowController?.contentViewController as? ViewerViewController
                NSLog("UPD compare 0.6.10>0.6.9=%d 0.6.2>0.6.2=%d 1.0>0.9.9=%d", UpdateChecker.isNewer("0.6.10", than: "0.6.9") ? 1 : 0,
                      UpdateChecker.isNewer("0.6.2", than: "0.6.2") ? 1 : 0, UpdateChecker.isNewer("1.0", than: "0.9.9") ? 1 : 0)
                UpdateChecker.autoCheck = false
                d.removeObject(forKey: "lastUpdateCheck")
                var calledWhileOff = false
                UpdateChecker.checkIfDue { _ in calledWhileOff = true }
                UpdateChecker.check { result in
                    var tag = "failed"
                    if case .newer(let r) = result { tag = "newer " + r.version; vc?.showUpdateBanner(r) }
                    if case .upToDate(let v) = result { tag = "upToDate " + v }
                    NSLog("UPD check current=%@ result=%@ lastCheckSet=%d", UpdateChecker.currentVersion, tag, d.object(forKey: "lastUpdateCheck") != nil ? 1 : 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSLog("UPD banner visible=%d autoOffCalled=%d", vc?.debugUpdateBannerVisible == true ? 1 : 0, calledWhileOff ? 1 : 0)
                        vc?.debugCapture(to: shot)
                        vc?.debugSkipUpdate()
                        UpdateChecker.autoCheck = true
                        d.removeObject(forKey: "lastUpdateCheck")
                        var calledAfterSkip = false
                        UpdateChecker.checkIfDue { _ in calledAfterSkip = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NSLog("UPD after skip skipped=%@ bannerVisible=%d promptedAgain=%d", UpdateChecker.skippedVersion ?? "-",
                                  vc?.debugUpdateBannerVisible == true ? 1 : 0, calledAfterSkip ? 1 : 0)
                            for (k, v) in [("autoCheckUpdates", saved.0), ("skippedUpdateVersion", saved.1), ("lastUpdateCheck", saved.2)] {
                                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
                            }
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--fadeseq"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runFadeSequence(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--slidefadetest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runSlideFadeTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--ratingshot"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runRatingShot(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--exporttest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runExportTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--comparetest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runCompareTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--marktest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runMarkTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--ratingtest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runRatingTest() }
            }
        } else if CommandLine.arguments.contains("--defaulttest") {
            // 设为默认看图：改之前、改之后各记一次，最后把这些格式改回「预览」
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSLog("DEFAULT before isDefault=%d current=%@", DefaultViewer.isDefault ? 1 : 0, DefaultViewer.currentName)
                DefaultViewer.make {
                    let flipic = DefaultViewer.types.filter(DefaultViewer.isFlipic).count
                    NSLog("DEFAULT after isDefault=%d types=%d/%d", DefaultViewer.isDefault ? 1 : 0, flipic, DefaultViewer.types.count)
                    let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
                    let g = DispatchGroup()
                    for t in DefaultViewer.types { g.enter(); NSWorkspace.shared.setDefaultApplication(at: preview, toOpen: t) { _ in g.leave() } }
                    g.notify(queue: .main) {
                        NSLog("DEFAULT restored current=%@", DefaultViewer.currentName)
                        NSApp.terminate(nil)
                    }
                }
            }
        } else if CommandLine.arguments.contains("--hotkeytest") {
            // 全局快捷键：从系统层面发两次 ⌃⌥⌘P，第一次应收起，第二次应回到最前面
            let saved = Shortcuts.combo(for: .toggleApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Shortcuts.set(KeyCombo(keyCode: 35, mods: [.control, .option, .command], chars: "p"), for: .toggleApp)
                NSLog("HOTKEY registered=%d active=%d hidden=%d", HotKey.isRegistered ? 1 : 0, NSApp.isActive ? 1 : 0, NSApp.isHidden ? 1 : 0)
                func post() {
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: nil, virtualKey: 35, keyDown: down)
                        e?.flags = [.maskControl, .maskAlternate, .maskCommand]
                        e?.post(tap: .cghidEventTap)
                    }
                }
                post()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSLog("HOTKEY after 1st press active=%d hidden=%d", NSApp.isActive ? 1 : 0, NSApp.isHidden ? 1 : 0)
                    post()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSLog("HOTKEY after 2nd press active=%d hidden=%d windowVisible=%d", NSApp.isActive ? 1 : 0, NSApp.isHidden ? 1 : 0,
                              self.windowController?.window?.isVisible == true ? 1 : 0)
                        Shortcuts.set(saved, for: .toggleApp)
                        NSLog("HOTKEY restored registered=%d", HotKey.isRegistered ? 1 : 0)
                        NSApp.terminate(nil)
                    }
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--settingstest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runSettingsTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--esctest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runEscTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--hudtest"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runHUDTest(outDir: outDir) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--zoomtest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.windowController?.runZoomFadeTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--slidetest"), i + 2 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            let app = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.windowController?.runSlideAndEditorTest(appPath: app) }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--wheeltest"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.windowController?.runWheelTest() }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--cleanup-shot"), i + 2 < CommandLine.arguments.count {
            // --cleanup-shot <输出目录> <文件夹>
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.windowController?.runCleanupTest(outDir: outDir)
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--peektest"), i + 2 < CommandLine.arguments.count {
            // --peektest <输出目录> <文件夹>
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.windowController?.runPeekTest(outDir: outDir)
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--shot-browse"), i + 2 < CommandLine.arguments.count {
            // --shot-browse <输出目录> <文件夹>
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.windowController?.runBrowseShots(outDir: outDir)
                }
            }
        } else if let i = CommandLine.arguments.firstIndex(of: "--bench"), i + 1 < CommandLine.arguments.count {
            let folder = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.runBench(folder: folder)
            }
        } else if CommandLine.arguments.contains("--shot") {
            // shot 模式的文件夹加载在下方单独编排，不走红路径
        } else if let pending = pendingURL {
            scheduleAutoUpdateCheck()
            windowController.open(pending)
            pendingURL = nil
        } else {
            scheduleAutoUpdateCheck()
            let paths = CommandLine.arguments.dropFirst()
                .filter { !$0.hasPrefix("-") }
            if let first = paths.first, FileManager.default.fileExists(atPath: first) {
                windowController.open(URL(fileURLWithPath: first))
            } else {
                windowController.openFolderPanel()
            }
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.windowController?.runSelfTest()
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--shot"), i + 1 < CommandLine.arguments.count {
            // --shot 模式：跳过默认参数解析（避免弹出打开面板），按编排加载指定文件夹
            let outDir = CommandLine.arguments[i + 1]
            let folder = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if let folder, FileManager.default.fileExists(atPath: folder) {
                    self?.windowController?.open(URL(fileURLWithPath: folder))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.windowController?.runShotSequence(outDir: outDir)
            }
            return
        }
    }

    /// 从访达打开：空窗口直接用；已经在看照片时开新窗口（选中几张一起打开就是几个窗口，太多只开第一张）
    func application(_ application: NSApplication, open urls: [URL]) {
        #if FLIPIC_PRO
        for l in urls where l.scheme == "flipic" { _ = License.handle(url: l) }
        #endif
        // flipic:// 链接（付款后激活）不是文件
        let urls = urls.filter { $0.isFileURL }
        guard let first = urls.first else { return }
        guard windowController != nil else {
            pendingURL = first
            return
        }
        let batch = urls.count <= 6 ? urls : [first]
        for url in batch {
            if let wc = activeController, (wc.contentViewController as? ViewerViewController)?.isEmpty ?? true {
                wc.showWindow(nil)
                wc.open(url)
            } else if Self.openInNewWindow {
                newViewerWindow().open(url)
            } else {
                activeController?.showWindow(nil)
                activeController?.open(url)
            }
        }
    }

    /// 「打开方式」子菜单每次展开时按当前照片现列可用的软件
    func menuNeedsUpdate(_ menu: NSMenu) {
        activeViewer?.populateOpenWithMenu(menu)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - 菜单栏

    /// 可自定义快捷键对应的菜单项
    private static let shortcutMenuActions: [Selector: ShortcutAction] = [
        #selector(ViewerViewController.navigateBackward(_:)): .prev,
        #selector(ViewerViewController.navigateForward(_:)): .next,
        #selector(ViewerViewController.goFirst(_:)): .first,
        #selector(ViewerViewController.goLast(_:)): .last,
        #selector(ViewerViewController.rotateCW(_:)): .rotateCW,
        #selector(ViewerViewController.rotateCCW(_:)): .rotateCCW,
        #selector(ViewerViewController.toggleInfoPanel(_:)): .info,
        #selector(ViewerViewController.toggleFilmstrip(_:)): .filmstrip,
        #selector(ViewerViewController.toggleSlideshow(_:)): .slideshow,
        #selector(ViewerViewController.revealInFinder(_:)): .reveal,
        #selector(ViewerViewController.openInEditor(_:)): .edit,
        #selector(ViewerViewController.renameCurrent(_:)): .rename,
        #selector(ViewerViewController.saveRotation(_:)): .saveRotation,
        #selector(ViewerViewController.exportAs(_:)): .exportAs,
        #selector(ViewerViewController.exportToFolder(_:)): .exportFolder,
        #selector(ViewerViewController.trashCurrent(_:)): .trash,
        #selector(ViewerViewController.batchConvert(_:)): .batchConvert,
        #selector(ViewerViewController.batchRename(_:)): .batchRename,
        #selector(ViewerViewController.toggleCleanup(_:)): .cleanup,
        #selector(ViewerViewController.setWallpaper(_:)): .wallpaper,
    ]
    #if FLIPIC_PRO
    private static let proMenuActions: [Selector: ShortcutAction] = [
        #selector(ViewerViewController.toggleBeforeAfter(_:)): .beforeAfter,
        #selector(ViewerViewController.splitByRating(_:)): .splitByRating,
        #selector(ViewerViewController.switchPairMember(_:)): .switchPair,
    ]
    #endif

    // MARK: - 检查更新

    /// 打开了自动检查才会联网；启动几秒后再查，不和打开图片抢时间
    private func scheduleAutoUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            UpdateChecker.checkIfDue { release in
                self?.activeViewer?.showUpdateBanner(release)
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.check { result in
            let alert = NSAlert()
            switch result {
            case .newer(let r):
                alert.messageText = L10n.f("update.available", "Flipic %@ 可以更新了", r.version)
                alert.informativeText = L10n.f("update.availableInfoAuto", "你现在用的是 %@。点「立即更新」会自动下载、校验并替换，完成后重新打开，设置都会保留。", UpdateChecker.currentVersion)
                alert.addButton(withTitle: L10n.t("update.now", "立即更新"))
                alert.addButton(withTitle: L10n.t("update.later", "以后再说"))
                if alert.runModal() == .alertFirstButtonReturn { Updater.shared.install(r) }
            case .upToDate(let v):
                alert.messageText = L10n.f("update.upToDate", "已经是最新版本（%@）", v)
                alert.runModal()
            case .failed(let why):
                alert.messageText = L10n.t("update.failed", "暂时连不上官网，稍后再试")
                alert.informativeText = why
                alert.runModal()
            }
        }
    }

    /// 全局快捷键：Flipic 在最前面就收起来（回到刚才的软件），否则叫到最前面
    func toggleAppVisibility() {
        if NSApp.isActive && !NSApp.isHidden, controllers.contains(where: { $0.window?.isVisible == true }) {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            if let wc = activeController { wc.showWindow(nil) } else { newViewerWindow() }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 带 ⌘ / ⌥ / ⌃ 的自定义快捷键挂到菜单项上；单键由看图界面自己处理，菜单上不显示
    @objc private func applyShortcuts() {
        HotKey.update()
        func walk(_ menu: NSMenu) {
            for it in menu.items {
                if let sub = it.submenu { walk(sub) }
                guard let sel = it.action else { continue }
                #if FLIPIC_PRO
                let mapped = Self.shortcutMenuActions[sel] ?? Self.proMenuActions[sel]
                #else
                let mapped = Self.shortcutMenuActions[sel]
                #endif
                guard let action = mapped else { continue }
                if let c = Shortcuts.combo(for: action), c.isMenuCombo {
                    it.keyEquivalent = c.menuKey
                    it.keyEquivalentModifierMask = c.modifiers
                } else {
                    it.keyEquivalent = ""
                    it.keyEquivalentModifierMask = []
                }
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
    }

    private func buildMenu() {
        let main = NSMenu()

        func addMenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            main.addItem(item)
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
        }
        @discardableResult
        func item(_ menu: NSMenu, _ title: String, _ action: Selector?,
                  _ key: String = "", _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { it.keyEquivalentModifierMask = mask }
            menu.addItem(it)
            return it
        }

        addMenu(L10n.t("menu.about", "关于 Flipic")) { m in
            item(m, L10n.t("menu.about", "关于 Flipic"), #selector(ViewerViewController.showAbout(_:)))
            item(m, L10n.t("menu.checkUpdates", "检查更新…"), #selector(AppDelegate.checkForUpdates(_:))).target = self
            m.addItem(.separator())
            item(m, L10n.t("menu.settings", "设置…"), #selector(ViewerViewController.showSettings(_:)), ",")
            m.addItem(.separator())
            item(m, L10n.t("menu.hide", "隐藏 Flipic"), #selector(NSApplication.hide(_:)), "h")
            let hideOthers = item(m, L10n.t("menu.hideOthers", "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            item(m, L10n.t("menu.showAll", "全部显示"), #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.quit", "退出 Flipic"), #selector(NSApplication.terminate(_:)), "q")
        }
        addMenu(L10n.t("menu.file", "文件")) { m in
            item(m, L10n.t("menu.newWindow", "新建窗口"), #selector(AppDelegate.newWindowAction(_:)), "n").target = self
            item(m, L10n.t("menu.open", "打开…"), #selector(ViewerViewController.openFolderPanel(_:)), "o")
            item(m, L10n.t("menu.reveal", "在 Finder 中显示"), #selector(ViewerViewController.revealInFinder(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.editChoose", "在后期软件中编辑…"), #selector(ViewerViewController.openInEditor(_:)))
            let openWith = NSMenuItem(title: L10n.t("menu.openWith", "打开方式"), action: nil, keyEquivalent: "")
            let openWithMenu = NSMenu(title: openWith.title)
            openWithMenu.delegate = self
            openWith.submenu = openWithMenu
            m.addItem(openWith)
            let ratingItem = NSMenuItem(title: L10n.t("menu.rating", "评分"), action: nil, keyEquivalent: "")
            let ratingMenu = NSMenu(title: ratingItem.title)
            for n in stride(from: 5, through: 1, by: -1) {
                item(ratingMenu, Rating.stars(n), #selector(ViewerViewController.setRatingMenu(_:))).tag = n
            }
            ratingMenu.addItem(.separator())
            item(ratingMenu, L10n.t("rating.none", "未评分"), #selector(ViewerViewController.setRatingMenu(_:))).tag = 0
            ratingItem.submenu = ratingMenu
            m.addItem(ratingItem)
            item(m, L10n.t("menu.mark", "标记这张"), #selector(ViewerViewController.toggleMark(_:)))
            item(m, L10n.t("menu.markedOnly", "只看已标记"), #selector(ViewerViewController.toggleMarkedOnly(_:)))
            let filterItem = NSMenuItem(title: L10n.t("menu.ratingFilter", "只看星级"), action: nil, keyEquivalent: "")
            let filterMenu = NSMenu(title: filterItem.title)
            item(filterMenu, L10n.t("menu.ratingFilterAll", "全部照片"), #selector(ViewerViewController.setRatingFilter(_:))).tag = 0
            filterMenu.addItem(.separator())
            for n in stride(from: 5, through: 1, by: -1) {
                item(filterMenu, L10n.f("menu.ratingAtLeast", "%@及以上", String(repeating: "★", count: n)),
                     #selector(ViewerViewController.setRatingFilter(_:))).tag = n
            }
            filterItem.submenu = filterMenu
            m.addItem(filterItem)
            m.addItem(.separator())
            item(m, L10n.t("menu.rename", "重命名…"), #selector(ViewerViewController.renameCurrent(_:)))
            item(m, L10n.t("menu.saveRotation", "保存旋转"), #selector(ViewerViewController.saveRotation(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.exportAs", "导出为…"), #selector(ViewerViewController.exportAs(_:)))
            item(m, L10n.t("menu.exportFolder", "导出到文件夹…"), #selector(ViewerViewController.exportToFolder(_:)))
            #if FLIPIC_PRO
            let sendItem = NSMenuItem(title: L10n.t("menu.sendTo", "发送到"), action: nil, keyEquivalent: "")
            let sendMenu = NSMenu(title: sendItem.title)
            for i in 1...9 {
                let it = item(sendMenu, SendTo.menuTitle(i), #selector(ViewerViewController.sendToSlot(_:)), "\(i)", .option)
                it.tag = i
            }
            sendMenu.addItem(.separator())
            item(sendMenu, L10n.t("pro.sendMovesMenu", "发送时移动文件"), #selector(ViewerViewController.toggleSendToMoves(_:)))
            item(sendMenu, L10n.t("pro.sendSetup", "设置常用文件夹…"), #selector(ViewerViewController.showProSettings(_:)))
            sendItem.submenu = sendMenu
            m.addItem(sendItem)
            item(m, L10n.t("menu.splitByRating", "按星级分到子文件夹…"), #selector(ViewerViewController.splitByRating(_:)))
            item(m, L10n.t("menu.openAllInEditor", "全部在后期软件中打开…"), #selector(ViewerViewController.openAllInEditor(_:)))
            item(m, L10n.t("menu.trashUnmarked", "没标记的移到废纸篓…"), #selector(ViewerViewController.trashUnpicked(_:))).tag = 0
            item(m, L10n.t("menu.trashUnrated", "没评星的移到废纸篓…"), #selector(ViewerViewController.trashUnpicked(_:))).tag = 1
            item(m, L10n.t("menu.restoreTrash", "放回刚才删掉的照片"), #selector(ViewerViewController.restoreLastTrash(_:)))
            #endif
            m.addItem(.separator())
            item(m, L10n.t("menu.trash", "移到废纸篓"), #selector(ViewerViewController.trashCurrent(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.close", "关闭窗口"), #selector(NSWindow.performClose(_:)), "w")
        }
        addMenu(L10n.t("menu.view", "显示")) { m in
            item(m, L10n.t("menu.zoomIn", "放大"), #selector(ViewerViewController.zoomIn(_:)), "=")
            item(m, L10n.t("menu.zoomOut", "缩小"), #selector(ViewerViewController.zoomOut(_:)), "-")
            m.addItem(.separator())
            item(m, L10n.t("menu.actualSize", "实际大小 (100%)"), #selector(ViewerViewController.zoomActual(_:)), "1")
            item(m, L10n.t("menu.fit", "适应窗口"), #selector(ViewerViewController.zoomFit(_:)), "0")
            m.addItem(.separator())
            item(m, L10n.t("menu.rotateCW", "向右旋转 90°"), #selector(ViewerViewController.rotateCW(_:)))
            item(m, L10n.t("menu.rotateCCW", "向左旋转 90°"), #selector(ViewerViewController.rotateCCW(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.info", "照片信息"), #selector(ViewerViewController.toggleInfoPanel(_:)))
            item(m, L10n.t("menu.filmstrip", "缩略图栏"), #selector(ViewerViewController.toggleFilmstrip(_:)))
            item(m, L10n.t("menu.toolbar", "工具条"), #selector(ViewerViewController.toggleToolbar(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.compare2", "并排对比 2 张"), #selector(ViewerViewController.toggleCompare(_:)))
            item(m, L10n.t("menu.compare4", "并排对比 4 张"), #selector(ViewerViewController.toggleCompare4(_:)))
            item(m, L10n.t("menu.compareSync", "对比时同步缩放和位置"), #selector(ViewerViewController.toggleCompareSync(_:)))
            #if FLIPIC_PRO
            item(m, L10n.t("menu.beforeAfter", "修图前后对比"), #selector(ViewerViewController.toggleBeforeAfter(_:)))
            item(m, L10n.t("menu.mergePairs", "合并显示 JPG 和 RAW"), #selector(ViewerViewController.toggleMergePairs(_:)))
            item(m, L10n.t("menu.switchPair", "切换看 JPG / RAW"), #selector(ViewerViewController.switchPairMember(_:)))
            #endif
            item(m, L10n.t("menu.slideshow", "幻灯片放映"), #selector(ViewerViewController.toggleSlideshow(_:)))
            m.addItem(.separator())
            let sortItem = NSMenuItem(title: L10n.t("menu.sort", "排序方式"), action: nil, keyEquivalent: "")
            let sortMenu = NSMenu(title: sortItem.title)
            for key in SortKey.allCases {
                item(sortMenu, key.title, #selector(ViewerViewController.setSortKey(_:))).tag = key.rawValue
            }
            sortMenu.addItem(.separator())
            item(sortMenu, L10n.t("sort.descending", "倒序"), #selector(ViewerViewController.toggleSortReversed(_:)))
            sortItem.submenu = sortMenu
            m.addItem(sortItem)
            m.addItem(.separator())
            item(m, L10n.t("menu.fullscreen", "进入全屏"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])
        }
        addMenu(L10n.t("menu.go", "前往")) { m in
            item(m, L10n.t("menu.prev", "上一张"), #selector(ViewerViewController.navigateBackward(_:)))
            item(m, L10n.t("menu.next", "下一张"), #selector(ViewerViewController.navigateForward(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.first", "第一张"), #selector(ViewerViewController.goFirst(_:)))
            item(m, L10n.t("menu.last", "最后一张"), #selector(ViewerViewController.goLast(_:)))
        }
        addMenu(L10n.t("menu.tools", "工具")) { m in
            item(m, L10n.t("menu.batchConvert", "批量转换格式…"), #selector(ViewerViewController.batchConvert(_:)))
            item(m, L10n.t("menu.batchRename", "批量重命名…"), #selector(ViewerViewController.batchRename(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.cleanup", "清理模式 Beta"), #selector(ViewerViewController.toggleCleanup(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.wallpaper", "设为桌面壁纸"), #selector(ViewerViewController.setWallpaper(_:)))
        }
        addMenu(L10n.t("menu.window", "窗口")) { m in
            item(m, L10n.t("menu.miniaturize", "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")
            item(m, L10n.t("menu.windowZoom", "缩放"), #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.front", "前置全部窗口"), #selector(NSApplication.arrangeInFront(_:)))
        }

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: L10n.t("menu.help", "帮助"))
        helpMenu.addItem(NSMenuItem(title: L10n.t("menu.shortcuts", "快捷键说明"),
                                    action: #selector(ViewerViewController.showShortcuts(_:)),
                                    keyEquivalent: "/"))
        helpItem.submenu = helpMenu

        NSApp.mainMenu = main
        applyShortcuts()
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcuts),
                                               name: Shortcuts.didChange, object: nil)
        HotKey.onPress = { [weak self] in self?.toggleAppVisibility() }
        NSApp.windowsMenu = main.item(at: 5)?.submenu
        NSApp.helpMenu = helpMenu
    }
}

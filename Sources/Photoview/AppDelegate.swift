import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var windowController: ViewerWindowController!
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--cleanup-report"), i + 1 < CommandLine.arguments.count {
            CleanupDebug.report(folder: CommandLine.arguments[i + 1])
            return
        }
        buildMenu()
        windowController = ViewerWindowController()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let i = CommandLine.arguments.firstIndex(of: "--xhs-shots"), i + 2 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[i + 1]
            let folder = CommandLine.arguments[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.windowController?.open(URL(fileURLWithPath: folder))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.windowController?.runXhsShots(outDir: outDir) }
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let wc = windowController {
            wc.showWindow(nil)
            wc.open(url)
        } else {
            pendingURL = url
        }
    }

    /// 「打开方式」子菜单每次展开时按当前照片现列可用的软件
    func menuNeedsUpdate(_ menu: NSMenu) {
        (windowController?.contentViewController as? ViewerViewController)?.populateOpenWithMenu(menu)
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
        #selector(ViewerViewController.trashCurrent(_:)): .trash,
        #selector(ViewerViewController.batchConvert(_:)): .batchConvert,
        #selector(ViewerViewController.batchRename(_:)): .batchRename,
        #selector(ViewerViewController.toggleCleanup(_:)): .cleanup,
        #selector(ViewerViewController.setWallpaper(_:)): .wallpaper,
    ]

    // MARK: - 检查更新

    /// 打开了自动检查才会联网；启动几秒后再查，不和打开图片抢时间
    private func scheduleAutoUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            UpdateChecker.checkIfDue { release in
                (self?.windowController?.contentViewController as? ViewerViewController)?.showUpdateBanner(release)
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.check { result in
            let alert = NSAlert()
            switch result {
            case .newer(let r):
                alert.messageText = L10n.f("update.available", "Flipic %@ 可以更新了", r.version)
                alert.informativeText = L10n.f("update.availableInfo", "你现在用的是 %@。下载后把新版拖进「应用程序」替换即可，设置都会保留。", UpdateChecker.currentVersion)
                alert.addButton(withTitle: L10n.t("update.download", "下载新版"))
                alert.addButton(withTitle: L10n.t("update.later", "以后再说"))
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.download) }
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
        if NSApp.isActive && !NSApp.isHidden, windowController?.window?.isVisible == true {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            windowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 带 ⌘ / ⌥ / ⌃ 的自定义快捷键挂到菜单项上；单键由看图界面自己处理，菜单上不显示
    @objc private func applyShortcuts() {
        HotKey.update()
        func walk(_ menu: NSMenu) {
            for it in menu.items {
                if let sub = it.submenu { walk(sub) }
                guard let sel = it.action, let action = Self.shortcutMenuActions[sel] else { continue }
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
            m.addItem(.separator())
            item(m, L10n.t("menu.rename", "重命名…"), #selector(ViewerViewController.renameCurrent(_:)))
            item(m, L10n.t("menu.saveRotation", "保存旋转"), #selector(ViewerViewController.saveRotation(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.exportAs", "导出为…"), #selector(ViewerViewController.exportAs(_:)))
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

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

        if let i = CommandLine.arguments.firstIndex(of: "--zoomtest"), i + 1 < CommandLine.arguments.count {
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
            windowController.open(pending)
            pendingURL = nil
        } else {
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
            item(m, L10n.t("menu.reveal", "在 Finder 中显示"), #selector(ViewerViewController.revealInFinder(_:)), "r")
            m.addItem(.separator())
            item(m, L10n.t("menu.editChoose", "在后期软件中编辑…"), #selector(ViewerViewController.openInEditor(_:)), "e")
            let openWith = NSMenuItem(title: L10n.t("menu.openWith", "打开方式"), action: nil, keyEquivalent: "")
            let openWithMenu = NSMenu(title: openWith.title)
            openWithMenu.delegate = self
            openWith.submenu = openWithMenu
            m.addItem(openWith)
            item(m, L10n.t("menu.setEditor", "设置后期软件…"), #selector(ViewerViewController.chooseEditor(_:)))
            m.addItem(.separator())
            item(m, L10n.t("menu.rename", "重命名…"), #selector(ViewerViewController.renameCurrent(_:)), "\r")
            item(m, L10n.t("menu.saveRotation", "保存旋转"), #selector(ViewerViewController.saveRotation(_:)), "S", [.command, .option])
            m.addItem(.separator())
            item(m, L10n.t("menu.exportAs", "导出为…"), #selector(ViewerViewController.exportAs(_:)), "s")
            m.addItem(.separator())
            item(m, L10n.t("menu.trash", "移到废纸篓"), #selector(ViewerViewController.trashCurrent(_:)), "\u{8}")
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
            item(m, L10n.t("menu.fadeTransition", "翻页渐变"), #selector(ViewerViewController.toggleFadeTransition(_:)))
            let intervalItem = NSMenuItem(title: L10n.t("menu.slideInterval", "幻灯片间隔"), action: nil, keyEquivalent: "")
            let intervalMenu = NSMenu(title: intervalItem.title)
            for sec in ViewerViewController.slideshowIntervals {
                item(intervalMenu, L10n.f("slide.seconds", "%d 秒", sec), #selector(ViewerViewController.setSlideshowInterval(_:))).tag = sec
            }
            intervalItem.submenu = intervalMenu
            m.addItem(intervalItem)
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
            let wheelItem = NSMenuItem(title: L10n.t("menu.wheel", "鼠标滚轮"), action: nil, keyEquivalent: "")
            let wheelMenu = NSMenu(title: wheelItem.title)
            item(wheelMenu, L10n.t("wheel.zoom", "缩放图片"), #selector(ViewerViewController.setWheelAction(_:))).tag = 0
            item(wheelMenu, L10n.t("wheel.navigate", "切换上一张 / 下一张"), #selector(ViewerViewController.setWheelAction(_:))).tag = 1
            wheelItem.submenu = wheelMenu
            m.addItem(wheelItem)
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
            item(m, L10n.t("menu.batchConvert", "批量转换格式…"), #selector(ViewerViewController.batchConvert(_:)), "c", [.command, .shift])
            item(m, L10n.t("menu.batchRename", "批量重命名…"), #selector(ViewerViewController.batchRename(_:)), "b", [.command, .shift])
            m.addItem(.separator())
            item(m, L10n.t("menu.cleanup", "清理模式 Beta"), #selector(ViewerViewController.toggleCleanup(_:)), "k", [.command, .shift])
            m.addItem(.separator())
            item(m, L10n.t("menu.wallpaper", "设为桌面壁纸"), #selector(ViewerViewController.setWallpaper(_:)), "d", [.command, .shift])
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
        NSApp.windowsMenu = main.item(at: 5)?.submenu
        NSApp.helpMenu = helpMenu
    }
}

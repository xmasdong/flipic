import AppKit

final class ViewerWindowController: NSWindowController {
    /// 记窗口大小位置用的名字：沿用改名前的，保留老用户的窗口
    static let frameName = "PixDeckMainWindow"

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isOpaque = true
        window.minSize = NSSize(width: 640, height: 420)
        self.init(window: window)
        shouldCascadeWindows = false
        contentViewController = ViewerViewController()
        // 用上次的大小和位置；第一次打开才居中。要放在装内容之后：装内容时窗口会按内容视图的默认大小重设一次
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        // 自己存，不用系统的自动保存：一个名字同一时间只归一个窗口，关掉的窗口没释放前名字还占着，
        // 后开的窗口（访达里每双击一张就新开一个）改了大小也存不下来，下次双击又是默认大小
        let nc = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            nc.addObserver(self, selector: #selector(rememberFrame(_:)), name: name, object: window)
        }
        nc.addObserver(self, selector: #selector(fullScreenTransition(_:)), name: NSWindow.willEnterFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(fullScreenTransition(_:)), name: NSWindow.willExitFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(fullScreenTransition(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(fullScreenTransition(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
    }

    /// 进出全屏的动画过程中也会发调整大小，那时的大小不记
    private var inFullScreenTransition = false
    @objc private func fullScreenTransition(_ note: Notification) {
        inFullScreenTransition = note.name == NSWindow.willEnterFullScreenNotification || note.name == NSWindow.willExitFullScreenNotification
    }

    /// 记下普通窗口的大小和位置，下次打开沿用。全屏、最小化不记；
    /// 贴合照片比例的预览也不记（进入预览前的大小在那之前已经记过了）
    @objc private func rememberFrame(_ note: Notification) {
        guard let w = window, w.isVisible, !inFullScreenTransition, !w.styleMask.contains(.fullScreen), !w.isMiniaturized,
              viewerVC?.isPeeking != true else { return }
        w.saveFrame(usingName: Self.frameName)
    }

    private var viewerVC: ViewerViewController? { contentViewController as? ViewerViewController }
    /// 正在看的照片，工作台从它所在的文件夹打开
    var currentPhotoURL: URL? { viewerVC?.folder.current?.url }

    func runSelfTest() { viewerVC?.runSelfTest() }
    func runShotSequence(outDir: String) { viewerVC?.runShotSequence(outDir: outDir) }
    func runBrowseShots(outDir: String) { viewerVC?.runBrowseShots(outDir: outDir) }
    func runPeekTest(outDir: String) { viewerVC?.runPeekTest(outDir: outDir) }
    func runCleanupTest(outDir: String) { viewerVC?.runCleanupTest(outDir: outDir) }
    func runWheelTest() { viewerVC?.runWheelTest() }
    func runZoomFadeTest() { viewerVC?.runZoomFadeTest() }
    func runHUDTest(outDir: String) { viewerVC?.runHUDTest(outDir: outDir) }
    func runEscTest() { viewerVC?.runEscTest() }
    func runThumbTest(outDir: String) { viewerVC?.runThumbTest(outDir: outDir) }
    func runPanTest() { viewerVC?.runPanTest() }
    func runPauseTest() { viewerVC?.runPauseTest() }
    func runWindowDragTest() { viewerVC?.runWindowDragTest() }
    func runPeekKeepTest() { viewerVC?.runPeekKeepTest() }
    func runLiveTest(outDir: String) { viewerVC?.runLiveTest(outDir: outDir) }
    func runHDRTest() { viewerVC?.runHDRTest() }
    func runSlideStripTest(outDir: String) { viewerVC?.runSlideStripTest(outDir: outDir) }
    func runFadeSequence(outDir: String) { viewerVC?.runFadeSequence(outDir: outDir) }
    func runSlideFadeTest() { viewerVC?.runSlideFadeTest() }
    func runRatingTest() { viewerVC?.runRatingTest() }
    func runStarToggleTest() { viewerVC?.runStarToggleTest() }
    func runMarkTest(outDir: String) { viewerVC?.runMarkTest(outDir: outDir) }
    func runMultiSelectTest(outDir: String) { viewerVC?.runMultiSelectTest(outDir: outDir) }
    #if FLIPIC_PRO
    func runWorkbenchEntryTest(outDir: String) { viewerVC?.runWorkbenchEntryTest(outDir: outDir) }
    func runWorkbenchViewerTest(outDir: String) { viewerVC?.runWorkbenchViewerTest(outDir: outDir) }
    func runWorkbenchFocusTest(outDir: String) { viewerVC?.runWorkbenchFocusTest(outDir: outDir) }
    func runWorkbenchTrashRaceTest(outDir: String) { viewerVC?.runWorkbenchTrashRaceTest(outDir: outDir) }
    func runWorkbenchNoViewerTest(outDir: String) { viewerVC?.runWorkbenchNoViewerTest(outDir: outDir) }
    func runThemeShots(outDir: String) { viewerVC?.runThemeShots(outDir: outDir) }
    #endif
    func runCompareTest(outDir: String) { viewerVC?.runCompareTest(outDir: outDir) }
    func runPNGTest(outDir: String, folder: String) { viewerVC?.runPNGTest(outDir: outDir, folder: folder) }
    func runStraightenTest(outDir: String, folder: String) { viewerVC?.runStraightenTest(outDir: outDir, folder: folder) }
    func runPickedNavTest(outDir: String) { viewerVC?.runPickedNavTest(outDir: outDir) }
    func runRawTest(outDir: String) { viewerVC?.runRawTest(outDir: outDir) }
    func runZoomKeyTest() { viewerVC?.runZoomKeyTest() }
    func runExportTest(outDir: String) { viewerVC?.runExportTest(outDir: outDir) }
    func runRatingShot(outDir: String) { viewerVC?.runRatingShot(outDir: outDir) }
    func runSettingsTest(outDir: String) { viewerVC?.runSettingsTest(outDir: outDir) }
    func runXhsShots(outDir: String) { viewerVC?.runXhsShots(outDir: outDir) }
    func runSlideAndEditorTest(appPath: String) { viewerVC?.runSlideAndEditorTest(appPath: appPath) }

    func runBench(folder: String) {
        guard let vc = viewerVC else { return }
        BenchProbe.run(folder: folder, open: { url in
                           vc.open(url: url)
                           #if FLIPIC_PRO
                           // BENCH_INDEX=1：打开的同时开始按内容查找的后台分析（不读缓存），看翻页受不受影响
                           if ProcessInfo.processInfo.environment["BENCH_INDEX"] != nil { vc.startContentIndexIfNeeded(readCache: false) }
                           #endif
                       },
                       forward: { vc.navigateForward(nil) }, zoomActual: { vc.zoomActual(nil) },
                       state: { vc.debugZoomState }, hasImage: { vc.debugHasImage },
                       capture: { vc.debugCapture(to: $0) }, shownLevel: { vc.debugShownLevel })
    }

    func open(_ url: URL) { viewerVC?.open(url: url) }
    func open(urls: [URL]) { viewerVC?.open(urls: urls) }
    /// 显示这张：已经在看它所在的文件夹就直接翻过去，否则打开它
    func show(photo url: URL) { viewerVC?.show(photo: url) }
    func openFolderPanel() { viewerVC?.openFolderPanel(nil) }
}

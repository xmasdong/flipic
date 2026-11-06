import AppKit

final class ViewerWindowController: NSWindowController {

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
        // 沿用改名前的键，保留老用户的窗口大小和位置；第一次打开才居中。
        // 自动保存的名字要设在窗口控制器上：设在窗口上会被控制器自己的空名字盖掉，位置一直存不下来
        if !window.setFrameUsingName("PixDeckMainWindow") { window.center() }
        self.init(window: window)
        shouldCascadeWindows = false
        windowFrameAutosaveName = "PixDeckMainWindow"
        contentViewController = ViewerViewController()
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
    func runMarkTest(outDir: String) { viewerVC?.runMarkTest(outDir: outDir) }
    func runMultiSelectTest(outDir: String) { viewerVC?.runMultiSelectTest(outDir: outDir) }
    #if FLIPIC_PRO
    func runWorkbenchEntryTest(outDir: String) { viewerVC?.runWorkbenchEntryTest(outDir: outDir) }
    func runWorkbenchViewerTest(outDir: String) { viewerVC?.runWorkbenchViewerTest(outDir: outDir) }
    func runWorkbenchFocusTest(outDir: String) { viewerVC?.runWorkbenchFocusTest(outDir: outDir) }
    func runWorkbenchTrashRaceTest(outDir: String) { viewerVC?.runWorkbenchTrashRaceTest(outDir: outDir) }
    #endif
    func runCompareTest(outDir: String) { viewerVC?.runCompareTest(outDir: outDir) }
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
    /// 显示这张：已经在看它所在的文件夹就直接翻过去，否则打开它
    func show(photo url: URL) { viewerVC?.show(photo: url) }
    func openFolderPanel() { viewerVC?.openFolderPanel(nil) }
}

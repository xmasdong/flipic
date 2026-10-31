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
        window.setFrameAutosaveName("PixDeckMainWindow")  // 沿用改名前的键，保留老用户的窗口大小
        window.center()
        self.init(window: window)
        contentViewController = ViewerViewController()
    }

    private var viewerVC: ViewerViewController? { contentViewController as? ViewerViewController }

    func runSelfTest() { viewerVC?.runSelfTest() }
    func runShotSequence(outDir: String) { viewerVC?.runShotSequence(outDir: outDir) }
    func runBrowseShots(outDir: String) { viewerVC?.runBrowseShots(outDir: outDir) }
    func runPeekTest(outDir: String) { viewerVC?.runPeekTest(outDir: outDir) }
    func runCleanupTest(outDir: String) { viewerVC?.runCleanupTest(outDir: outDir) }
    func runWheelTest() { viewerVC?.runWheelTest() }
    func runZoomFadeTest() { viewerVC?.runZoomFadeTest() }
    func runHUDTest(outDir: String) { viewerVC?.runHUDTest(outDir: outDir) }
    func runSlideAndEditorTest(appPath: String) { viewerVC?.runSlideAndEditorTest(appPath: appPath) }

    func runBench(folder: String) {
        guard let vc = viewerVC else { return }
        BenchProbe.run(folder: folder, open: { vc.open(url: $0) },
                       forward: { vc.navigateForward(nil) }, zoomActual: { vc.zoomActual(nil) },
                       state: { vc.debugZoomState })
    }

    func open(_ url: URL) { viewerVC?.open(url: url) }
    func openFolderPanel() { viewerVC?.openFolderPanel(nil) }
}

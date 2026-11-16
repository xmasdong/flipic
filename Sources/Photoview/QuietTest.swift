import AppKit
import ObjectiveC

/// 自测时不打扰正在用电脑的人：环境变量 FLIPIC_QUIET_TEST=1 时，
/// 不进程序坞、不抢前台、所有窗口压在桌面图标下面（别的窗口都盖在它上面）。
/// 截图用的是按窗口号取图，窗口被盖住也能截到，所以测试结果不变。正常启动时这里什么都不做
enum QuietTest {
    static let on = ProcessInfo.processInfo.environment["FLIPIC_QUIET_TEST"] == "1"
    /// 桌面壁纸之上、桌面图标之下
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    private static var observer: NSObjectProtocol?

    static func installIfNeeded() {
        guard on else { return }
        // 把「激活程序」的两个入口换成空操作，测试代码和正常流程里的 NSApp.activate 都不会把它拉到前台
        swap(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.quiet_activate(ignoringOtherApps:)))
        if #available(macOS 14.0, *) {
            swap(NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void), #selector(NSApplication.quiet_activateNow))
        }
        // 每个窗口（包括确认框、表单）一出现就压到最底层
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: nil) { note in
            guard let w = note.object as? NSWindow, w.level != level, w.parent == nil, !(w is NSPanel && w.className.contains("Menu")) else { return }
            w.level = level
            w.collectionBehavior.insert(.stationary)
        }
    }

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let ma = class_getInstanceMethod(cls, a), let mb = class_getInstanceMethod(cls, b) else { return }
        method_exchangeImplementations(ma, mb)
    }
}

extension NSApplication {
    @objc fileprivate func quiet_activate(ignoringOtherApps flag: Bool) {}
    @objc fileprivate func quiet_activateNow() {}
}

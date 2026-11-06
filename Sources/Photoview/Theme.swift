import AppKit

/// 设置 › 通用 › 外观：深色（默认）、浅色、跟随系统。
/// 换的是窗口外框：工作台的侧栏、宫格、检查器，设置、关于、反馈、更新窗口和弹出的对话框。
/// 照片底下（看图窗口、工作台的大图 / 单张 / 对比）一直是深色，看曝光和颜色不受影响
enum Theme {
    enum Mode: Int { case dark, light, system }

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.integer(forKey: "appearanceMode")) ?? .dark }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearanceMode")
            apply()
        }
    }

    /// 启动时和改设置时调用；跟随系统时交给系统，系统切换深浅色时窗口自己跟着变
    static func apply() {
        switch mode {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
        startObserving()
        repaint()
    }

    /// 深浅两套取值的颜色，交给 NSColor 的地方（窗口底色、文字）会自己跟着外观变
    static func color(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static func gray(dark: CGFloat, light: CGFloat) -> NSColor {
        color(dark: NSColor(calibratedWhite: dark, alpha: 1), light: NSColor(calibratedWhite: light, alpha: 1))
    }

    /// 深色时是白色叠一层、浅色时是黑色叠一层：悬停、选中、描边
    static func overlay(_ alpha: CGFloat) -> NSColor {
        color(dark: NSColor(white: 1, alpha: alpha), light: NSColor(white: 0, alpha: alpha * 0.8))
    }

    // MARK: - 图层颜色

    /// layer 上的颜色是 CGColor，外观变了不会自己变：登记在这里，外观一变按各自视图的外观重新取一遍
    private struct Paint { var background: NSColor?; var border: NSColor? }
    private static let painted = NSMapTable<NSView, Box>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private final class Box { var paint: Paint; init(_ p: Paint) { paint = p } }

    static func paint(_ view: NSView, background: NSColor? = nil, border: NSColor? = nil) {
        view.wantsLayer = true
        let box = painted.object(forKey: view) ?? Box(Paint())
        if let background { box.paint.background = background }
        if let border { box.paint.border = border }
        painted.setObject(box, forKey: view)
        resolve(view, box.paint)
    }

    /// 视图挪进了外观不同的窗口（看图窗口一直是深色）时重新取一遍，在 viewDidChangeEffectiveAppearance 里调
    static func refresh(_ view: NSView) {
        if let b = painted.object(forKey: view) { resolve(view, b.paint) }
    }

    private static func resolve(_ view: NSView, _ p: Paint) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = p.background { view.layer?.backgroundColor = c.cgColor }
            if let c = p.border { view.layer?.borderColor = c.cgColor }
        }
    }

    static func repaint() {
        guard let e = painted.keyEnumerator().allObjects as? [NSView] else { return }
        for v in e { if let b = painted.object(forKey: v) { resolve(v, b.paint) } }
    }

    private static var observer: NSKeyValueObservation?
    private static func startObserving() {
        guard observer == nil else { return }
        // 跟随系统时系统切换深浅色，NSApp 的外观会变；手动改设置也走这里
        observer = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { repaint() }
        }
    }
}

import AppKit

/// 看图界面底部的旋转条，两种状态：
/// 裁剪与拉直中：上面一行比例 + 横竖互换 + 输出尺寸，下面一行滑块 + 角度 + 归零 / 取消 / 完成；
/// 改过还没保存：提示 + 还原 / 保存…
final class RotationBar: NSVisualEffectView {
    var onDegrees: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?
    var onRevert: (() -> Void)?
    var onSave: (() -> Void)?
    /// 选了比例 / 点了横竖互换
    var onAspect: ((CropGeometry.Aspect) -> Void)?
    var onSwap: (() -> Void)?

    private let slider = NSSlider(value: 0, minValue: -Straighten.maxDegrees, maxValue: Straighten.maxDegrees, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "0.0°")
    private var straightenRow: NSStackView!
    private var cropRow: NSStackView!
    private var pendingRow: NSStackView!
    private var outer: NSStackView!
    /// 别的工具借这条用的一行（加边框）
    private var extraRow: NSView?
    /// 比例选择：一个显示当前比例的按钮，点开是菜单（每个比例后面带一句淡淡的用途说明）
    private let aspectButton = NSButton()
    private var currentAspect = CropGeometry.Aspect.original
    private var currentSwapped = false
    /// 刚弹出的自定义比例对话框（测试用）
    private(set) weak var customAlert: NSAlert?
    private let swapButton = NSButton()
    #if FLIPIC_PRO
    /// 切图（Pro）：裁剪 | 切图 开关和切图的几个控件。开源版没有这一块
    let splitUI = SplitBarUI()
    /// 选了切图 / 回到裁剪（Pro 检查已通过）
    var onSplitMode: ((Bool) -> Void)?
    private var aspectViews: [NSView] = []
    #endif
    private let sizeLabel = NSTextField(labelWithString: "")
    /// 菜单里的顺序；自定义最后，前面有分隔线
    static let aspectOrder: [CropGeometry.Aspect] = [.original, .free, .square, .r4x5, .r3x4, .r2x3, .r3x2, .r16x9, .r9x16, .custom]

    /// 比例的写法；swapped 时写成反过来的（4:5 → 5:4）
    static func title(_ aspect: CropGeometry.Aspect, swapped: Bool) -> String {
        let fixed: (Int, Int)
        switch aspect {
        case .original: return L10n.t("crop.original", "原比例")
        case .free: return L10n.t("crop.free", "自由")
        case .square: return "1:1"
        case .r4x5: fixed = (4, 5)
        case .r3x4: fixed = (3, 4)
        case .r2x3: fixed = (2, 3)
        case .r3x2: fixed = (3, 2)
        case .r16x9: fixed = (16, 9)
        case .r9x16: fixed = (9, 16)
        case .custom: fixed = (CropMemory.customWidth, CropMemory.customHeight)
        }
        return swapped ? "\(fixed.1):\(fixed.0)" : "\(fixed.0):\(fixed.1)"
    }

    /// 说明在菜单里统一从这一列开始（点）：比最宽的比例「16:9」宽一点
    static let hintColumn: CGFloat = 52

    /// 比例 + 制表位 + 淡淡的说明：所有说明对齐在同一列，不随比例文字的长短错开
    static func titleWithHint(_ ratio: String, hint: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: hintColumn)]
        style.defaultTabInterval = hintColumn
        let t = NSMutableAttributedString(string: ratio + "\t", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        t.append(NSAttributedString(string: hint, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                               .paragraphStyle: style]))
        return t
    }

    /// 测试用：说明文字起点离标题左边多远（点），用排版算出来；没有说明的项是 nil
    static func debugHintStartX(_ title: NSAttributedString) -> CGFloat? {
        guard let tab = title.string.firstIndex(of: "\t") else { return nil }
        let storage = NSTextStorage(attributedString: title)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 100))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let hintIndex = title.string.distance(from: title.string.startIndex, to: title.string.index(after: tab))
        let glyph = manager.glyphIndexForCharacter(at: hintIndex)
        return manager.location(forGlyphAt: glyph).x + manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
    }

    /// 菜单里比例后面的一句话；原比例、自由、自定义没有
    static func hint(_ aspect: CropGeometry.Aspect) -> String? {
        switch aspect {
        case .square: return L10n.t("crop.hint.1x1", "方图")
        case .r4x5: return L10n.t("crop.hint.4x5", "Instagram 竖图")
        case .r3x4: return L10n.t("crop.hint.3x4", "小红书竖图")
        case .r2x3: return L10n.t("crop.hint.2x3", "照片冲印")
        case .r3x2: return L10n.t("crop.hint.3x2", "相机原生")
        case .r16x9: return L10n.t("crop.hint.16x9", "横屏视频")
        case .r9x16: return L10n.t("crop.hint.9x16", "竖屏 / 壁纸")
        default: return nil
        }
    }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        let title = Self.label(L10n.t("rot.bar.straighten", "拉直"), bold: true)
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        slider.toolTip = L10n.t("rot.bar.hint", "← → 微调 0.1°，按住 ⇧ 每次 1°")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let hint = Self.label(L10n.t("rot.bar.hint", "← → 微调 0.1°，按住 ⇧ 每次 1°"), bold: false)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let reset = Self.button(L10n.t("rot.bar.reset", "归零"), #selector(resetClicked), self)
        let cancel = Self.button(L10n.t("rot.bar.cancel", "取消"), #selector(cancelClicked), self)
        let done = Self.button(L10n.t("rot.bar.done", "完成"), #selector(doneClicked), self)
        done.bezelColor = .controlAccentColor
        straightenRow = NSStackView(views: [title, slider, valueLabel, hint, reset, cancel, done])
        straightenRow.setCustomSpacing(16, after: hint)

        let aspectTitle = Self.label(L10n.t("rot.bar.aspect", "比例"), bold: true)
        aspectButton.bezelStyle = .rounded
        aspectButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        aspectButton.imagePosition = .imageTrailing
        aspectButton.title = Self.title(.original, swapped: false)
        aspectButton.setAccessibilityLabel(L10n.t("rot.bar.aspect", "比例"))
        aspectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        aspectButton.target = self
        aspectButton.action = #selector(aspectClicked)
        swapButton.bezelStyle = .rounded
        swapButton.image = NSImage(systemSymbolName: "rectangle.portrait.rotate", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        swapButton.imagePosition = .imageOnly
        swapButton.title = ""
        swapButton.toolTip = L10n.t("crop.swap", "横竖互换")
        swapButton.setAccessibilityLabel(L10n.t("crop.swap", "横竖互换"))
        swapButton.target = self
        swapButton.action = #selector(swapClicked)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        cropRow = NSStackView(views: [aspectTitle, aspectButton, swapButton, gap, sizeLabel])
        #if FLIPIC_PRO
        aspectViews = [aspectTitle, aspectButton, swapButton]
        cropRow.insertArrangedSubview(splitUI.modeView, at: 0)
        cropRow.setCustomSpacing(16, after: splitUI.modeView)
        for v in splitUI.splitViews {
            v.isHidden = true
            cropRow.insertArrangedSubview(v, at: cropRow.arrangedSubviews.count - 2)
        }
        splitUI.window = { [weak self] in self?.window }
        splitUI.onMode = { [weak self] on in
            self?.applySplitVisibility(on)
            self?.onSplitMode?(on)
        }
        #endif

        let pendingTitle = Self.label(L10n.t("rot.bar.pending", "修改还没保存"), bold: false)
        let revert = Self.button(L10n.t("rot.bar.revert", "还原"), #selector(revertClicked), self)
        let save = Self.button(L10n.t("rot.save", "保存…"), #selector(saveClicked), self)
        save.bezelColor = .controlAccentColor
        pendingRow = NSStackView(views: [pendingTitle, revert, save])
        pendingRow.setCustomSpacing(16, after: pendingTitle)

        for row in [straightenRow!, cropRow!, pendingRow!] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
        }
        // 几行放进同一个竖排的 stack：隐藏的行不占位置，条的宽度跟着当前最宽的那行走
        outer = NSStackView(views: [cropRow, straightenRow, pendingRow])
        outer.orientation = .vertical
        outer.alignment = .width
        outer.spacing = 8
        outer.detachesHiddenViews = true
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func label(_ s: String, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    static func button(_ title: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        return b
    }

    /// 拉直中
    var isStraightening: Bool { !isHidden && !straightenRow.isHidden }

    /// 整条换成 row（加边框）；nil = 拿掉、收起
    func showExtra(_ row: NSView?) {
        extraRow?.removeFromSuperview()
        extraRow = row
        if let row { outer.addArrangedSubview(row) }
        for r in [straightenRow!, cropRow!, pendingRow!] { r.isHidden = true }
        isHidden = row == nil
    }

    func showStraighten(degrees: Double) {
        #if FLIPIC_PRO
        splitUI.refreshProMark()
        #endif
        setDegrees(degrees)
        straightenRow.isHidden = false
        cropRow.isHidden = false
        pendingRow.isHidden = true
        isHidden = false
    }

    /// pending = true 显示「修改还没保存」，否则整条收起
    func showPending(_ pending: Bool) {
        guard extraRow == nil else { return }
        straightenRow.isHidden = true
        cropRow.isHidden = true
        pendingRow.isHidden = false
        isHidden = !pending
    }

    func setDegrees(_ d: Double) {
        slider.doubleValue = d
        valueLabel.stringValue = String(format: "%.1f°", d)
    }

    /// 选中的比例；swapped 时把它写成反过来的，互换按钮只在换了有区别的比例上能点
    func setAspect(_ aspect: CropGeometry.Aspect, swapped: Bool) {
        currentAspect = aspect
        currentSwapped = swapped
        aspectButton.title = Self.title(aspect, swapped: swapped)
        swapButton.isEnabled = aspect.swappable
    }

    #if FLIPIC_PRO
    private func applySplitVisibility(_ split: Bool) {
        for v in aspectViews { v.isHidden = split }
        for v in splitUI.splitViews { v.isHidden = !split }
    }

    /// 进裁剪时总是从「裁剪」开始
    func resetSplitMode() {
        splitUI.setMode(split: false)
        applySplitVisibility(false)
    }

    /// 切图时右边显示的一句话（几张、每张多大）
    func setSplitSummary(_ text: String) { sizeLabel.stringValue = text }
    #endif

    /// 输出的像素尺寸，比如 4000 × 5000
    func setOutputSize(_ size: CGSize) {
        sizeLabel.stringValue = size.width > 0 ? "\(Int(size.width)) × \(Int(size.height))" : ""
    }

    /// 比例菜单；当前的打勾
    func makeAspectMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for a in Self.aspectOrder {
            if a == .custom { menu.addItem(.separator()) }
            let item = NSMenuItem(title: a == .custom ? L10n.t("crop.custom", "自定义…") : Self.title(a, swapped: false), action: #selector(aspectPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = a.rawValue
            if let hint = Self.hint(a) { item.attributedTitle = Self.titleWithHint(item.title, hint: hint) }
            if a == currentAspect { item.state = .on }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func aspectClicked() {
        let menu = makeAspectMenu()
        // 菜单贴在按钮下沿往上展开时选中项对齐按钮：直接从按钮上沿弹出
        menu.popUp(positioning: menu.item(withTag: currentAspect.rawValue), at: NSPoint(x: 0, y: aspectButton.bounds.height + 2), in: aspectButton)
    }

    @objc private func aspectPicked(_ sender: NSMenuItem) {
        guard let a = CropGeometry.Aspect(rawValue: sender.tag) else { return }
        select(a)
    }

    private func select(_ a: CropGeometry.Aspect) {
        if a == .custom { askCustom() } else { onAspect?(a) }
    }

    /// 自定义比例：宽、高两个小输入框（1…100 的整数），不合法时「应用」点不了
    private func askCustom() {
        let alert = NSAlert()
        alert.messageText = L10n.t("crop.custom.title", "自定义比例")
        alert.informativeText = L10n.t("crop.custom.info", "宽和高各填 1 到 100 的整数")
        let apply = alert.addButton(withTitle: L10n.t("crop.custom.apply", "应用"))
        let cancel = alert.addButton(withTitle: L10n.t("rot.bar.cancel", "取消"))
        cancel.keyEquivalent = "\u{1b}"
        let sheet = CustomRatioFields(width: CropMemory.customWidth, height: CropMemory.customHeight) { ok in apply.isEnabled = ok }
        alert.accessoryView = sheet
        alert.window.initialFirstResponder = sheet.widthField
        customAlert = alert
        let confirm = { [weak self, weak sheet] (code: NSApplication.ModalResponse) in
            guard code == .alertFirstButtonReturn, let sheet, let v = sheet.value,
                  CropMemory.setCustom(width: v.w, height: v.h) else { return }
            self?.onAspect?(.custom)
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: confirm) } else { confirm(alert.runModal()) }
    }

    @objc private func swapClicked() { onSwap?() }

    /// 测试用：像在菜单里选了这个比例（自定义会弹出对话框）
    func debugSelectAspect(_ aspect: CropGeometry.Aspect) { select(aspect) }

    var debugCrop: String {
        "aspect=\(aspectButton.title) swap=\(swapButton.isEnabled ? 1 : 0) size=\(sizeLabel.stringValue)"
    }

    /// 测试用：菜单上每一项的文字和打勾情况
    var debugMenuItems: [(title: String, checked: Bool)] {
        makeAspectMenu().items.filter { !$0.isSeparatorItem }.map { ($0.attributedTitle?.string ?? $0.title, $0.state == .on) }
    }

    /// 测试用：菜单里每一项的富文本标题（没有就是普通标题）
    var debugMenuAttributedTitles: [NSAttributedString] {
        makeAspectMenu().items.filter { !$0.isSeparatorItem }.map { $0.attributedTitle ?? NSAttributedString(string: $0.title) }
    }

    /// 测试用：像点了按钮那样弹出菜单；0.8 秒后调 onShown（此时菜单在屏幕上），再把菜单收起。
    /// 返回 onShown 有没有赶上菜单还开着（程序不在前台时系统可能很快收掉，调用方可以重试）
    @discardableResult
    func debugPopMenu(onShown: @escaping (NSMenu) -> Void) -> Bool {
        let menu = makeAspectMenu()
        var shown = false
        let t = Timer(timeInterval: 0.8, repeats: false) { _ in
            shown = true
            onShown(menu)
            menu.cancelTracking()
        }
        RunLoop.main.add(t, forMode: .common)
        menu.popUp(positioning: menu.item(withTag: currentAspect.rawValue), at: NSPoint(x: 0, y: aspectButton.bounds.height + 2), in: aspectButton)
        t.invalidate()
        return shown
    }

    @objc private func sliderMoved() {
        // 0° 附近吸一下，拖回水平容易
        var d = (slider.doubleValue * 10).rounded() / 10
        if abs(d) < 0.25 { d = 0 }
        valueLabel.stringValue = String(format: "%.1f°", d)
        onDegrees?(d)
    }

    @objc private func resetClicked() { onReset?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func doneClicked() { onDone?() }
    @objc private func revertClicked() { onRevert?() }
    @objc private func saveClicked() { onSave?() }

    var debugRow: String { isHidden ? "hidden" : (straightenRow.isHidden ? "pending" : "straighten") }
}

/// 自定义比例对话框里的「宽 : 高」两个小输入框；两个都是 1…100 的整数才算合法
final class CustomRatioFields: NSView, NSTextFieldDelegate {
    let widthField = NSTextField(string: ""), heightField = NSTextField(string: "")
    private let onValid: (Bool) -> Void
    private let parse: (String, String) -> (w: Int, h: Int)?

    init(width: Int, height: Int, parse: @escaping (String, String) -> (w: Int, h: Int)? = { CropMemory.parseCustom(width: $0, height: $1) },
         onValid: @escaping (Bool) -> Void) {
        self.onValid = onValid
        self.parse = parse
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13)
            return l
        }
        for (f, v, id) in [(widthField, width, "cropCustomW"), (heightField, height, "cropCustomH")] {
            f.stringValue = String(v)
            f.alignment = .center
            f.delegate = self
            f.setAccessibilityIdentifier(id)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        let colon = label(":")
        let row = NSStackView(views: [label(L10n.t("crop.custom.w", "宽")), widthField, colon, label(L10n.t("crop.custom.h", "高")), heightField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var value: (w: Int, h: Int)? { parse(widthField.stringValue, heightField.stringValue) }

    private func report() { onValid(value != nil) }

    func controlTextDidChange(_ obj: Notification) { report() }
}

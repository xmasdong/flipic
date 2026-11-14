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
    private let aspectControl = NSSegmentedControl()
    private let swapButton = NSButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    /// 各个比例的写法；选中的那个横竖互换后写成反过来的（4:5 → 5:4）
    private static let aspectTitles: [(CropGeometry.Aspect, String, String)] = [
        (.original, L10n.t("crop.original", "原比例"), L10n.t("crop.original", "原比例")),
        (.free, L10n.t("crop.free", "自由"), L10n.t("crop.free", "自由")),
        (.square, "1:1", "1:1"), (.r4x5, "4:5", "5:4"), (.r3x2, "3:2", "2:3"), (.r16x9, "16:9", "9:16"),
    ]

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
        aspectControl.segmentCount = Self.aspectTitles.count
        aspectControl.trackingMode = .selectOne
        aspectControl.segmentStyle = .rounded
        aspectControl.segmentDistribution = .fit
        for (i, t) in Self.aspectTitles.enumerated() { aspectControl.setLabel(t.1, forSegment: i) }
        aspectControl.selectedSegment = 0
        aspectControl.target = self
        aspectControl.action = #selector(aspectChanged)
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
        cropRow = NSStackView(views: [aspectTitle, aspectControl, swapButton, gap, sizeLabel])

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
        let outer = NSStackView(views: [cropRow, straightenRow, pendingRow])
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

    private static func label(_ s: String, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    private static func button(_ title: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        return b
    }

    /// 拉直中
    var isStraightening: Bool { !isHidden && !straightenRow.isHidden }

    func showStraighten(degrees: Double) {
        setDegrees(degrees)
        straightenRow.isHidden = false
        cropRow.isHidden = false
        pendingRow.isHidden = true
        isHidden = false
    }

    /// pending = true 显示「修改还没保存」，否则整条收起
    func showPending(_ pending: Bool) {
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
        for (i, t) in Self.aspectTitles.enumerated() {
            aspectControl.setLabel(t.0 == aspect && swapped ? t.2 : t.1, forSegment: i)
            if t.0 == aspect { aspectControl.selectedSegment = i }
        }
        swapButton.isEnabled = aspect.swappable
    }

    /// 输出的像素尺寸，比如 4000 × 5000
    func setOutputSize(_ size: CGSize) {
        sizeLabel.stringValue = size.width > 0 ? "\(Int(size.width)) × \(Int(size.height))" : ""
    }

    @objc private func aspectChanged() {
        let i = aspectControl.selectedSegment
        guard Self.aspectTitles.indices.contains(i) else { return }
        onAspect?(Self.aspectTitles[i].0)
    }

    @objc private func swapClicked() { onSwap?() }

    /// 测试用：像点了比例那一格一样
    func debugSelectAspect(_ aspect: CropGeometry.Aspect) {
        guard let i = Self.aspectTitles.firstIndex(where: { $0.0 == aspect }) else { return }
        aspectControl.selectedSegment = i
        aspectChanged()
    }

    var debugCrop: String {
        let i = aspectControl.selectedSegment
        return "aspect=\(i >= 0 ? aspectControl.label(forSegment: i) ?? "-" : "-") swap=\(swapButton.isEnabled ? 1 : 0) size=\(sizeLabel.stringValue)"
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

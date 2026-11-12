import AppKit

/// 看图界面底部的旋转条，两种状态：
/// 拉直中：滑块 + 角度 + 归零 / 取消 / 完成；转过还没保存：提示 + 还原 / 保存…
final class RotationBar: NSVisualEffectView {
    var onDegrees: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?
    var onRevert: (() -> Void)?
    var onSave: (() -> Void)?

    private let slider = NSSlider(value: 0, minValue: -Straighten.maxDegrees, maxValue: Straighten.maxDegrees, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "0.0°")
    private var straightenRow: NSStackView!
    private var pendingRow: NSStackView!

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

        let pendingTitle = Self.label(L10n.t("rot.bar.pending", "旋转还没保存"), bold: false)
        let revert = Self.button(L10n.t("rot.bar.revert", "还原"), #selector(revertClicked), self)
        let save = Self.button(L10n.t("rot.save", "保存…"), #selector(saveClicked), self)
        save.bezelColor = .controlAccentColor
        pendingRow = NSStackView(views: [pendingTitle, revert, save])
        pendingRow.setCustomSpacing(16, after: pendingTitle)

        for row in [straightenRow!, pendingRow!] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
        }
        // 两行放进同一个竖排的 stack：隐藏的那行不占位置，条的宽度跟着当前这行走
        let outer = NSStackView(views: [straightenRow, pendingRow])
        outer.orientation = .vertical
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
        pendingRow.isHidden = true
        isHidden = false
    }

    /// pending = true 显示「旋转还没保存」，否则整条收起
    func showPending(_ pending: Bool) {
        straightenRow.isHidden = true
        pendingRow.isHidden = false
        isHidden = !pending
    }

    func setDegrees(_ d: Double) {
        slider.doubleValue = d
        valueLabel.stringValue = String(format: "%.1f°", d)
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

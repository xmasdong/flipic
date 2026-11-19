import AppKit

/// 保存修改（裁剪、拉直、旋转）时顺带选输出尺寸，比如裁成 3:4 发小红书时直接存成长边 1440。
/// 只用于「另存一份」：原图永远保持原尺寸，选了会缩小的尺寸时「覆盖原图」点不了。不放大：裁出来已经比所选的小，就按原样存。
/// 记住上次选的尺寸（连着存一组照片时方便）；记住了「以后都这样保存」、不弹框的保存一律按原尺寸
enum SaveSize {
    enum Choice: Equatable {
        case original
        case preset(Int)
        case custom(Int)

        var longEdge: Int? {
            switch self {
            case .original: return nil
            case .preset(let e), .custom(let e): return e
            }
        }
    }

    static let presets = [4096, 2560, 2048, 1440, 1080]
    static let minEdge = 64

    /// 测试用：换成临时的偏好设置，不碰真实的
    static var defaults: UserDefaults = .standard
    private static let choiceKey = "rotationSaveSize", customKey = "rotationSaveCustomEdge"

    /// 自定义的长边，没设过是 2000
    static var customEdge: Int {
        get { let v = defaults.integer(forKey: customKey); return v >= minEdge ? v : 2000 }
        set { defaults.set(max(minEdge, newValue), forKey: customKey) }
    }

    /// 上次在保存对话框里选的尺寸
    static var last: Choice {
        get {
            let s = defaults.string(forKey: choiceKey) ?? ""
            if s == "custom" { return .custom(customEdge) }
            if let v = Int(s), presets.contains(v) { return .preset(v) }
            return .original
        }
        set {
            switch newValue {
            case .original: defaults.set("original", forKey: choiceKey)
            case .preset(let e): defaults.set(String(e), forKey: choiceKey)
            case .custom(let e): customEdge = e; defaults.set("custom", forKey: choiceKey)
            }
        }
    }

    /// 真的会缩小时返回长边，否则 nil（原尺寸、或裁出来已经不比所选的大：不放大）
    static func shrinkEdge(native: CGSize, choice: Choice) -> Int? {
        guard let e = choice.longEdge, e >= minEdge, CGFloat(e) < max(native.width, native.height) else { return nil }
        return e
    }

    /// 存出来的像素尺寸。取整和 ImageExporter.scaled 一样（长边正好等于所选，短边四舍五入）
    static func output(native: CGSize, choice: Choice) -> CGSize {
        guard let e = shrinkEdge(native: native, choice: choice) else { return native }
        let w = Int(native.width), h = Int(native.height)
        let s = Double(e) / Double(max(w, h))
        return w >= h ? CGSize(width: e, height: max(1, Int((Double(h) * s).rounded())))
                      : CGSize(width: max(1, Int((Double(w) * s).rounded())), height: e)
    }

    static func text(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }
}

/// 保存对话框里的「尺寸：」一行：弹出菜单、自定义时的像素框、存出来的尺寸，下面一行说明。
/// 管着对话框的「覆盖原图」按钮和「以后都这样保存」勾选框：会缩小时前者点不了、回车改成「另存一份」，后者勾不了
final class SaveSizeRow: NSObject, NSTextFieldDelegate {
    /// 测试用：正在显示的那一行
    static weak var current: SaveSizeRow?

    let native: CGSize
    let view = NSView()
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let field = NSTextField()
    let pxLabel = NSTextField(labelWithString: "px")
    let result = NSTextField(labelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    private(set) weak var overwriteButton: NSButton?
    private(set) weak var copyButton: NSButton?
    private(set) weak var rememberButton: NSButton?

    private static let customTag = 1

    init(native: CGSize, initial: SaveSize.Choice = SaveSize.last) {
        self.native = native
        super.init()
        let label = NSTextField(labelWithString: L10n.t("rot.size.label", "尺寸："))
        popup.addItem(withTitle: L10n.t("rot.size.original", "原尺寸"))
        popup.lastItem?.representedObject = 0
        popup.menu?.addItem(.separator())
        for e in SaveSize.presets {
            popup.addItem(withTitle: L10n.f("rot.size.long", "长边 %@", String(e)))
            popup.lastItem?.representedObject = e
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: L10n.t("rot.size.custom", "自定义…"))
        popup.lastItem?.tag = Self.customTag
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.setAccessibilityIdentifier("saveSizePopup")

        field.stringValue = String(SaveSize.customEdge)
        field.alignment = .right
        field.delegate = self
        field.setAccessibilityIdentifier("saveSizeCustom")
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        pxLabel.textColor = .secondaryLabelColor
        result.textColor = .secondaryLabelColor
        result.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let row = NSStackView(views: [label, popup, field, pxLabel, result])
        row.orientation = .horizontal
        row.spacing = 6
        row.setCustomSpacing(12, after: pxLabel)
        row.setCustomSpacing(12, after: popup)
        let stack = NSStackView(views: [row, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
        ])

        // 先按最宽的样子（自定义、五位数的尺寸、说明那行有字）量好大小，对话框打开后切换选项时不跳
        field.isHidden = false; pxLabel.isHidden = false
        result.stringValue = L10n.f("rot.size.result", "导出 %@", "88888 × 88888") + L10n.t("rot.size.noUpscale", "，不放大")
        let rowWidth = max(320, row.fittingSize.width)
        note.preferredMaxLayoutWidth = rowWidth
        note.stringValue = L10n.t("rot.size.copyOnly", "缩小尺寸只能另存一份，原图保持原尺寸")
        view.frame = NSRect(x: 0, y: 0, width: rowWidth, height: stack.fittingSize.height)

        select(initial)
    }

    /// 放进对话框。按钮要先加好（第一个是覆盖原图、第二个是另存一份），勾选框也先打开
    func attach(to alert: NSAlert, overwrite: NSButton?, copy: NSButton?) {
        overwriteButton = overwrite
        copyButton = copy
        rememberButton = alert.showsSuppressionButton ? alert.suppressionButton : nil
        alert.accessoryView = view
        Self.current = self
        update()
    }

    /// 现在选的尺寸
    var choice: SaveSize.Choice {
        guard let item = popup.selectedItem else { return .original }
        if item.tag == Self.customTag { return .custom(customValue) }
        let e = item.representedObject as? Int ?? 0
        return e > 0 ? .preset(e) : .original
    }

    /// 自定义框里的数：不是数字时用上次的，小于 64 按 64
    var customValue: Int {
        let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? SaveSize.customEdge
        return max(SaveSize.minEdge, v)
    }

    /// 另存时要缩到的长边；nil = 原尺寸
    var shrinkEdge: Int? { SaveSize.shrinkEdge(native: native, choice: choice) }
    var outputSize: CGSize { SaveSize.output(native: native, choice: choice) }
    var overwriteAllowed: Bool { shrinkEdge == nil }

    func select(_ c: SaveSize.Choice) {
        switch c {
        case .original:
            popup.selectItem(at: 0)
        case .preset(let e):
            if let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? Int) == e }) { popup.selectItem(at: i) } else { popup.selectItem(at: 0) }
        case .custom(let e):
            field.stringValue = String(e)
            popup.selectItem(withTag: Self.customTag)
        }
        update()
    }

    /// 测试用：在自定义框里打字
    func debugType(_ s: String) {
        field.stringValue = s
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    @objc private func popupChanged() {
        update()
        if popup.selectedTag() == Self.customTag {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    /// 用户点了保存：记住这次选的尺寸
    func remember() {
        SaveSize.last = choice
    }

    private func update() {
        let custom = popup.selectedTag() == Self.customTag
        field.isHidden = !custom
        pxLabel.isHidden = !custom
        let out = outputSize
        let notBigger = choice != .original && shrinkEdge == nil
        result.stringValue = L10n.f("rot.size.result", "导出 %@", SaveSize.text(out)) + (notBigger ? L10n.t("rot.size.noUpscale", "，不放大") : "")
        let allowed = overwriteAllowed
        note.stringValue = allowed ? "" : L10n.t("rot.size.copyOnly", "缩小尺寸只能另存一份，原图保持原尺寸")
        if let o = overwriteButton, let c = copyButton {
            o.isEnabled = allowed
            // 回车跟着能点的那个走
            o.keyEquivalent = allowed ? "\r" : ""
            c.keyEquivalent = allowed ? "" : "\r"
        }
        if let r = rememberButton {
            // 「以后都这样保存」之后就不再弹框、只按原尺寸存，缩小时不让勾，免得以为以后都缩小
            if !allowed { r.state = .off }
            r.isEnabled = allowed
        }
    }
}

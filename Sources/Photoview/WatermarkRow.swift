import AppKit

/// 导出窗口（⌘S 面板、批量转换、预设编辑）里的「水印」一行：菜单（无 / 存过的样式 / 编辑水印…），
/// 选了样式就在下面多出「本次文字」（多行输入，回车是换行），预填样式的文字，只改这一次的导出，不改动样式
final class WatermarkRowView: NSStackView {
    static var label: String { L10n.t("wm.label", "水印") }
    static var noneTitle: String { L10n.t("wm.none", "无") }
    static var editTitle: String { L10n.t("wm.edit", "编辑水印…") }

    /// 选择或文字变了
    var onChange: (() -> Void)?
    /// 用户在菜单里换了一项（nil = 无）
    var onPick: ((UUID?) -> Void)?
    /// 现在选中的样式
    var activeID: UUID? { active?.id }
    /// 下面那一行出现或消失了，外面的窗口要重新量一下大小
    var onLayout: (() -> Void)?

    let popup = NSPopUpButton(frame: .zero)
    /// 本次文字：多行，约三行高
    let field = MultilineTextField(width: 232)
    private let labelView = NSTextField(labelWithString: WatermarkRowView.label)
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let detail = NSStackView()
    private let indent = NSView()
    private let store: WatermarkStore
    /// 现在用的样式（预设里存的那一份，或选中的存过的样式）；nil = 无
    private(set) var active: WatermarkStyle?
    /// 菜单第 i+1 项对应的样式；预设里存的样式已经不在列表里时，它排在最后一项
    private var itemStyles: [WatermarkStyle] = []
    private var lastIndex = 0
    private let memoryKey: String?
    private let forPreset: Bool

    /// job：一开始用的水印（预设里存的）；nil 时按 memoryKey 记住的上次选择
    init(job: WatermarkJob?, memoryKey: String?, forPreset: Bool = false, store: WatermarkStore = .shared, labelWidth: CGFloat? = nil, preselect: Bool = false) {
        self.store = store
        self.memoryKey = memoryKey
        self.forPreset = forPreset
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        labelView.font = .systemFont(ofSize: 13)
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.setAccessibilityLabel(Self.label)
        let top = NSStackView(views: [labelView, popup])
        top.spacing = 8
        top.alignment = .centerY
        if let labelWidth {
            labelView.translatesAutoresizingMaskIntoConstraints = false
            labelView.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        }

        field.onTextChange = { [weak self] in self?.onChange?() }
        field.setAccessibilityLabel(L10n.t("wm.field.title", "本次文字"))
        field.toolTip = L10n.t("wm.field.title", "本次文字")
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0
        noteLabel.preferredMaxLayoutWidth = 232
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.widthAnchor.constraint(equalToConstant: 232).isActive = true
        noteLabel.stringValue = forPreset
            ? L10n.t("wm.note.preset", "这个预设导出时用的文字，不改动水印样式。{date} 是导出当天的日期，{name} 是文件名。")
            : L10n.t("wm.note.export", "本次文字，只用于这一次，不改动水印样式。{date} 是导出当天的日期，{name} 是文件名。")
        let col = NSStackView(views: [field, noteLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: (labelWidth ?? 30) + 8).isActive = true
        detail.setViews([indent, col], in: .leading)
        detail.orientation = .horizontal
        detail.alignment = .top
        detail.spacing = 0
        addArrangedSubview(top)
        addArrangedSubview(detail)

        // 初始选择
        if let job {
            active = job.style
            field.stringValue = job.effectiveText
        } else if preselect, let id = WatermarkMemory.preselectForMenu(store: store), let s = store.style(id: id) {
            active = s
        } else if let key = memoryKey, let id = WatermarkMemory.last(key), let s = store.style(id: id) {
            active = s
        }
        if job == nil, let a = active { field.stringValue = a.resolvedText }
        rebuildMenu()
        syncDetail(notify: false)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: WatermarkStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// 现在这一次要用的水印；无 = nil
    var job: WatermarkJob? {
        guard let a = active else { return nil }
        return WatermarkJob(style: a, text: field.stringValue)
    }

    /// 确定导出时调：记住这次选的样式（选「无」也记，下次默认还是无）
    func rememberChoice() {
        if let key = memoryKey { WatermarkMemory.remember(active?.id, key: key) }
    }

    /// 自测用：选菜单第 i 项（0 = 无）
    func debugSelect(_ i: Int) {
        popup.selectItem(at: i)
        popupChanged(popup)
    }

    // MARK: - 菜单

    private func rebuildMenu() {
        itemStyles = store.styles
        if let a = active, !itemStyles.contains(where: { $0.id == a.id }) { itemStyles.append(a) }
        popup.removeAllItems()
        popup.addItem(withTitle: Self.noneTitle)
        for s in itemStyles { popup.addItem(withTitle: s.displayName) }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: Self.editTitle)
        if let a = active, let i = itemStyles.firstIndex(where: { $0.id == a.id }) { popup.selectItem(at: i + 1) } else { popup.selectItem(at: 0) }
        lastIndex = popup.indexOfSelectedItem
    }

    private var editIndex: Int { itemStyles.count + 2 }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if i == editIndex {
            popup.selectItem(at: lastIndex)
            WatermarkEditor.runModal(from: window, selecting: active?.id)
            return
        }
        // 点的还是现在这一项：不动（预设里存的那份样式不会被列表里现在的样子换掉）
        if i == lastIndex { return }
        lastIndex = i
        if i == 0 {
            active = nil
        } else if itemStyles.indices.contains(i - 1) {
            let s = itemStyles[i - 1]
            active = store.style(id: s.id) ?? s
            field.stringValue = active?.resolvedText ?? ""
        }
        onPick?(active?.id)
        syncDetail(notify: true)
    }

    @objc private func storeChanged() {
        guard let a = active else { rebuildMenu(); return }
        let typed = field.stringValue
        let wasDefault = typed == a.resolvedText
        if !forPreset, let s = store.style(id: a.id) {
            // 在编辑窗口里改过样式：用最新的；手打的文字（和样式文字不同的）留着
            active = s
            if wasDefault { field.stringValue = s.resolvedText }
        } else if !forPreset {
            active = nil
        }
        rebuildMenu()
        syncDetail(notify: true)
    }

    private func syncDetail(notify: Bool) {
        let show = active != nil
        let changed = detail.isHidden == show
        detail.isHidden = !show
        field.placeholderString = active?.resolvedText
        if notify { onChange?() }
        if changed { onLayout?() }
    }
}

import AppKit

/// 导出选项那一组控件：「导出为…」面板和「批量转换格式」对话框共用
final class ExportOptionsView: NSStackView, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    private let keepMeta = NSButton(checkboxWithTitle: L10n.t("exp.keepMeta", "保留拍摄信息、说明和版权"), target: nil, action: nil)
    private let stripGPS = NSButton(checkboxWithTitle: L10n.t("exp.stripGPS", "去掉位置信息"), target: nil, action: nil)
    private let longCheck = NSButton(checkboxWithTitle: L10n.t("exp.longEdge", "长边不超过"), target: nil, action: nil)
    private let longField = NSTextField(string: "")
    private let sizeCheck = NSButton(checkboxWithTitle: L10n.t("exp.maxSize", "文件不超过"), target: nil, action: nil)
    private let sizeField = NSTextField(string: "")
    private let srgb = NSButton(checkboxWithTitle: L10n.t("exp.srgb", "转换为 sRGB"), target: nil, action: nil)
    #if FLIPIC_PRO
    /// 胶片：无 + 十款（Pro）。effectToken 是现在选的那段文字，换款以外的参数（强度等）沿用传进来的
    private let filmPopup = NSPopUpButton(frame: .zero)
    private var effectToken: String?
    private var filmIndex = 0
    #endif

    init(options o: ExportOptions) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        keepMeta.state = o.keepMetadata ? .on : .off
        stripGPS.state = o.stripGPS ? .on : .off
        longCheck.state = o.maxLongEdge != nil ? .on : .off
        longField.stringValue = String(o.maxLongEdge ?? ExportOptions.savedLongEdge)
        sizeCheck.state = o.maxBytes != nil ? .on : .off
        let mb = o.maxBytes.map { Double($0) / 1_048_576 } ?? ExportOptions.savedSizeMB
        sizeField.stringValue = mb == mb.rounded() ? String(Int(mb)) : String(format: "%.2f", mb).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        srgb.state = o.toSRGB ? .on : .off
        for b in [keepMeta, stripGPS, longCheck, sizeCheck, srgb] { b.target = self; b.action = #selector(changed(_:)) }
        for f in [longField, sizeField] {
            f.alignment = .right
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        sizeCheck.toolTip = L10n.t("exp.sizePngNote", "PNG 是无损格式，不能按大小限制；JPEG 和 HEIC 可以")
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let gpsRow = NSStackView(views: [indent, stripGPS])
        gpsRow.spacing = 0
        let unit: (String) -> NSTextField = { t in
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 13)
            return l
        }
        let longRow = NSStackView(views: [longCheck, longField, unit(L10n.t("exp.pixels", "像素"))])
        let sizeRow = NSStackView(views: [sizeCheck, sizeField, unit("MB")])
        for r in [longRow, sizeRow] { r.spacing = 6; r.alignment = .centerY }
        for v in [keepMeta, gpsRow, longRow, sizeRow, srgb] { addArrangedSubview(v) }
        setCustomSpacing(10, after: gpsRow)
        #if FLIPIC_PRO
        filmPopup.addItems(withTitles: FilmExportUI.titles)
        effectToken = o.effect
        filmIndex = FilmExportUI.index(for: o.effect)
        filmPopup.selectItem(at: filmIndex)
        filmPopup.target = self
        filmPopup.action = #selector(filmChanged(_:))
        let filmRow = NSStackView(views: [unit(FilmExportUI.label), filmPopup])
        filmRow.spacing = 8
        filmRow.alignment = .centerY
        addArrangedSubview(filmRow)
        setCustomSpacing(10, after: srgb)
        #endif
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// PNG 无损，没有「文件不超过」
    var isPNG = false { didSet { sync() } }

    private func sync() {
        stripGPS.isEnabled = keepMeta.state == .on
        longField.isEnabled = longCheck.state == .on
        sizeCheck.isEnabled = !isPNG
        sizeField.isEnabled = sizeCheck.state == .on && !isPNG
    }

    var options: ExportOptions {
        var o = ExportOptions()
        o.keepMetadata = keepMeta.state == .on
        o.stripGPS = o.keepMetadata && stripGPS.state == .on
        if longCheck.state == .on, let v = Int(longField.stringValue.trimmingCharacters(in: .whitespaces)), v >= 64 { o.maxLongEdge = v }
        if sizeCheck.state == .on, !isPNG,
           let mb = Double(sizeField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), mb >= 0.05 {
            o.maxBytes = Int64(mb * 1_048_576)
        }
        o.toSRGB = srgb.state == .on
        #if FLIPIC_PRO
        o.effect = FilmExportUI.token(forIndex: filmPopup.indexOfSelectedItem, initial: effectToken)
        #endif
        return o
    }

    #if FLIPIC_PRO
    @objc private func filmChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if FilmExportUI.allowed(index: i, in: window) {
            filmIndex = i
        } else {
            sender.selectItem(at: filmIndex)
        }
        changed(sender)
    }

    /// 自测用：选胶片菜单的第 i 项（0 = 无），走和点选一样的流程
    func debugSelectFilm(_ i: Int) {
        filmPopup.selectItem(at: i)
        filmChanged(filmPopup)
    }
    var debugFilmPopup: NSPopUpButton { filmPopup }
    #endif

    @objc private func changed(_ sender: Any?) {
        sync()
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) { onChange?() }

    /// 自测用：直接设各项
    func debugSet(long: Int, megabytes: Double, srgb on: Bool, strip: Bool) {
        longCheck.state = .on; longField.stringValue = String(long)
        sizeCheck.state = .on; sizeField.stringValue = String(megabytes)
        srgb.state = on ? .on : .off
        stripGPS.state = strip ? .on : .off
        sync()
    }
}

/// 「导出为…」保存面板下面的附件：格式、质量、导出选项、预计大小
final class ExportAccessory {
    private(set) var view: NSView
    let popup: NSPopUpButton
    let slider: NSSlider
    let qualityLabel: NSTextField
    let estimateLabel: NSTextField
    let options: ExportOptionsView

    init(formats: [String], formatIndex: Int, quality: Double, onChange: @escaping () -> Void) {
        popup = NSPopUpButton(frame: .zero)
        popup.addItems(withTitles: formats)
        popup.selectItem(at: formats.indices.contains(formatIndex) ? formatIndex : 0)
        qualityLabel = NSTextField(labelWithString: L10n.f("exp.quality", "质量 %d", Int(quality)))
        qualityLabel.font = .systemFont(ofSize: 12)
        slider = NSSlider(value: quality, minValue: 40, maxValue: 100, target: nil, action: nil)
        slider.isContinuous = true
        estimateLabel = NSTextField(wrappingLabelWithString: L10n.t("exp.estimating", "预计大小：计算中…"))
        estimateLabel.font = .systemFont(ofSize: 12)
        estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.maximumNumberOfLines = 2
        var initial = ExportOptions.saved
        #if FLIPIC_PRO
        initial.effect = FilmEffect.defaultToken   // 现在开着哪一款，默认就导出带哪一款；没开就是无
        #endif
        options = ExportOptionsView(options: initial)
        let q = NSStackView(views: [qualityLabel, slider])
        q.spacing = 8
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let sep = NSBox()
        sep.boxType = .separator
        let stack = NSStackView(views: [popup, q, sep, options, estimateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 6, right: 0)
        #if FLIPIC_PRO
        let presetButton = NSButton(title: L10n.t("preset.saveAs", "存为预设…"), target: nil, action: nil)
        presetButton.controlSize = .small
        presetButton.bezelStyle = .rounded
        stack.addArrangedSubview(presetButton)
        #endif
        let width: CGFloat = 320
        for v in [popup, q, sep, estimateLabel] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        estimateLabel.preferredMaxLayoutWidth = width
        estimateLabel.heightAnchor.constraint(equalToConstant: 32).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = stack
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        popup.target = self
        popup.action = #selector(popupMoved(_:))
        #if FLIPIC_PRO
        presetButton.target = self
        presetButton.action = #selector(saveAsPreset(_:))
        #endif
        self.onChange = onChange
        options.onChange = { [weak self] in self?.onChange?() }
    }

    private var onChange: (() -> Void)?
    @objc private func sliderMoved(_ s: NSSlider) {
        qualityLabel.stringValue = L10n.f("exp.quality", "质量 %d", Int(s.doubleValue))
        onChange?()
    }
    @objc private func popupMoved(_ s: NSPopUpButton) { onChange?() }

    #if FLIPIC_PRO
    /// 「存为预设…」：按现在的格式、质量和选项建一个预设，保存位置是「每次问」
    @objc private func saveAsPreset(_ sender: NSButton) {
        PresetSaveAs.run(from: sender, format: popup.titleOfSelectedItem ?? "JPEG", quality: slider.integerValue,
                         options: options.options, destination: PresetDestination(kind: .ask))
    }
    #endif
}

/// 批量转换对话框的附件：格式、质量、导出选项、保存位置
final class BatchAccessory: NSObject {
    private(set) var view: NSView
    let popup = NSPopUpButton(frame: .zero)
    let slider: NSSlider
    let qualityLabel: NSTextField
    let options: ExportOptionsView
    private let pathLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var outDir: URL
    /// 为 true 表示默认位置因为原来的盘是存储卡或只读的而改了
    private(set) var redirected: Bool
    private(set) var userChose = false
    private let source: URL

    init(source: URL, formatIndex: Int, quality: Double) {
        self.source = source
        popup.addItems(withTitles: BatchConvert.formats.map(\.name))
        popup.selectItem(at: BatchConvert.formats.indices.contains(formatIndex) ? formatIndex : 0)
        qualityLabel = NSTextField(labelWithString: L10n.f("bc.quality", "质量 %d", Int(quality)))
        qualityLabel.font = .systemFont(ofSize: 12)
        slider = NSSlider(value: quality, minValue: 40, maxValue: 100, target: nil, action: nil)
        var initial = ExportOptions.saved
        #if FLIPIC_PRO
        initial.effect = FilmEffect.defaultToken
        #endif
        options = ExportOptionsView(options: initial)
        let d = BatchConvert.defaultOutputFolder(for: source, ext: BatchConvert.formats[max(0, min(formatIndex, 2))].ext)
        outDir = d.url
        redirected = d.redirected
        view = NSView()
        super.init()
        slider.target = self; slider.action = #selector(sliderMoved(_:))
        popup.target = self; popup.action = #selector(formatMoved(_:))
        let q = NSStackView(views: [qualityLabel, slider])
        q.spacing = 8
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let sep1 = NSBox(), sep2 = NSBox()
        sep1.boxType = .separator; sep2.boxType = .separator

        let saveTitle = NSTextField(labelWithString: L10n.t("bc.saveTo", "保存到"))
        saveTitle.font = .systemFont(ofSize: 12)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: L10n.t("bc.choose", "选择…"), target: self, action: #selector(chooseFolder))
        choose.controlSize = .small
        choose.bezelStyle = .rounded
        let pathRow = NSStackView(views: [saveTitle, pathLabel, choose])
        pathRow.spacing = 8
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 3

        let stack = NSStackView(views: [popup, q, sep1, options, sep2, pathRow, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        #if FLIPIC_PRO
        let presetButton = NSButton(title: L10n.t("preset.saveAs", "存为预设…"), target: self, action: #selector(saveAsPreset(_:)))
        presetButton.controlSize = .small
        presetButton.bezelStyle = .rounded
        stack.addArrangedSubview(presetButton)
        #endif
        let width: CGFloat = 340
        for v in [popup, q, sep1, sep2, pathRow, noteLabel] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        noteLabel.preferredMaxLayoutWidth = width
        noteLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true
        refresh()
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = stack
        formatMoved(popup)
    }

    var formatIndex: Int { popup.indexOfSelectedItem }
    var settings: BatchConvert.Settings {
        let f = BatchConvert.formats[formatIndex]
        return BatchConvert.Settings(uti: f.uti, ext: f.ext, quality: slider.doubleValue, options: options.options, outDir: outDir)
    }

    private func refresh() {
        pathLabel.stringValue = (outDir.path as NSString).abbreviatingWithTildeInPath
        pathLabel.toolTip = outDir.path
        let ext = BatchConvert.formats[max(0, min(popup.indexOfSelectedItem, 2))].ext
        var note = redirected && !userChose
            ? L10n.t("bc.cardNote", "原照片在存储卡或只读的盘上，默认存到「图片」文件夹，不往那个盘里写。")
            : L10n.f("bc.defaultNote", "默认放在原照片旁边的 Converted-%@ 文件夹，同名文件不会被覆盖。", ext)
        note += " " + L10n.t("bc.sameNote", "已经是这个格式的照片，没设限制时会跳过。")
        noteLabel.stringValue = note
    }

    #if FLIPIC_PRO
    /// 现在的输出位置对应的预设保存位置：默认的「原照片旁的 Converted-…」是子文件夹，自己选的是固定文件夹，存储卡改放「图片」的是每次问
    var presetDestination: PresetDestination {
        if userChose { return PresetDestination(kind: .fixed, path: outDir.path) }
        if redirected { return PresetDestination(kind: .ask) }
        return PresetDestination(kind: .subfolder, subfolder: outDir.lastPathComponent)
    }

    @objc private func saveAsPreset(_ sender: NSButton) {
        PresetSaveAs.run(from: sender, format: BatchConvert.formats[max(0, min(formatIndex, 2))].name, quality: Int(slider.doubleValue),
                         options: options.options, destination: presetDestination)
    }
    #endif

    /// 自测用：当作用户在选择面板里选了这个文件夹
    func debugChoose(_ url: URL) { outDir = url; userChose = true; refresh() }

    @objc private func sliderMoved(_ s: NSSlider) { qualityLabel.stringValue = L10n.f("bc.quality", "质量 %d", Int(s.doubleValue)) }

    @objc private func formatMoved(_ s: NSPopUpButton) {
        let png = s.indexOfSelectedItem == 1
        slider.isEnabled = !png
        options.isPNG = png
        if !userChose {
            let d = BatchConvert.defaultOutputFolder(for: source, ext: BatchConvert.formats[max(0, min(s.indexOfSelectedItem, 2))].ext)
            outDir = d.url
            redirected = d.redirected
        }
        refresh()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("bc.choosePrompt", "选择")
        panel.directoryURL = outDir.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outDir = url
        userChose = true
        refresh()
    }
}

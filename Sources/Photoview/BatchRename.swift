import AppKit
import ImageIO

/// EXIF 变量模板批量重命名：
/// 支持 {date}（拍摄日期 yyyyMMdd）、{time}（拍摄时间 HHmmss）、{camera}（相机型号）、{focal}（焦距 如 35mm）、
/// {name}（原主文件名）、{seq}（3 位序号 001）、{seq4}（4 位序号 0001）。
/// 兼容旧用法：模板里没有花括号时（例如直接填「东京旅行」），自动按「东京旅行-{seq}」重命名
enum BatchRenameEngine {
    struct Meta {
        var date: String
        var time: String
        var camera: String
        var focal: String
    }

    static let presets: [(titleKey: String, titleDefault: String, template: String)] = [
        ("br.preset.prefix", "前缀-001", "{prefix}-{seq}"),
        ("br.preset.dateSeq", "日期_序号", "{date}_{seq}"),
        ("br.preset.dateTimeCam", "日期_时间_相机_序号", "{date}_{time}_{camera}_{seq}"),
        ("br.preset.camFocal", "相机_焦距_序号", "{camera}_{focal}_{seq}"),
        ("br.preset.nameSeq", "原名_序号", "{name}_{seq}"),
    ]

    /// 读一次文件头取拍摄日期/时间/相机/焦距，缺项安全回落到文件修改时间或空串
    static func readMeta(url: URL, fallbackDate: Date? = nil) -> Meta {
        var dt: Date?
        var camera = ""
        var focal = ""
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            if let raw = ExifReader.captureDate(exif) {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                dt = f.date(from: raw)
            }
            if let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                camera = sanitizeToken(model)
            }
            if let fl = exif?[kCGImagePropertyExifFocalLength as String] as? Double, fl > 0 {
                focal = fl < 10 ? String(format: "%.1fmm", fl) : String(format: "%.0fmm", fl)
            }
        }
        let usedDate = dt ?? fallbackDate
            ?? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            ?? Date()
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyyMMdd"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HHmmss"
        return Meta(date: df.string(from: usedDate), time: tf.string(from: usedDate), camera: camera, focal: focal)
    }

    static func sanitizeToken(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\*?\"<>|\r\n\t")
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        return cleaned.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))
    }

    /// 按模板生成不含扩展名的文件名；兼容纯前缀（不含 `{` 自动追加 `-{seq}`）
    static func expand(template raw: String, url: URL, seq: Int, meta: Meta? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tpl = trimmed.contains("{") ? trimmed : "\(trimmed)-{seq}"
        let needsMeta = tpl.lowercased().contains("{date}") || tpl.lowercased().contains("{time}")
            || tpl.lowercased().contains("{camera}") || tpl.lowercased().contains("{focal}")
        let m = needsMeta ? (meta ?? readMeta(url: url)) : Meta(date: "", time: "", camera: "", focal: "")
        let stem = url.deletingPathExtension().lastPathComponent
        var out = ""
        var rest = Substring(tpl)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}") {
                switch after[after.startIndex..<close].lowercased() {
                case "date": out += m.date
                case "time": out += m.time
                case "camera": out += m.camera
                case "focal": out += m.focal
                case "name": out += stem
                case "seq": out += String(format: "%03d", max(0, seq))
                case "seq4": out += String(format: "%04d", max(0, seq))
                default: out += "{" + after[after.startIndex..<close] + "}"
                }
                rest = after[after.index(after: close)...]
            } else {
                out += rest[open...]
                rest = ""
            }
        }
        out += rest
        // 清理缺项变量（比如截图没有相机/焦距）留下的连续下划线/连字符
        let sanitized = sanitizeToken(out)
            .replacingOccurrences(of: #"_{2,}"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))
        return sanitized.isEmpty ? String(format: "%03d", max(0, seq)) : sanitized
    }

    /// 执行批量重命名（重名自动避让、同步改 .xmp / .MOV / 关联文件与 CardMarks）
    static func execute(items: [ImageItem], template: String, startSeq: Int) -> (renamed: Int, newNameMap: [URL: String]) {
        guard let folderURL = items.first?.url.deletingLastPathComponent() else { return (0, [:]) }
        let fm = FileManager.default
        var renamed = 0
        var map: [URL: String] = [:]
        var seq = max(0, startSeq)
        for item in items {
            let ext = item.url.pathExtension
            let meta = readMeta(url: item.url, fallbackDate: item.modified)
            var base = expand(template: template, url: item.url, seq: seq, meta: meta)
            var candidate = ext.isEmpty ? base : "\(base).\(ext)"
            var suffix = 2
            while candidate != item.url.lastPathComponent,
                  fm.fileExists(atPath: folderURL.appendingPathComponent(candidate).path) {
                if template.lowercased().contains("{seq") || !template.contains("{") {
                    seq += 1
                    base = expand(template: template, url: item.url, seq: seq, meta: meta)
                } else {
                    base = "\(expand(template: template, url: item.url, seq: seq, meta: meta))-\(suffix)"
                    suffix += 1
                }
                candidate = ext.isEmpty ? base : "\(base).\(ext)"
            }
            if candidate != item.url.lastPathComponent {
                let dest = folderURL.appendingPathComponent(candidate)
                if (try? fm.moveItem(at: item.url, to: dest)) != nil {
                    ViewerViewController.renameCompanions(of: item.url, to: dest)
                    CardMarks.rename(from: item.url, to: dest)
                    renamed += 1
                    map[item.url] = candidate
                }
            }
            seq += 1
        }
        return (renamed, map)
    }
}

/// 批量重命名弹窗的附件视图：模板预设、模板输入、起始编号、前 3 张实时预览
final class BatchRenameAccessory: NSView, NSTextFieldDelegate {
    let presetPopup = NSPopUpButton(frame: .zero)
    let templateField = NSTextField(string: "")
    let startField = NSTextField(string: "1")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let sampleItems: [ImageItem]
    private let sampleMetas: [BatchRenameEngine.Meta]
    private let folderName: String

    init(items: [ImageItem], folderName: String) {
        self.sampleItems = Array(items.prefix(3))
        self.sampleMetas = self.sampleItems.map { BatchRenameEngine.readMeta(url: $0.url, fallbackDate: $0.modified) }
        self.folderName = folderName
        super.init(frame: NSRect(x: 0, y: 0, width: 410, height: 158))
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    var templateText: String { templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var startNumber: Int { max(0, Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1) }

    private func build() {
        for p in BatchRenameEngine.presets {
            presetPopup.addItem(withTitle: L10n.t(p.titleKey, p.titleDefault))
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)

        templateField.stringValue = folderName
        templateField.placeholderString = L10n.t("br.tplPlaceholder", "前缀或模板，如 {date}_{camera}_{seq}")
        templateField.delegate = self
        templateField.translatesAutoresizingMaskIntoConstraints = false
        templateField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        startField.alignment = .right
        startField.delegate = self
        startField.translatesAutoresizingMaskIntoConstraints = false
        startField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let lbl: (String) -> NSTextField = { s in
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 12)
            return f
        }
        let r1 = NSStackView(views: [lbl(L10n.t("br.preset", "常用")), presetPopup, lbl(L10n.t("br.start", "起始")), startField])
        r1.spacing = 8; r1.alignment = .centerY
        let r2 = NSStackView(views: [lbl(L10n.t("br.template", "模板")), templateField])
        r2.spacing = 8; r2.alignment = .centerY

        let hint = NSTextField(wrappingLabelWithString: L10n.t("br.tokens",
            "可用变量：{date} 日期、{time} 时间、{camera} 相机、{focal} 焦距、{name} 原名、{seq} 序号"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 394

        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .labelColor
        previewLabel.maximumNumberOfLines = 4
        previewLabel.preferredMaxLayoutWidth = 394

        let stack = NSStackView(views: [r1, r2, hint, previewLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        refreshPreview()
    }

    @objc private func presetChanged() {
        let i = presetPopup.indexOfSelectedItem
        guard BatchRenameEngine.presets.indices.contains(i) else { return }
        let raw = BatchRenameEngine.presets[i].template
        templateField.stringValue = raw.replacingOccurrences(of: "{prefix}", with: folderName)
        refreshPreview()
    }

    func controlTextDidChange(_ obj: Notification) { refreshPreview() }

    private func refreshPreview() {
        let tpl = templateText
        guard !tpl.isEmpty else { previewLabel.stringValue = ""; return }
        let start = startNumber
        let lines = sampleItems.enumerated().map { idx, item -> String in
            let ext = item.url.pathExtension
            let base = BatchRenameEngine.expand(template: tpl, url: item.url, seq: start + idx, meta: sampleMetas[idx])
            let newName = ext.isEmpty ? base : "\(base).\(ext)"
            return "\(item.url.lastPathComponent)  →  \(newName)"
        }
        previewLabel.stringValue = lines.joined(separator: "\n")
    }
}

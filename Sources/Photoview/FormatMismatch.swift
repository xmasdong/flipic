import AppKit
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// 检测与修复「文件后缀与实际图片格式不符」（例如豆包 / 网页保存的 PNG、WebP 被写成 .jpg，导致访达无法生成缩略图、Photoshop 报错）。
/// 检测只读文件头前 32 字节（零整图解码），支持两种修复：
/// 1. 无损修正后缀（推荐，原位改名并同步 .xmp / .MOV 等附属文件）
/// 2. 重新编码为真正的 JPEG（保留 .jpg 文件名，透明通道铺白底）
enum FormatMismatch {
    enum RealFormat: String, Equatable {
        case png, jpeg, webp, gif, heic, avif, bmp, tiff, jxl

        /// 推荐使用的规范后缀（小写，不含点）
        var canonicalExt: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .webp: return "webp"
            case .gif: return "gif"
            case .heic: return "heic"
            case .avif: return "avif"
            case .bmp: return "bmp"
            case .tiff: return "tif"
            case .jxl: return "jxl"
            }
        }

        /// 短格式名（界面提示用）
        var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .webp: return "WebP"
            case .gif: return "GIF"
            case .heic: return "HEIC"
            case .avif: return "AVIF"
            case .bmp: return "BMP"
            case .tiff: return "TIFF"
            case .jxl: return "JPEG XL"
            }
        }

        /// 与该格式匹配、不算错配的常见扩展名
        var validExts: Set<String> {
            switch self {
            case .png: return ["png"]
            case .jpeg: return ["jpg", "jpeg", "jpe", "jfif"]
            case .webp: return ["webp"]
            case .gif: return ["gif"]
            case .heic: return ["heic", "heif", "hif"]
            case .avif: return ["avif"]
            case .bmp: return ["bmp", "dib"]
            case .tiff: return ["tif", "tiff"]
            case .jxl: return ["jxl"]
            }
        }
    }

    struct Info: Equatable {
        let url: URL
        /// 当前文件后缀（小写，不含点）
        let currentExt: String
        /// 文件头识别出的真实格式
        let actual: RealFormat

        var suggestedExt: String { actual.canonicalExt }

        var suggestedFileName: String {
            let stem = url.deletingPathExtension().lastPathComponent
            return "\(stem).\(suggestedExt)"
        }
    }

    enum RepairMode: Int {
        /// 无损改后缀（推荐）
        case renameExtension = 0
        /// 重新编码为真 JPEG（保留 .jpg）
        case convertToJPEG = 1
    }

    struct BatchOutcome {
        var fixed: Int = 0
        var failed: Int = 0
        /// 旧 URL → 新 URL（包括原地转真 JPEG 时 old == new）
        var urlMap: [URL: URL] = [:]
        var firstError: String?
    }

    // MARK: - 魔数快速识别

    /// 供慢盘 JPEG 128 KB 前缀快读守卫：确认文件头确实是 JPEG（FF D8 FF）
    static func hasJPEGHeader(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    /// 读文件头前 32 字节（单次 POSIX read，不映射整张图）
    private static func readHeader(_ url: URL) -> [UInt8]? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n >= 4 else { return nil }
        if n < buf.count { buf.removeSubrange(n..<buf.count) }
        return buf
    }

    /// 仅靠前 32 字节判断常见静图格式（相机 RAW 和视频不参与）
    static func detectRealFormat(_ url: URL) -> RealFormat? {
        guard !CleanupUnit.isRaw(url), !Video.isVideo(url) else { return nil }
        guard let b = readHeader(url) else { return nil }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
            return .png
        }
        // JPEG: FF D8 FF
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return .jpeg
        }
        // WebP: RIFF....WEBP
        if b.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return .webp
        }
        // GIF: GIF87a / GIF89a
        if b.count >= 6,
           b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38,
           (b[4] == 0x37 || b[4] == 0x39), b[5] == 0x61 {
            return .gif
        }
        // JPEG XL codestream (FF 0A) or ISOBMFF container (00 00 00 0C 'JXL ' 0D 0A 87 0A)
        if b.count >= 2, b[0] == 0xFF, b[1] == 0x0A {
            return .jxl
        }
        if b.count >= 12,
           b[0] == 0x00, b[1] == 0x00, b[2] == 0x00, b[3] == 0x0C,
           b[4] == 0x4A, b[5] == 0x58, b[6] == 0x4C, b[7] == 0x20 {
            return .jxl
        }
        // ISOBMFF ftyp box: HEIC / AVIF（排除 Canon CR3 的 crx ）
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            func brand(at offset: Int) -> String? {
                guard offset + 4 <= b.count else { return nil }
                return String(bytes: b[offset..<(offset + 4)], encoding: .ascii)
            }
            let major = brand(at: 8) ?? ""
            if major == "crx " { return nil }
            var brands = [major]
            var off = 16
            while off + 4 <= b.count {
                if let br = brand(at: off) { brands.append(br) }
                off += 4
            }
            if brands.contains("crx ") { return nil }
            if brands.contains("avif") || brands.contains("avis") { return .avif }
            let heicBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]
            if brands.contains(where: { heicBrands.contains($0) }) { return .heic }
            return nil
        }
        // BMP: BM（只认支持的图片后缀，防止撞非图文件）
        if b.count >= 6, b[0] == 0x42, b[1] == 0x4D {
            // 校验 DIB header size 合理性（常见 12/40/52/56/108/124）
            if b.count >= 18 {
                let dib = UInt32(b[14]) | (UInt32(b[15]) << 8) | (UInt32(b[16]) << 16) | (UInt32(b[17]) << 24)
                if [12, 40, 52, 56, 64, 108, 124].contains(dib) { return .bmp }
            }
        }
        // TIFF: II*\0 or MM\0* —— 很多 RAW 也用 TIFF 头，必须经 ImageIO 确认确实是纯 public.tiff
        if b.count >= 4,
           ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A)) {
            if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let type = CGImageSourceGetType(src) as String?,
               type == UTType.tiff.identifier {
                return .tiff
            }
        }
        return nil
    }

    /// 如果文件后缀与真实格式不符，返回错配信息；一致、RAW、视频或无法识别均返回 nil
    static func detect(_ url: URL) -> Info? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !CleanupUnit.isRaw(url), !Video.isVideo(url) else { return nil }
        guard let actual = detectRealFormat(url), !actual.validExts.contains(ext) else { return nil }
        return Info(url: url, currentExt: ext, actual: actual)
    }

    /// 扫描一组文件，返回所有错配项（保持输入顺序）
    static func scan(_ urls: [URL]) -> [Info] {
        var out: [Info] = []
        for u in urls {
            if let m = detect(u) { out.append(m) }
        }
        return out
    }

    /// 供裁剪/拉直/加边框另存副本用：错配文件改用真实格式对应的规范后缀，避免继续写出「假 JPG」
    static func preferredCopyExtension(for url: URL) -> String {
        if let m = detect(url) { return m.suggestedExt }
        let ext = url.pathExtension
        return ext.isEmpty ? "jpg" : ext
    }

    // MARK: - 修复执行

    /// 生成同目录下不撞名的目标路径（保留原主文件名，碰撞时追加 -2、-3…）
    static func uniqueURL(in folder: URL, stem: String, ext: String, ignoring source: URL? = nil) -> URL {
        let fm = FileManager.default
        let sourceKey = source?.standardizedFileURL.path.lowercased()
        var candidate = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path),
              candidate.standardizedFileURL.path.lowercased() != sourceKey {
            candidate = folder.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// 方式 1：无损修正为真实格式后缀（原位 rename，保留所有属性/标签/时间，同步 .xmp / .MOV 等附属文件）
    static func renameToActual(_ info: Info) -> Result<URL, Error> {
        let fm = FileManager.default
        let src = info.url
        let folder = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let dest = uniqueURL(in: folder, stem: stem, ext: info.suggestedExt, ignoring: src)
        do {
            FolderWatcher.noteOwnWrite(src)
            FolderWatcher.noteOwnWrite(dest)
            try fm.moveItem(at: src, to: dest)
            CardMarks.rename(from: src, to: dest)
            ViewerViewController.renameCompanions(of: src, to: dest)
            ImageLoader.shared.evict(url: src)
            ImageLoader.shared.evict(url: dest)
            return .success(dest)
        } catch {
            return .failure(error)
        }
    }

    /// 方式 2：重新编码为真正的 JPEG（保留 .jpg 文件名；非 .jpg 后缀则改存为同名 .jpg 并移除旧错配文件）。
    /// 带透明通道的 PNG/WebP 会先铺白底，防止转成 JPEG 后透明区变黑；完整保留 EXIF / IPTC / GPS、访达标签与创建时间。
    static func convertToRealJPEG(_ info: Info, quality: Double = 0.92) -> Result<URL, Error> {
        let fm = FileManager.default
        let src = info.url
        let folder = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let keepPath = ["jpg", "jpeg", "jpe"].contains(info.currentExt)
        let dest = keepPath ? src : uniqueURL(in: folder, stem: stem, ext: "jpg", ignoring: src)

        guard let decoded = ImageLoader.decodedFull(url: src) else {
            return .failure(NSError(domain: "FormatMismatch", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: L10n.t("mm.errDecode", "无法解码原图")]))
        }
        let rgbImage = flattenAlphaOnWhiteIfNeeded(decoded)

        // 读取原图元数据，去掉已烘焙到像素的旧方向标记，避免二次旋转
        var props: [String: Any] = [:]
        if let cgSrc = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let raw = CGImageSourceCopyPropertiesAtIndex(cgSrc, 0, nil) as? [String: Any] {
            props = raw
        }
        props.removeValue(forKey: kCGImagePropertyOrientation as String)
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props[kCGImageDestinationLossyCompressionQuality as String] = quality

        let tmp = folder.appendingPathComponent("\(FolderWatcher.tempPrefix)\(UUID().uuidString).jpg")
        defer { try? fm.removeItem(at: tmp) }
        guard let cgDest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return .failure(NSError(domain: "FormatMismatch", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: L10n.t("mm.errEncode", "无法创建目标 JPEG 文件")]))
        }
        CGImageDestinationAddImage(cgDest, rgbImage, props as CFDictionary)
        guard CGImageDestinationFinalize(cgDest) else {
            return .failure(NSError(domain: "FormatMismatch", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: L10n.t("mm.errEncode", "无法写入目标 JPEG 文件")]))
        }
        // 回读校验：必须是有效 JPEG 且宽高一致
        guard let verifySrc = CGImageSourceCreateWithURL(tmp as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              (CGImageSourceGetType(verifySrc) as String?) == UTType.jpeg.identifier,
              let vProps = CGImageSourceCopyPropertiesAtIndex(verifySrc, 0, nil) as? [String: Any],
              (vProps[kCGImagePropertyPixelWidth as String] as? Int) == rgbImage.width,
              (vProps[kCGImagePropertyPixelHeight as String] as? Int) == rgbImage.height else {
            return .failure(NSError(domain: "FormatMismatch", code: 4,
                                    userInfo: [NSLocalizedDescriptionKey: L10n.t("mm.errVerify", "生成的 JPEG 校验失败，原图未改动")]))
        }

        // 记录原文件属性（创建时间、访达标签），替换后恢复
        let oldTags = (try? src.resourceValues(forKeys: [.tagNamesKey]))?.tagNames
        let oldAttrs = try? fm.attributesOfItem(atPath: src.path)
        let oldCreation = oldAttrs?[.creationDate] as? Date

        do {
            FolderWatcher.noteOwnWrite(src)
            FolderWatcher.noteOwnWrite(dest)
            if keepPath {
                _ = try fm.replaceItemAt(src, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
                try fm.removeItem(at: src)
                CardMarks.rename(from: src, to: dest)
                ViewerViewController.renameCompanions(of: src, to: dest)
            }
            if let oldCreation {
                try? fm.setAttributes([.creationDate: oldCreation], ofItemAtPath: dest.path)
            }
            if let oldTags, !oldTags.isEmpty {
                try? (dest as NSURL).setResourceValue(oldTags, forKey: .tagNamesKey)
            }
            ImageLoader.shared.evict(url: src)
            ImageLoader.shared.evict(url: dest)
            return .success(dest)
        } catch {
            return .failure(error)
        }
    }

    /// PNG / WebP 带透明通道转 JPEG 时先铺纯白底，避免透明区发黑
    private static func flattenAlphaOnWhiteIfNeeded(_ image: CGImage) -> CGImage {
        let ai = image.alphaInfo
        let hasAlpha = ai == .premultipliedFirst || ai == .premultipliedLast || ai == .first || ai == .last
        guard hasAlpha else { return image }
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let targetCS = cs.model == .rgb ? cs : (CGColorSpace(name: CGColorSpace.sRGB)!)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: targetCS,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// 批量执行修复
    static func executeBatch(_ items: [Info], mode: RepairMode, progress: ((Int, Int) -> Void)? = nil) -> BatchOutcome {
        var out = BatchOutcome()
        let total = items.count
        for (i, item) in items.enumerated() {
            let res: Result<URL, Error>
            switch mode {
            case .renameExtension: res = renameToActual(item)
            case .convertToJPEG: res = convertToRealJPEG(item)
            }
            switch res {
            case .success(let newURL):
                out.fixed += 1
                out.urlMap[item.url] = newURL
            case .failure(let err):
                out.failed += 1
                if out.firstError == nil { out.firstError = err.localizedDescription }
            }
            progress?(i + 1, total)
        }
        return out
    }
}

// MARK: - 看图页顶部轻提示条（可一键修正当前张 / 打开整文件夹修复 / 关闭）

final class FormatMismatchBannerView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    let fixOneButton = NSButton(title: "", target: nil, action: nil)
    let fixFolderButton = NSButton(title: "", target: nil, action: nil)
    let closeButton = NSButton(title: "", target: nil, action: nil)

    var onFixOne: (() -> Void)?
    var onFixFolder: (() -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var currentInfo: FormatMismatch.Info?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        iconView.contentTintColor = .systemOrange
        iconView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fixOneButton.bezelStyle = .rounded
        fixOneButton.controlSize = .small
        fixOneButton.keyEquivalent = ""
        fixOneButton.bezelColor = .controlAccentColor
        fixOneButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        fixOneButton.target = self
        fixOneButton.action = #selector(fixOneClicked)
        fixOneButton.refusesFirstResponder = true
        fixOneButton.translatesAutoresizingMaskIntoConstraints = false
        fixOneButton.setContentHuggingPriority(.required, for: .horizontal)

        fixFolderButton.bezelStyle = .rounded
        fixFolderButton.controlSize = .small
        fixFolderButton.font = .systemFont(ofSize: 11.5, weight: .regular)
        fixFolderButton.target = self
        fixFolderButton.action = #selector(fixFolderClicked)
        fixFolderButton.refusesFirstResponder = true
        fixFolderButton.translatesAutoresizingMaskIntoConstraints = false
        fixFolderButton.setContentHuggingPriority(.required, for: .horizontal)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("alert.close", "关闭"))
        closeButton.symbolConfiguration = .init(pointSize: 10.5, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.refusesFirstResponder = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, messageLabel, fixOneButton, fixFolderButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(info: FormatMismatch.Info, showFolderAction: Bool) {
        currentInfo = info
        messageLabel.stringValue = L10n.f("mm.bannerText", "实际为 %1$@（后缀是 .%2$@），访达无法显示缩略图",
                                          info.actual.displayName, info.currentExt)
        fixOneButton.title = L10n.f("mm.fixToExt", "修正为 .%@", info.suggestedExt)
        fixFolderButton.title = L10n.t("mm.fixFolderBtn", "修复整个文件夹…")
        fixFolderButton.isHidden = !showFolderAction
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.14 : 0.10).cgColor
    }

    @objc private func fixOneClicked() { onFixOne?() }
    @objc private func fixFolderClicked() { onFixFolder?() }
    @objc private func dismissClicked() { onDismiss?() }
}

// MARK: - 整文件夹批量修复弹窗

final class FormatMismatchWindowController: NSWindowController {
    private let items: [FormatMismatch.Info]
    private var selected: [Bool]
    private var mode: FormatMismatch.RepairMode = .renameExtension
    private let onComplete: (FormatMismatch.BatchOutcome, FormatMismatch.RepairMode) -> Void
    var onClose: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(wrappingLabelWithString: "")
    private let renameRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let jpegRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let modeHintLabel = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let selectAllButton = NSButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private var rowChecks: [NSButton] = []
    private var rowTargets: [NSTextField] = []
    private var running = false

    /// 供自测读取当前预览行数与第一行文字
    var debugRowCount: Int { rowTargets.count }
    var debugFirstTarget: String { rowTargets.first?.stringValue ?? "" }

    init(items: [FormatMismatch.Info], folderName: String,
         onComplete: @escaping (FormatMismatch.BatchOutcome, FormatMismatch.RepairMode) -> Void) {
        self.items = items
        self.selected = Array(repeating: true, count: items.count)
        self.onComplete = onComplete

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = L10n.t("mm.sheetTitle", "修复错误的图片后缀")
        win.minSize = NSSize(width: 500, height: 380)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI(folderName: folderName)
        refreshModeUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(attachedTo parent: NSWindow?) {
        guard let win = window else { return }
        if let parent {
            parent.beginSheet(win) { _ in }
        } else {
            win.center()
            win.makeKeyAndOrderFront(nil)
        }
    }

    private func closeDialog() {
        guard let win = window else { onClose?(); return }
        if let parent = win.sheetParent {
            parent.endSheet(win)
        } else {
            win.close()
        }
        onClose?()
    }

    private func buildUI(folderName: String) {
        guard let content = window?.contentView else { return }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.badge.checkmark", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 24, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.stringValue = L10n.f("mm.foundHeader", "在「%1$@」中发现 %2$d 张后缀与格式不符的图片", folderName, items.count)
        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        subLabel.stringValue = L10n.t("mm.foundSub", "这些图片的实际内容与文件后缀不一致（例如 PNG / WebP 被存成 .jpg），导致访达无法生成缩略图或后期软件报错。")
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = .secondaryLabelColor
        subLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerText = NSStackView(views: [headerLabel, subLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        headerText.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [icon, headerText])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // 修复方式（单选）
        renameRadio.title = L10n.t("mm.modeRename", "修正为真实后缀（推荐，无损最快）")
        renameRadio.state = .on
        renameRadio.target = self
        renameRadio.action = #selector(modeChanged(_:))
        renameRadio.tag = FormatMismatch.RepairMode.renameExtension.rawValue

        jpegRadio.title = L10n.t("mm.modeJPEG", "转为真正的 JPEG（保留 .jpg 文件名）")
        jpegRadio.state = .off
        jpegRadio.target = self
        jpegRadio.action = #selector(modeChanged(_:))
        jpegRadio.tag = FormatMismatch.RepairMode.convertToJPEG.rawValue

        modeHintLabel.font = .systemFont(ofSize: 11.5)
        modeHintLabel.textColor = .secondaryLabelColor

        let modeBox = NSView()
        modeBox.wantsLayer = true
        modeBox.layer?.cornerRadius = 8
        modeBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor
        modeBox.translatesAutoresizingMaskIntoConstraints = false
        let modeStack = NSStackView(views: [renameRadio, jpegRadio, modeHintLabel])
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 6
        modeStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        modeStack.translatesAutoresizingMaskIntoConstraints = false
        modeBox.addSubview(modeStack)

        // 文件预览列表
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        final class FlippedDoc: NSView { override var isFlipped: Bool { true } }
        let doc = FlippedDoc()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.borderType = .bezelBorder
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for (idx, item) in items.enumerated() {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowToggled(_:)))
            check.state = .on
            check.tag = idx
            check.setContentHuggingPriority(.required, for: .horizontal)

            let srcLabel = NSTextField(labelWithString: item.url.lastPathComponent)
            srcLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            srcLabel.textColor = .labelColor
            srcLabel.lineBreakMode = .byTruncatingMiddle
            srcLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let arrow = NSTextField(labelWithString: "→")
            arrow.font = .systemFont(ofSize: 11.5)
            arrow.textColor = .tertiaryLabelColor
            arrow.setContentHuggingPriority(.required, for: .horizontal)

            let targetLabel = NSTextField(labelWithString: "")
            targetLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
            targetLabel.textColor = .controlAccentColor
            targetLabel.lineBreakMode = .byTruncatingMiddle
            targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let badge = NSTextField(labelWithString: " \(item.actual.displayName) ")
            badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
            badge.textColor = .systemOrange
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
            badge.setContentHuggingPriority(.required, for: .horizontal)

            let rowSpacer = NSView()
            rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [check, srcLabel, arrow, targetLabel, rowSpacer, badge])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -16).isActive = true

            rowChecks.append(check)
            rowTargets.append(targetLabel)
        }

        // 底部栏
        selectAllButton.bezelStyle = .rounded
        selectAllButton.controlSize = .small
        selectAllButton.target = self
        selectAllButton.action = #selector(toggleAllClicked)

        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = Double(max(1, items.count))
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = L10n.t("alert.cancel", "取消")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        applyButton.title = L10n.t("mm.applyBtn", "开始修复")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [selectAllButton, countLabel, spacer, cancelButton, applyButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        for v in [headerRow, modeBox, scroll, progressBar, bottomRow] as [NSView] {
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            modeBox.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 14),
            modeBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            modeBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            modeStack.topAnchor.constraint(equalTo: modeBox.topAnchor),
            modeStack.bottomAnchor.constraint(equalTo: modeBox.bottomAnchor),
            modeStack.leadingAnchor.constraint(equalTo: modeBox.leadingAnchor),
            modeStack.trailingAnchor.constraint(equalTo: modeBox.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: modeBox.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -10),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),

            progressBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            progressBar.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -10),

            bottomRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottomRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottomRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func refreshModeUI() {
        renameRadio.state = mode == .renameExtension ? .on : .off
        jpegRadio.state = mode == .convertToJPEG ? .on : .off
        modeHintLabel.stringValue = mode == .renameExtension
            ? L10n.t("mm.modeRenameHint", "仅修改文件后缀，不重新压缩、不损画质，并同步重命名同名 .xmp / .MOV 附属文件。")
            : L10n.t("mm.modeJPEGHint", "将文件内容重新编码为标准 JPEG（质量 92%，透明底自动铺白），保留 .jpg 文件名与 EXIF / 访达标签。")
        for (i, item) in items.enumerated() {
            if mode == .renameExtension {
                rowTargets[i].stringValue = item.suggestedFileName
            } else {
                let isAlreadyJpg = ["jpg", "jpeg", "jpe"].contains(item.currentExt)
                let targetName = isAlreadyJpg ? item.url.lastPathComponent : "\(item.url.deletingPathExtension().lastPathComponent).jpg"
                rowTargets[i].stringValue = L10n.f("mm.targetRealJPEG", "%@（真 JPEG）", targetName)
            }
        }
        refreshSelectionCount()
    }

    private func refreshSelectionCount() {
        let n = selected.filter { $0 }.count
        countLabel.stringValue = L10n.f("mm.selectedCount", "已选 %1$d / %2$d 张", n, items.count)
        selectAllButton.title = n == items.count ? L10n.t("mm.deselectAll", "取消全选") : L10n.t("mm.selectAll", "全选")
        applyButton.isEnabled = n > 0 && !running
    }

    @objc private func modeChanged(_ sender: NSButton) {
        mode = FormatMismatch.RepairMode(rawValue: sender.tag) ?? .renameExtension
        refreshModeUI()
    }

    @objc private func rowToggled(_ sender: NSButton) {
        let i = sender.tag
        guard selected.indices.contains(i) else { return }
        selected[i] = sender.state == .on
        refreshSelectionCount()
    }

    @objc private func toggleAllClicked() {
        let allOn = selected.allSatisfy { $0 }
        for i in selected.indices {
            selected[i] = !allOn
            rowChecks[i].state = !allOn ? .on : .off
        }
        refreshSelectionCount()
    }

    @objc private func cancelClicked() {
        guard !running else { return }
        closeDialog()
    }

    @objc private func applyClicked() {
        guard !running else { return }
        let chosen = zip(items, selected).compactMap { $1 ? $0 : nil }
        guard !chosen.isEmpty else { return }
        running = true
        applyButton.isEnabled = false
        cancelButton.isEnabled = false
        selectAllButton.isEnabled = false
        renameRadio.isEnabled = false
        jpegRadio.isEnabled = false
        for c in rowChecks { c.isEnabled = false }
        progressBar.maxValue = Double(chosen.count)
        progressBar.doubleValue = 0
        progressBar.isHidden = false

        let chosenMode = mode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = FormatMismatch.executeBatch(chosen, mode: chosenMode) { done, _ in
                DispatchQueue.main.async { self?.progressBar.doubleValue = Double(done) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.closeDialog()
                self.onComplete(outcome, chosenMode)
            }
        }
    }
}

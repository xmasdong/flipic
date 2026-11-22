import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 导出水印：样式（WatermarkStyle）、一次导出用的整份水印（WatermarkJob）、存取（WatermarkStore）。
/// 这是免费功能，公开版也有，所以这里不碰任何 Pro 的东西。画水印的代码在 WatermarkRenderer.swift

// MARK: - 样式

struct WatermarkStyle: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case text, image }
    enum Layout: String, Codable, CaseIterable { case tiled, single }
    enum Anchor: String, Codable, CaseIterable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    }
    enum Tint: String, Codable, CaseIterable { case white, black, custom }
    enum Edge: String, Codable, CaseIterable { case none, shadow, outline }

    var id = UUID()
    /// 空 = 内置样式用跟着界面语言走的默认名字
    var name = ""
    /// 内置样式的编号（WatermarkBuiltIn.rawValue）；自己建的是 nil
    var builtIn: String?
    var kind: Kind = .text
    /// 多行文字；认得 {date}（今天，yyyy-MM-dd）和 {name}（文件名，不含扩展名）。空 + 内置 = 用默认文字
    var text = ""
    /// 图片水印：Watermarks 文件夹里的文件名（导入时复制进去，原图挪走也不影响）
    var imageFile: String?
    var layout: Layout = .tiled
    /// 平铺的倾斜角度（度，逆时针为正，默认 -30）
    var angle = -30.0
    /// 平铺的疏密：每一块之间的空隙，以字号为单位的倍数
    var spacing = 1.0
    var anchor: Anchor = .bottomRight
    /// 单个水印离边的距离，占长边的比例
    var margin = 0.025
    /// 文字：字号占长边的比例；图片：水印宽度占长边的比例
    var size = 0.03
    var opacity = 0.3
    var tint: Tint = .white
    /// sRGB 的 r g b，0...1（tint == .custom 时用）
    var customColor: [Double] = [0.5, 0.5, 0.5]
    var edge: Edge = .none
    var bold = false

    static let sizeRange = 0.008...0.4
    static let spacingRange = 0.0...6.0
    static let marginRange = 0.0...0.3

    init() {}

    // 每一项都容错：缺项、类型不对（比如以后的版本改了）就用默认值，数值夹在合理范围里，不丢整个样式
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decode(T.self, forKey: k)) ?? d }
        func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double { x.isFinite ? min(max(x, r.lowerBound), r.upperBound) : r.lowerBound }
        id = v(.id, UUID())
        name = v(.name, "")
        builtIn = try? c.decode(String.self, forKey: .builtIn)
        kind = v(.kind, Kind.text)
        text = v(.text, "")
        imageFile = try? c.decode(String.self, forKey: .imageFile)
        layout = v(.layout, Layout.tiled)
        angle = clamp(v(.angle, -30.0), -180...180)
        spacing = clamp(v(.spacing, 1.0), Self.spacingRange)
        anchor = v(.anchor, Anchor.bottomRight)
        margin = clamp(v(.margin, 0.025), Self.marginRange)
        size = clamp(v(.size, 0.03), Self.sizeRange)
        opacity = clamp(v(.opacity, 0.3), 0...1)
        tint = v(.tint, Tint.white)
        let rgb: [Double] = v(.customColor, [0.5, 0.5, 0.5])
        customColor = rgb.count == 3 ? rgb.map { clamp($0, 0...1) } : [0.5, 0.5, 0.5]
        edge = v(.edge, Edge.none)
        bold = v(.bold, false)
    }

    /// 列表里显示的名字
    var displayName: String {
        if !name.isEmpty { return name }
        if let b = builtIn.flatMap(WatermarkBuiltIn.init(rawValue:)) { return b.defaultName }
        return L10n.t("wm.unnamed", "未命名")
    }

    /// 真正要画的文字（内置样式没改过文字时是跟着语言走的默认文字）
    var resolvedText: String {
        if text.isEmpty, let b = builtIn.flatMap(WatermarkBuiltIn.init(rawValue:)) { return b.defaultText }
        return text
    }

    /// 把跟着语言走的名字和文字固定下来：存进预设、交给批量任务的用这一份，以后换语言或改样式都不影响
    func frozen() -> WatermarkStyle {
        var s = self
        s.name = displayName
        s.text = resolvedText
        return s
    }

    /// 平铺是否用得上这些项
    var isTiled: Bool { layout == .tiled }

    /// 字（或图）颜色，sRGB
    var rgb: (r: Double, g: Double, b: Double) {
        switch tint {
        case .white: return (1, 1, 1)
        case .black: return (0, 0, 0)
        case .custom:
            let c = customColor.count == 3 ? customColor : [0.5, 0.5, 0.5]
            return (c[0], c[1], c[2])
        }
    }

    /// 描边、阴影用的颜色：浅色字配深色边，深色字配浅色边
    var edgeRGB: (r: Double, g: Double, b: Double) {
        let c = rgb
        let lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        return lum > 0.5 ? (0, 0, 0) : (1, 1, 1)
    }
}

/// 内置样式：第一次用时建好，之后都是用户自己的（可以改、复制、删除、恢复）
enum WatermarkBuiltIn: String, CaseIterable {
    case id, proof, sign

    /// 固定的 id，「恢复内置样式」之后「上次用的」还认得
    var fixedID: UUID {
        switch self {
        case .id: return UUID(uuidString: "6F1D5A10-0000-4000-8000-0000000000A1")!
        case .proof: return UUID(uuidString: "6F1D5A10-0000-4000-8000-0000000000A2")!
        case .sign: return UUID(uuidString: "6F1D5A10-0000-4000-8000-0000000000A3")!
        }
    }

    var defaultName: String {
        switch self {
        case .id: return L10n.t("wm.builtin.id.name", "证件用途")
        case .proof: return L10n.t("wm.builtin.proof.name", "样片")
        case .sign: return L10n.t("wm.builtin.sign.name", "署名")
        }
    }

    var defaultText: String {
        switch self {
        case .id: return L10n.t("wm.builtin.id.text", "仅供办理业务使用，他用无效")
        case .proof: return L10n.t("wm.builtin.proof.text", "样片 请勿外传")
        case .sign: return L10n.t("wm.builtin.sign.text", "© 你的名字")
        }
    }

    func make() -> WatermarkStyle {
        var s = WatermarkStyle()
        s.id = fixedID
        s.builtIn = rawValue
        switch self {
        case .id:
            s.layout = .tiled
            s.angle = -30
            s.spacing = 0.6
            s.size = 0.032
            s.opacity = 0.32
            s.tint = .custom
            s.customColor = [0.42, 0.42, 0.42]
            s.edge = .none
            s.bold = true
        case .proof:
            s.layout = .tiled
            s.angle = -30
            s.spacing = 1.4
            s.size = 0.04
            s.opacity = 0.24
            s.tint = .white
            s.edge = .shadow
            s.bold = true
        case .sign:
            s.layout = .single
            s.anchor = .bottomRight
            s.margin = 0.025
            s.size = 0.022
            s.opacity = 0.7
            s.tint = .white
            s.edge = .shadow
            s.bold = false
        }
        return s
    }
}

// MARK: - 一次导出用的水印

/// 导出选项里带的水印：整份样式 + 这一次的文字。样式是复制进来的，之后改了样式、删了样式，已经排好的批量任务和预设都不受影响
struct WatermarkJob: Codable, Equatable {
    var style: WatermarkStyle
    /// 这一次用的文字（比如证件要交给谁、办什么事）；nil 或空 = 用样式里的文字
    var text: String?

    init(style: WatermarkStyle, text: String? = nil) {
        let frozen = style.frozen()
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.style = frozen
        self.text = t.isEmpty || t == frozen.text ? nil : text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = (try? c.decode(WatermarkStyle.self, forKey: .style)) ?? WatermarkBuiltIn.id.make()
        self.init(style: s, text: try? c.decode(String.self, forKey: .text))
    }

    /// 这次真正画的文字（还没替换 {date}、{name}）
    var effectiveText: String {
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return style.resolvedText
    }
}

// MARK: - 文字里的占位符

enum WatermarkTokens {
    /// {date} 今天（yyyy-MM-dd，公历），{name} 文件名（不含扩展名），{index} 批量序号（001、002…）；大小写不限，别的花括号原样保留
    static func expand(_ text: String, fileName: String?, date: Date, index: Int? = nil) -> String {
        guard text.contains("{") else { return text }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: date)
        let name = fileName ?? ""
        let seq = String(format: "%03d", max(1, index ?? 1))
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}") {
                switch after[after.startIndex..<close].lowercased() {
                case "date": out += today
                case "name": out += name
                case "index": out += seq
                default: out += "{" + after[after.startIndex..<close] + "}"
                }
                rest = after[after.index(after: close)...]
            } else {
                out += rest[open...]
                rest = ""
            }
        }
        return out + rest
    }
}

// MARK: - 存取

/// 样式列表和图片水印用的 logo：都放在 Application Support/<bundle id>/Watermarks/ 里（styles.json + logo 文件）。
/// directory 可注入（测试用临时文件夹，不碰真正的）
final class WatermarkStore {
    static let maxCount = 24
    static let didChange = Notification.Name("FlipicWatermarksDidChange")
    /// 界面用的这一份；测试里可以换成指向临时文件夹的
    static var shared = WatermarkStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Flipic", isDirectory: true)
            .appendingPathComponent("Watermarks", isDirectory: true)
    }

    private struct File: Codable {
        var version = 1
        var styles: [WatermarkStyle] = []
        init(styles: [WatermarkStyle]) { self.styles = styles }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 列表里个别项读不懂就跳过那一项，不丢整个列表
            var list: [WatermarkStyle] = []
            if var arr = try? c.nestedUnkeyedContainer(forKey: .styles) {
                while !arr.isAtEnd {
                    if let s = try? arr.decode(WatermarkStyle.self) { list.append(s) } else { _ = try? arr.decode(AnyDecodable.self) }
                }
            }
            styles = list
        }
    }
    private struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }

    let directory: URL
    private(set) var styles: [WatermarkStyle] = []

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    private var listURL: URL { directory.appendingPathComponent("styles.json") }

    /// 从文件重新读；没有文件（第一次用）或读不出来就建三个内置样式
    func reload() {
        if let data = try? Data(contentsOf: listURL), let f = try? JSONDecoder().decode(File.self, from: data) {
            styles = Array(f.styles.prefix(Self.maxCount))
        } else {
            styles = WatermarkBuiltIn.allCases.map { $0.make() }
            save(notify: false)
        }
    }

    private func save(notify: Bool = true) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? enc.encode(File(styles: styles)) { try? data.write(to: listURL, options: .atomic) }
        if notify { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    var isFull: Bool { styles.count >= Self.maxCount }
    func style(id: UUID) -> WatermarkStyle? { styles.first { $0.id == id } }
    func index(of id: UUID) -> Int? { styles.firstIndex { $0.id == id } }

    func newName() -> String {
        let names = Set(styles.map(\.displayName))
        var n = 1
        while names.contains(L10n.f("wm.newName", "水印 %d", n)) { n += 1 }
        return L10n.f("wm.newName", "水印 %d", n)
    }

    /// 新建一个：文字水印，平铺，白色；名字没用过的「水印 N」
    @discardableResult
    func addNew() -> WatermarkStyle? {
        guard !isFull else { return nil }
        var s = WatermarkStyle()
        s.name = newName()
        s.text = L10n.t("wm.newText", "仅供 XX 使用")
        s.size = 0.03
        s.opacity = 0.3
        s.edge = .shadow
        styles.append(s)
        save()
        return s
    }

    @discardableResult
    func add(_ s: WatermarkStyle) -> Bool {
        guard !isFull else { return false }
        styles.append(s)
        save()
        return true
    }

    func update(_ s: WatermarkStyle) {
        guard let i = index(of: s.id), styles[i] != s else { return }
        styles[i] = s
        save()
    }

    /// 复制一份放在原来那个后面，名字加「副本」；复制的不再是内置样式
    @discardableResult
    func duplicate(id: UUID) -> WatermarkStyle? {
        guard !isFull, let i = index(of: id) else { return nil }
        var c = styles[i]
        c.id = UUID()
        c.builtIn = nil
        c.name = L10n.f("wm.copyName", "%@ 副本", styles[i].displayName)
        c.text = styles[i].resolvedText
        styles.insert(c, at: i + 1)
        save()
        return c
    }

    /// 删掉样式。logo 文件留着：已经存进预设的整份样式还要用它
    func remove(id: UUID) {
        guard let i = index(of: id) else { return }
        styles.remove(at: i)
        save()
    }

    /// 把内置样式恢复成出厂的样子：还在的按原样重置（位置不动），被删了的补回来（放在最前面，按顺序）
    func resetBuiltIns() {
        var insertAt = 0
        for b in WatermarkBuiltIn.allCases {
            if let i = styles.firstIndex(where: { $0.builtIn == b.rawValue }) {
                styles[i] = b.make()
                insertAt = i + 1
            } else if !isFull {
                styles.insert(b.make(), at: min(insertAt, styles.count))
                insertAt += 1
            }
        }
        save()
    }

    /// 单个内置样式恢复出厂设置
    func reset(id: UUID) {
        guard let i = index(of: id), let b = styles[i].builtIn.flatMap(WatermarkBuiltIn.init(rawValue:)) else { return }
        styles[i] = b.make()
        save()
    }

    // MARK: logo

    /// 把选的图片缩到长边 1024 以内、存成 PNG（带透明）放进 Watermarks 文件夹，文件名是内容的哈希（同一张图只存一份）。返回文件名
    func importLogo(from url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let data = Self.normalizedLogoPNG(src) else { return nil }
        let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            do { try data.write(to: dest, options: .atomic) } catch { return nil }
        }
        return name
    }

    static func normalizedLogoPNG(_ src: CGImageSource) -> Data? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceShouldCacheImmediately: true]
        guard var img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // 统一成带 alpha 的 RGBA（灰度、索引色的图也能当 logo）
        if img.colorSpace?.model != .rgb || img.alphaInfo == .none || img.alphaInfo == .noneSkipLast || img.alphaInfo == .noneSkipFirst {
            let cs = img.colorSpace?.model == .rgb ? img.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            guard let out = ctx.makeImage() else { return nil }
            img = out
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func logoURL(_ file: String) -> URL {
        directory.appendingPathComponent((file as NSString).lastPathComponent)
    }

    private static let logoLock = NSLock()
    private static var logoCache: [String: CGImage] = [:]

    /// 读 logo（按路径缓存；文件不在了返回 nil）
    func logoImage(_ file: String?) -> CGImage? {
        guard let file, !file.isEmpty else { return nil }
        let url = logoURL(file)
        Self.logoLock.lock()
        if let hit = Self.logoCache[url.path] { Self.logoLock.unlock(); return hit }
        Self.logoLock.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        Self.logoLock.lock()
        if Self.logoCache.count > 16 { Self.logoCache.removeAll() }
        Self.logoCache[url.path] = img
        Self.logoLock.unlock()
        return img
    }
}

// MARK: - 各个对话框记住上次选的

/// 导出窗口里水印菜单的选择：每个对话框（⌘S、批量转换）各记一个。选的是样式的 id，文字不记（每次由样式带出）
enum WatermarkMemory {
    static let exportKey = "export.watermarkStyle"
    static let batchKey = "batch.watermarkStyle"
    /// 菜单「加水印导出…」：下一次打开的 ⌘S 面板直接选上水印
    static var forceNextExport = false
    static var defaults = UserDefaults.standard

    static func last(_ key: String) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// nil = 无
    static func remember(_ id: UUID?, key: String) {
        if let id { defaults.set(id.uuidString, forKey: key) } else { defaults.set("none", forKey: key) }
    }

    /// 「加水印导出…」要预选哪个：上次在 ⌘S 里用过的，没用过（或那个样式没了）就是「证件用途」，再没有就是第一个
    static func preselectForMenu(store: WatermarkStore = .shared) -> UUID? {
        if let id = last(exportKey), store.style(id: id) != nil { return id }
        return store.styles.first { $0.builtIn == WatermarkBuiltIn.id.rawValue }?.id ?? store.styles.first?.id
    }
}

// MARK: - 适用的照片

enum WatermarkEligibility {
    /// 视频和动图（GIF、APNG）不加水印：批量转换里这类文件直接跳过，不会出一份没带水印的副本
    static func isStill(_ url: URL) -> Bool {
        if Video.isVideo(url) { return false }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(src) as String? else { return true }
        if type == UTType.gif.identifier { return CGImageSourceGetCount(src) > 1 ? false : true }
        if type == UTType.png.identifier,
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any],
           png[kCGImagePropertyAPNGLoopCount as String] != nil { return false }
        return true
    }
}

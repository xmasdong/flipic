import AppKit

/// 访达的七种颜色标签。rawValue 是访达存的颜色序号：1 灰 2 绿 3 紫 4 蓝 5 黄 6 红 7 橙；
/// allCases 的顺序是菜单和快捷键里的顺序（红橙黄绿蓝紫灰，和访达侧边栏一致）
enum TagColor: Int, CaseIterable {
    case red = 6, orange = 7, yellow = 5, green = 2, blue = 4, purple = 3, gray = 1

    var index: Int { rawValue }
    fileprivate var bit: UInt8 { 1 << UInt8(rawValue) }

    var title: String {
        switch self {
        case .red: return L10n.t("tag.red", "红色")
        case .orange: return L10n.t("tag.orange", "橙色")
        case .yellow: return L10n.t("tag.yellow", "黄色")
        case .green: return L10n.t("tag.green", "绿色")
        case .blue: return L10n.t("tag.blue", "蓝色")
        case .purple: return L10n.t("tag.purple", "紫色")
        case .gray: return L10n.t("tag.gray", "灰色")
        }
    }

    /// 访达自己画标签圆点用的颜色（系统给的，跟着系统版本走）；读不到就用写死的近似值
    var color: NSColor {
        let all = NSWorkspace.shared.fileLabelColors
        if all.count == 8 { return all[index] }
        switch self {
        case .red: return NSColor(calibratedRed: 0.98, green: 0.38, blue: 0.35, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.25, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.93, green: 0.85, blue: 0.27, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.70, green: 0.84, blue: 0.27, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.34, green: 0.63, blue: 1.0, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.75, green: 0.55, blue: 0.84, alpha: 1)
        case .gray: return NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.66, alpha: 1)
        }
    }

    /// 菜单项前面的小色块
    var swatch: NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            self.color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// 一张照片上有哪几种颜色标签
struct TagColorSet: Equatable {
    private(set) var bits: UInt8 = 0
    init() {}
    init(_ colors: [TagColor]) { colors.forEach { insert($0) } }

    var isEmpty: Bool { bits == 0 }
    /// 红橙黄绿蓝紫灰的顺序
    var colors: [TagColor] { TagColor.allCases.filter(contains) }
    func contains(_ c: TagColor) -> Bool { bits & c.bit != 0 }
    mutating func insert(_ c: TagColor) { bits |= c.bit }
    mutating func remove(_ c: TagColor) { bits &= ~c.bit }
    func with(_ c: TagColor, on: Bool) -> TagColorSet {
        var s = self
        if on { s.insert(c) } else { s.remove(c) }
        return s
    }
}

/// 访达颜色标签的读写。标签存在文件的扩展属性里（和 Marks 同一处），存成「名称\n颜色序号」。
/// 访达认颜色标签靠名称：它自己的七个标签叫什么跟系统语言、访达里的设置有关，名字对不上就会在访达侧边栏里多出一个同色的新标签。
/// 所以写的时候先问系统（见 writeNames），读的时候认所有语言里访达可能写的名字
enum FinderTags {
    /// 各颜色在各语言里访达可能用的名字（红、橙、黄、绿、蓝、紫、灰）。认标签靠它；
    /// 写标签用哪一个由 writeNames 向系统确认
    private static let knownNames: [TagColor: [String]] = [
        .red: ["Red", "红色", "紅色", "赤", "レッド", "빨강", "빨간색", "Rouge", "Rot", "Rojo", "Rosso", "Vermelho", "Vermelha", "Красный", "أحمر", "Kırmızı", "Đỏ"],
        .orange: ["Orange", "橙色", "オレンジ", "주황", "주황색", "Naranja", "Arancione", "Laranja", "Оранжевый", "برتقالي", "Turuncu", "Cam"],
        .yellow: ["Yellow", "黄色", "黃色", "黄", "イエロー", "노랑", "노란색", "Jaune", "Gelb", "Amarillo", "Giallo", "Amarelo", "Жёлтый", "Желтый", "أصفر", "Sarı", "Vàng"],
        .green: ["Green", "绿色", "綠色", "緑", "グリーン", "초록", "초록색", "Vert", "Grün", "Verde", "Verde", "Зелёный", "Зеленый", "أخضر", "Yeşil", "Xanh lá"],
        .blue: ["Blue", "蓝色", "藍色", "青", "ブルー", "파랑", "파란색", "Bleu", "Blau", "Azul", "Blu", "Синий", "أزرق", "Mavi", "Xanh dương"],
        .purple: ["Purple", "紫色", "紫", "パープル", "보라", "보라색", "Violet", "Violett", "Morado", "Viola", "Roxo", "Фиолетовый", "أرجواني", "Mor", "Tím"],
        .gray: ["Gray", "Grey", "灰色", "グレイ", "グレー", "회색", "Gris", "Grau", "Grigio", "Cinza", "Серый", "رمادي", "Gri", "Xám"],
    ]

    /// 名称 → 颜色。再加上系统自己报的这套名字（跟当前语言走）
    private static let nameToColor: [String: TagColor] = {
        var map: [String: TagColor] = [:]
        for (c, names) in knownNames { for n in names { map[n.precomposedStringWithCanonicalMapping] = c } }
        let system = NSWorkspace.shared.fileLabels
        if system.count == 8 { for c in TagColor.allCases { map[system[c.index].precomposedStringWithCanonicalMapping] = c } }
        return map
    }()

    /// 列目录时顺带取回的标签名里有哪几种颜色；没有标签的文件（绝大多数）一步就返回
    static func colors(fromTagNames names: [String]?) -> TagColorSet {
        guard let names, !names.isEmpty else { return TagColorSet() }
        var s = TagColorSet()
        for n in names { if let c = nameToColor[n] ?? nameToColor[n.precomposedStringWithCanonicalMapping] { s.insert(c) } }
        return s
    }

    /// resourceValues 会缓存，要读盘上现在的值得用新的 URL 对象
    private static func freshNames(_ url: URL) -> [String]? {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames
    }

    static func colors(of url: URL) -> TagColorSet { colors(fromTagNames: freshNames(url)) }

    /// 信息面板里列的标签：颜色标签带颜色，自己建的标签（编辑常用来写「待修」「可发」）只有名字；挑片标记另有徽章，不列
    static func listing(of url: URL) -> [(name: String, color: TagColor?)] {
        (freshNames(url) ?? []).filter { !Marks.markNames.contains($0) }.map { n in
            (n, nameToColor[n] ?? nameToColor[n.precomposedStringWithCanonicalMapping])
        }
    }

    private static func baseName(_ entry: String) -> String {
        entry.components(separatedBy: "\n").first ?? entry
    }

    private static func isColorEntry(_ entry: String, _ color: TagColor?) -> Bool {
        let n = baseName(entry)
        guard let c = nameToColor[n] ?? nameToColor[n.precomposedStringWithCanonicalMapping] else { return false }
        return color == nil || c == color
    }

    /// 写进文件的名字：访达在这台电脑上给这个颜色起的名字。
    /// 做法是在临时文件上用系统自己的接口打标签，系统认得的名字会自动带上颜色（读回颜色序号对得上），不认得的不会。
    /// 按「系统当前语言的名字 → 各语言的名字」的顺序试，第一个认得的就是；都不认得退回系统当前语言的名字
    static let writeNames: [TagColor: String] = {
        var result: [TagColor: String] = [:]
        let system = NSWorkspace.shared.fileLabels
        let probe = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flipic-tagprobe-\(UUID().uuidString)")
        let made = FileManager.default.createFile(atPath: probe.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: probe) }
        for c in TagColor.allCases {
            var candidates: [String] = []
            if system.count == 8 { candidates.append(system[c.index]) }
            candidates += knownNames[c] ?? []
            let url = probe
            if made {
                for name in candidates {
                    guard (try? (url as NSURL).setResourceValue([name], forKey: .tagNamesKey)) != nil else { continue }
                    let label = (try? URL(fileURLWithPath: probe.path).resourceValues(forKeys: [.labelNumberKey]))?.labelNumber
                    if label == c.index { result[c] = name; break }
                }
            }
            if result[c] == nil { result[c] = candidates.first }
        }
        return result
    }()

    /// 给文件加上或去掉一种颜色标签，保留其他所有标签（包括挑片标记和自己建的）；成功返回 true
    @discardableResult
    static func set(_ color: TagColor, on: Bool, for url: URL) -> Bool {
        var tags = Marks.readTags(url)
        let before = tags
        tags.removeAll { isColorEntry($0, color) }
        if on { tags.append("\(writeNames[color] ?? color.title)\n\(color.index)") }
        if tags != before, !Marks.writeTags(tags, to: url) { return false }
        return colors(of: url).contains(color) == on
    }

    /// 去掉全部颜色标签，其他标签不动
    @discardableResult
    static func clearColors(for url: URL) -> Bool {
        var tags = Marks.readTags(url)
        let before = tags
        tags.removeAll { isColorEntry($0, nil) }
        if tags != before, !Marks.writeTags(tags, to: url) { return false }
        return colors(of: url).isEmpty
    }
}

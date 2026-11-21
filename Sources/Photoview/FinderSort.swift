import Foundation

/// 「跟随访达」：读访达给某个文件夹记的排序方式。
/// 访达把文件夹的显示设置记在上一级文件夹的 .DS_Store 里、以这个文件夹的名字为键；
/// 个人文件夹、磁盘根目录这类上一级写不了的，记在自己的 .DS_Store 里、名字是「.」。
/// 两处都没有就用访达的全局默认（官网版才读得到）；名称以外认不出的（手动排列、种类、标签等）一律按文件名
enum FinderSort {
    typealias Order = (key: SortKey, reversed: Bool)

    static func resolve(_ folder: URL) -> Order {
        let dir = folder.standardizedFileURL
        var rec: [String: Any] = [:]
        if dir.path != "/" {
            rec = DSStore.record(at: dir.deletingLastPathComponent().appendingPathComponent(".DS_Store"), named: dir.lastPathComponent)
        }
        if rec.isEmpty { rec = DSStore.record(at: dir.appendingPathComponent(".DS_Store"), named: ".") }
        return resolve(rec, globals: globals())
    }

    /// 访达的全局默认：显示方式和各显示方式的排序设置
    static func globals() -> [String: Any] {
        var g: [String: Any] = [:]
        for k in ["FXPreferredViewStyle", "StandardViewSettings", "FXArrangeGroupViewBy"] {
            if let v = CFPreferencesCopyAppValue(k as CFString, "com.apple.finder" as CFString) { g[k] = v }
        }
        return g
    }

    /// rec 是 .DS_Store 里这个文件夹的记录（四字码 → 值），globals 是 globals() 的结果
    static func resolve(_ rec: [String: Any], globals g: [String: Any]) -> Order {
        func plist(_ code: String) -> [String: Any]? {
            (rec[code] as? Data).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        }
        let std = g["StandardViewSettings"] as? [String: Any]
        func global(_ k: String) -> [String: Any]? { std?[k] as? [String: Any] }
        let style = (rec["vstl"] as? String) ?? (g["FXPreferredViewStyle"] as? String) ?? "icnv"
        switch style {
        case "Nlsv":
            let ext = global("ExtendedListViewSettingsV2")
            return list(plist("lsvp") ?? plist("lsvP") ?? (ext?["sortColumn"] != nil ? ext : global("ListViewSettings")))
        case "glyv":
            return arranged(plist("glvp")?["arrangeBy"] ?? global("GalleryViewSettings")?["arrangeBy"])
        default:
            // 图标和分栏显示都按「排列方式」
            let a = plist("icvp")?["arrangeBy"] ?? global("IconViewSettings")?["arrangeBy"]
            if a == nil, let legacy = g["FXArrangeGroupViewBy"] as? String {
                return arranged(["Name": "name", "Date Added": "dateAdded", "Date Modified": "dateModified",
                                 "Date Created": "dateCreated", "Size": "size"][legacy])
            }
            return arranged(a)
        }
    }

    static func key(_ s: Any?) -> SortKey? {
        switch s as? String {
        case "name": return .name
        case "dateAdded": return .added
        case "dateModified": return .modified
        case "dateCreated": return .created
        case "size": return .size
        default: return nil
        }
    }

    /// 图标、画廊的排列方式方向固定：名称 A→Z，日期新的在前，大小大的在前，和这里的自然方向一样
    private static func arranged(_ a: Any?) -> Order { (key(a) ?? .name, false) }

    /// 列表显示：sortColumn 加这一列的 ascending。访达的升序对日期是旧的在前、对大小是小的在前
    private static func list(_ p: [String: Any]?) -> Order {
        let col = p?["sortColumn"] as? String
        guard let k = key(col) else { return (.name, false) }
        var info: [String: Any]?
        if let cols = p?["columns"] as? [String: Any] { info = cols[col!] as? [String: Any] }
        else if let cols = p?["columns"] as? [[String: Any]] { info = cols.first { $0["identifier"] as? String == col } }
        let ascending = (info?["ascending"] as? Bool) ?? !k.largestFirst
        return (k, ascending == k.largestFirst)
    }
}

/// 只读的 .DS_Store（Bud1 伙伴分配 + B 树）解析，只取某一个文件名下的记录。
/// 文件坏了、截断了、太大都返回空，不会越界
enum DSStore {
    static func record(at url: URL, named name: String) -> [String: Any] {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count <= 16 << 20 else { return [:] }
        return record(in: [UInt8](d), named: name)
    }

    static func record(in b: [UInt8], named name: String) -> [String: Any] {
        func u32(_ o: Int) -> Int? {
            o >= 0 && o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : nil
        }
        // 文件头：00000001 'Bud1' 根块偏移 大小；文件里的偏移都要加 4
        guard u32(0) == 1, u32(4) == 0x4275_6431, let rootOff = u32(8) else { return [:] }
        let root = rootOff + 4
        guard let n = u32(root), n < 1 << 16 else { return [:] }
        var addrs: [Int] = []
        for i in 0..<n { guard let a = u32(root + 8 + 4 * i) else { return [:] }; addrs.append(a) }
        var p = root + 8 + 4 * ((n + 255) / 256 * 256)
        guard let tocCount = u32(p) else { return [:] }
        p += 4
        var dsdb: Int?
        for _ in 0..<min(tocCount, 256) {
            guard p < b.count else { return [:] }
            let l = Int(b[p])
            guard let v = u32(p + 1 + l) else { return [:] }
            if b[(p + 1)..<(p + 1 + l)].elementsEqual("DSDB".utf8) { dsdb = v }
            p += 5 + l
        }
        // 块地址低 5 位是大小的 log2，其余是偏移
        func block(_ i: Int) -> Int? { i >= 0 && i < addrs.count ? (addrs[i] & ~0x1f) + 4 : nil }
        guard let db = dsdb.flatMap(block), let top = u32(db) else { return [:] }

        let targets = Set([name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
            .map { s in s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] } })
        var out: [String: Any] = [:]
        var visits = 0

        func record(_ p: inout Int) -> Bool {
            guard let l = u32(p), l < 1 << 12, p + 4 + 2 * l + 8 <= b.count else { return false }
            let hit = targets.contains(Array(b[(p + 4)..<(p + 4 + 2 * l)]))
            p += 4 + 2 * l
            let code = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            guard let type = u32(p + 4) else { return false }
            p += 8
            var value: Any?
            switch type {
            case 0x6C6F_6E67, 0x7368_6F72: p += 4                       // long shor
            case 0x7479_7065:                                            // type
                guard p + 4 <= b.count else { return false }
                value = String(decoding: b[p..<(p + 4)], as: UTF8.self); p += 4
            case 0x626F_6F6C: p += 1                                     // bool
            case 0x626C_6F62:                                            // blob
                guard let len = u32(p), p + 4 + len <= b.count else { return false }
                if hit { value = Data(b[(p + 4)..<(p + 4 + len)]) }
                p += 4 + len
            case 0x7573_7472:                                            // ustr
                guard let len = u32(p) else { return false }
                p += 4 + 2 * len
            case 0x636F_6D70, 0x6475_7463: p += 8                       // comp dutc
            default: return false
            }
            if hit, let value { out[code] = value }
            return p <= b.count
        }
        func node(_ i: Int, _ depth: Int) -> Bool {
            visits += 1
            guard depth < 32, visits < 50_000, let o = block(i), let next = u32(o), let c = u32(o + 4), c < 1 << 16 else { return false }
            var p = o + 8
            for _ in 0..<c {
                if next != 0 {
                    guard let child = u32(p), node(child, depth + 1) else { return false }
                    p += 4
                }
                guard record(&p) else { return false }
            }
            return next == 0 || node(next, depth + 1)
        }
        _ = node(top, 0)   // 坏在半路时，前面读到的照样用
        return out
    }
}

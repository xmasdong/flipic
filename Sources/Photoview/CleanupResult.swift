import Foundation
import Vision

enum CleanupCategory: Int, CaseIterable {
    case similar, duplicate, closedEyes, blurry

    var title: String {
        switch self {
        case .similar: return L10n.t("cleanup.similar", "相似连拍")
        case .duplicate: return L10n.t("cleanup.duplicate", "完全重复")
        case .closedEyes: return L10n.t("cleanup.closedEyes", "闭眼")
        case .blurry: return L10n.t("cleanup.blurry", "模糊 / 虚焦")
        }
    }

    var emptyText: String {
        switch self {
        case .similar: return L10n.t("cleanup.empty.similar", "没有发现相似的连拍")
        case .duplicate: return L10n.t("cleanup.empty.duplicate", "没有内容完全相同的文件")
        case .closedEyes: return L10n.t("cleanup.empty.closedEyes", "没有发现闭眼的照片")
        case .blurry: return L10n.t("cleanup.empty.blurry", "没有发现模糊的照片")
        }
    }
}

/// 一组照片：连拍组、同一份内容的多个副本，或闭眼/模糊的整张列表
struct CleanupGroup {
    var units: [CleanupUnit]
    /// 推荐保留的那张（连拍里最好的、重复里的第一份）；闭眼/模糊没有
    var keeper: URL?
    var date: Date?
}

/// 由逐张分析结果推出四个分类与默认勾选
struct CleanupResult {
    var groups: [CleanupCategory: [CleanupGroup]] = [:]
    /// 默认建议删除（勾选）的主文件
    var suggested: Set<URL> = []
    var keepers: Set<URL> = []

    /// 连拍：相邻两张拍摄间隔不超过这个秒数才可能是一组
    static let burstWindow: TimeInterval = 30
    /// 画面特征距离不超过这个值算相似（按特征版本区分量纲）
    static var similarDistance: Float {
        CleanupScanner.printRevision == 1 ? 12 : 0.42
    }
    /// 全图最清晰区域的拉普拉斯方差低于这个值算糊
    static let blurThreshold: Float = 20
    /// 有人脸时看人脸区域，低于这个值算糊
    static let faceBlurThreshold: Float = 10

    static func isBlurry(_ m: CleanupMetrics) -> Bool {
        if let f = m.faceSharpness { return f < faceBlurThreshold }
        return m.sharpness < blurThreshold
    }

    /// 越大越值得保留：没人闭眼优先，其次看清晰度
    static func quality(_ m: CleanupMetrics?) -> Float {
        guard let m else { return -1 }
        let sharp = m.faceSharpness.map { $0 * 4 } ?? m.sharpness
        return (m.closedFaces.isEmpty ? 1_000_000 : 0) + sharp
    }

    static func build(units: [CleanupUnit], scanner: CleanupScanner) -> CleanupResult {
        var r = CleanupResult()

        // 1. 完全重复：同一哈希里按文件名保留第一份
        var dupLosers = Set<URL>()
        var dupKeepers = Set<URL>()
        var byHash: [String: [CleanupUnit]] = [:]
        for u in units { if let h = scanner.hash(of: u.primary) { byHash[h, default: []].append(u) } }
        var dupGroups: [CleanupGroup] = []
        for (_, g) in byHash where g.count > 1 {
            // 保留文件名最短的那份（原件通常没有「副本」「copy」之类后缀）
            let sorted = g.sorted {
                let a = $0.primary.lastPathComponent, b = $1.primary.lastPathComponent
                return a.count == b.count ? a.localizedStandardCompare(b) == .orderedAscending : a.count < b.count
            }
            let keep = sorted[0].primary
            dupGroups.append(CleanupGroup(units: sorted, keeper: keep, date: nil))
            dupKeepers.insert(keep)
            for u in sorted.dropFirst() { dupLosers.insert(u.primary); r.suggested.insert(u.primary) }
        }
        dupGroups.sort { $0.units[0].primary.lastPathComponent.localizedStandardCompare($1.units[0].primary.lastPathComponent) == .orderedAscending }
        r.groups[.duplicate] = dupGroups

        // 2. 相似连拍：按拍摄时间排开，相邻且画面相近的串成一组
        let timed = units.filter { !dupLosers.contains($0.primary) }
            .compactMap { u -> (CleanupUnit, CleanupMetrics)? in scanner.metrics[u.primary].map { (u, $0) } }
            .sorted { $0.1.captureDate == $1.1.captureDate
                ? $0.0.primary.lastPathComponent.localizedStandardCompare($1.0.primary.lastPathComponent) == .orderedAscending
                : $0.1.captureDate < $1.1.captureDate }
        var simGroups: [CleanupGroup] = []
        var current: [(CleanupUnit, CleanupMetrics)] = []
        func flush() {
            if current.count > 1 {
                let best = current.max { quality($0.1) < quality($1.1) }!.0.primary
                simGroups.append(CleanupGroup(units: current.map(\.0), keeper: best,
                                              date: Date(timeIntervalSince1970: current[0].1.captureDate)))
            }
            current = []
        }
        for pair in timed {
            if let last = current.last,
               pair.1.captureDate - last.1.captureDate <= burstWindow,
               let a = scanner.featurePrint(for: last.0.primary), let b = scanner.featurePrint(for: pair.0.primary) {
                var d: Float = .greatestFiniteMagnitude
                try? a.computeDistance(&d, to: b)
                if d <= similarDistance {
                    current.append(pair)
                    continue
                }
            }
            flush()
            current = [pair]
        }
        flush()
        var simLosers = Set<URL>()
        for g in simGroups {
            r.keepers.insert(g.keeper!)
            for u in g.units where u.primary != g.keeper { r.suggested.insert(u.primary); simLosers.insert(u.primary) }
        }
        // 重复里留下的那份，如果在连拍里不是最好的一张，照样建议删（连拍里还有更好的）
        r.keepers.formUnion(dupKeepers.subtracting(simLosers))
        r.groups[.similar] = simGroups

        // 3. 闭眼、4. 模糊：推荐保留的那张不默认勾选
        var closed: [CleanupUnit] = [], blurry: [CleanupUnit] = []
        for (u, m) in timed {
            if !m.closedFaces.isEmpty { closed.append(u) }
            if isBlurry(m) { blurry.append(u) }
        }
        for u in closed + blurry { r.suggested.insert(u.primary) }
        r.groups[.closedEyes] = closed.isEmpty ? [] : [CleanupGroup(units: closed, keeper: nil, date: nil)]
        r.groups[.blurry] = blurry.isEmpty ? [] : [CleanupGroup(units: blurry, keeper: nil, date: nil)]
        // 在任何一组里被推荐保留的，都不默认勾选
        r.suggested.subtract(r.keepers)
        return r
    }

    func count(_ c: CleanupCategory) -> Int {
        (groups[c] ?? []).reduce(0) { $0 + $1.units.count }
    }
}

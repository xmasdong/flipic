import Foundation

/// 相机录视频时顺手写在旁边的附属文件：低清代理、遥测字幕、缩略图、元数据。
/// 删除（进废纸篓）、复制、移动、改名视频时这些跟着视频走，⌘Z 放回时一起放回。
///
/// 只认同一个文件夹里的文件，扩展名和文件名都不分大小写；附属文件本身不进缩略图栏（扩展名都不在 FolderModel.isListable 里）。
/// 一个附属文件同时可能属于文件夹里另一个视频（比如 DJI_0001.MP4 和 DJI_0001.MOV 都在）时不动它。
///
/// 要加新的相机，往 `rules` 里加一行就行：
///
/// | 扩展名 | 命名 | 来源 |
/// |--------|------|------|
/// | .LRF   | 同名：DJI_20231012_0001_D.MP4 ↔ DJI_20231012_0001_D.LRF | 大疆低清代理 |
/// | .SRT   | 同名 | 大疆遥测字幕 |
/// | .THM   | 同名：GX010123.MP4 ↔ GX010123.THM | GoPro / 佳能 / 索尼缩略图 |
/// | .LRV   | 同名 | GoPro 低清（有的机型同名） |
/// | .LRV   | GoPro：GX010123.MP4 / GH010123.MP4 ↔ GL010123.LRV | GoPro 低清 |
/// | .XML   | 索尼：C0001.MP4 ↔ C0001M01.XML（M01…M99） | 索尼片段元数据 |
enum VideoCompanions {
    enum Naming {
        /// 和视频同名，只是扩展名不同
        case sameStem
        /// GoPro：视频 GX / GH 开头，低清版把前两个字母换成 GL
        case goProLowRes
        /// 索尼：视频名后面加 M01…M99
        case sonyClipXML
    }

    struct Rule {
        /// 附属文件的扩展名（小写）
        let ext: String
        let naming: Naming
    }

    static let rules: [Rule] = [
        Rule(ext: "lrf", naming: .sameStem),      // 大疆低清代理
        Rule(ext: "srt", naming: .sameStem),      // 大疆遥测字幕
        Rule(ext: "thm", naming: .sameStem),      // GoPro / 佳能 / 索尼缩略图
        Rule(ext: "lrv", naming: .sameStem),      // GoPro 低清（同名的机型）
        Rule(ext: "lrv", naming: .goProLowRes),   // GoPro 低清 GL…
        Rule(ext: "xml", naming: .sonyClipXML),   // 索尼 C0001M01.XML
    ]

    /// 附属文件名（不带扩展名）可能属于哪些视频名（小写，不带扩展名）
    static func ownerStems(ofCompanionStem stem: String, naming: Naming) -> [String] {
        let s = stem.lowercased()
        switch naming {
        case .sameStem:
            return [s]
        case .goProLowRes:
            guard s.hasPrefix("gl"), s.count > 2 else { return [] }
            let rest = s.dropFirst(2)
            return ["gx" + rest, "gh" + rest]
        case .sonyClipXML:
            guard s.count > 3 else { return [] }
            let tail = s.suffix(3)
            guard tail.first == "m", tail.dropFirst().allSatisfy(\.isASCIIDigit), tail != "m00" else { return [] }
            return [String(s.dropLast(3))]
        }
    }

    /// 视频 video 的附属文件（真实文件名）。不是视频时返回空。会列一次目录，别在每帧都调
    static func files(of video: URL) -> [URL] {
        guard Video.isVideo(video) else { return [] }
        let dir = video.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return match(video: video.lastPathComponent, among: names).map { dir.appendingPathComponent($0) }
    }

    /// 纯按名字算（自测和 files(of:) 共用）：names 是同一文件夹里的全部文件名
    static func match(video name: String, among names: [String]) -> [String] {
        let mainLower = name.lowercased()
        let mainStem = (mainLower as NSString).deletingPathExtension
        // 文件夹里别的视频：附属文件也可能属于它们
        var otherVideoStems = Set<String>()
        for n in names where Video.isVideoName(n) && n.lowercased() != mainLower {
            otherVideoStems.insert((n.lowercased() as NSString).deletingPathExtension)
        }
        var out: [String] = []
        for n in names {
            let ext = (n as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, !Video.isVideoName(n) else { continue }
            let stem = (n as NSString).deletingPathExtension
            for r in rules where r.ext == ext {
                let owners = ownerStems(ofCompanionStem: stem, naming: r.naming)
                guard owners.contains(mainStem) else { continue }
                if owners.contains(where: otherVideoStems.contains) { continue }
                if !out.contains(n) { out.append(n) }
            }
        }
        return out.sorted()
    }

    /// 视频从 oldStem 改成 newStem（都不带扩展名）时，附属文件 companionName 该叫什么；不是这个视频的附属文件返回 nil
    static func renamed(_ companionName: String, oldStem: String, newStem: String) -> String? {
        let ns = companionName as NSString
        let ext = ns.pathExtension, stem = ns.deletingPathExtension
        let oldLower = oldStem.lowercased()
        for r in rules where r.ext == ext.lowercased() {
            guard ownerStems(ofCompanionStem: stem, naming: r.naming).contains(oldLower) else { continue }
            let newName: String
            switch r.naming {
            case .sameStem:
                newName = newStem
            case .goProLowRes:
                // 新名字还是 GoPro 的 GX / GH 开头：照样把前两个字母换成 GL（保持原来的大小写）；否则退回同名
                let lower = newStem.lowercased()
                if (lower.hasPrefix("gx") || lower.hasPrefix("gh")), newStem.count > 2 {
                    let g = stem.prefix(2)
                    newName = String(g) + newStem.dropFirst(2)
                } else {
                    newName = newStem
                }
            case .sonyClipXML:
                newName = newStem + stem.suffix(3)
            }
            return ext.isEmpty ? newName : newName + "." + ext
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

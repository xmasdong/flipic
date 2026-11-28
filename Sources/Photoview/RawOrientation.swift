import Foundation
import ImageIO

/// RAW 无损转 90°：只改文件里的方向标记，照片数据一个字节不动。
/// 方向标记可能在好几处都有（ARW 三个 IFD、RW2 和 RAF 内嵌 JPEG 的 EXIF、CR3 的 CMT1），只改一处系统不一定认，
/// 所以把能找到的都改成同一个值。先在 APFS 克隆出来的临时副本上改，用系统重新读一遍方向确认改对了，再换回去
enum RawOrientation {
    /// 能无损改方向的扩展名（其余 RAW 仍然另存 JPEG）
    static let extensions: Set<String> = ["arw", "nef", "nrw", "cr2", "cr3", "dng", "pef", "srw", "sr2", "srf", "erf", "3fr",
                                          "iiq", "mos", "mef", "orf", "ori", "rw2", "rwl", "raf"]

    private static let cycle = [1: 6, 6: 3, 3: 8, 8: 1]

    /// 自测专用：为 true 时 systemOrientation 一律返回 nil，模拟系统不认识这台相机。只由 --rawrotatetest 设置
    nonisolated(unsafe) static var forceUnrecognised = false

    /// 这个文件能不能无损转（格式对、找得到方向标记、方向不是镜像）。
    /// 系统认识就用系统读到的方向；系统不认识（新相机、旧系统）就读文件自己的方向标记，所有标记必须一致
    static func canRotate(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()),
              let (current, _) = currentOrientation(url), cycle[current] != nil,
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return !(orientationSpots(h).isEmpty)
    }

    /// 当前方向和它的来源（true = 系统读到的）。系统不认识时读文件里所有标记，不一致或没有则 nil
    private static func currentOrientation(_ url: URL) -> (Int, Bool)? {
        if let o = systemOrientation(url) { return (o, true) }
        if let o = fileOrientation(url) { return (o, false) }
        return nil
    }

    /// 文件里所有方向标记的共同值（0 当 1）；没有标记或各处不一致返回 nil
    static func fileOrientation(_ url: URL) -> Int? {
        guard extensions.contains(url.pathExtension.lowercased()),
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return spotValues(h, orientationSpots(h))
    }

    /// 自测用：方向标记在文件里的字节位置
    static func spotOffsets(_ url: URL) -> [UInt64] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        return orientationSpots(h).map(\.offset)
    }

    private static func spotValues(_ h: FileHandle, _ spots: [Spot]) -> Int? {
        guard !spots.isEmpty else { return nil }
        var common: Int?
        for s in spots {
            h.seek(toFileOffset: s.offset)
            guard let d = try? h.read(upToCount: 2), d.count == 2 else { return nil }
            let raw = s.littleEndian ? Int(d[d.startIndex]) | Int(d[d.startIndex + 1]) << 8 : Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
            let v = raw == 0 ? 1 : raw
            if let c = common, c != v { return nil }
            common = v
        }
        return common
    }

    /// 转 turns 个 90°（顺时针）后写到 out。out 可以等于 url（覆盖原图）。成功返回 true
    static func write(url: URL, clockwiseTurns turns: Int, to out: URL) -> Bool {
        writeWithError(url: url, clockwiseTurns: turns, to: out).ok
    }

    /// 带错误原因的无损写回：文件系统/权限报错返回具体 localizedDescription，格式校验不通过返回 nil（供上层兜底另存 JPEG）
    static func writeWithError(url: URL, clockwiseTurns turns: Int, to out: URL) -> (ok: Bool, error: String?) {
        let turns = ((turns % 4) + 4) % 4
        guard let (current, fromSystem) = currentOrientation(url), cycle[current] != nil else { return (false, nil) }
        var o = current
        for _ in 0..<turns { o = cycle[o]! }
        let fm = FileManager.default
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".flipic-rotate-\(UUID().uuidString).\(url.pathExtension)")
        do { try fm.copyItem(at: url, to: tmp) } catch { return (false, error.localizedDescription) }   // APFS 上是克隆，不占空间、很快
        func fail(_ err: String? = nil) -> (Bool, String?) { try? fm.removeItem(at: tmp); return (false, err) }
        // 相机卡里设过「保护」的照片拷出来可能是 0444 只读；如果原文件本身没有 Finder 锁定（uchg），先给临时副本加上写权限再改方向字节
        if let attrs = try? fm.attributesOfItem(atPath: tmp.path),
           let perm = attrs[.posixPermissions] as? Int, (perm & 0o200) == 0 {
            try? fm.setAttributes([.posixPermissions: perm | 0o200], ofItemAtPath: tmp.path)
        }
        let h: FileHandle
        do { h = try FileHandle(forUpdating: tmp) } catch { return fail(error.localizedDescription) }
        let spots = orientationSpots(h)
        guard !spots.isEmpty else { try? h.close(); return fail() }
        for s in spots {
            h.seek(toFileOffset: s.offset)
            let v = UInt16(o)
            h.write(Data(s.littleEndian ? [UInt8(v & 0xff), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xff)]))
        }
        try? h.synchronize()
        try? h.close()
        if fromSystem {
            // 用系统重新读：方向要等于算出来的值
            guard systemOrientation(tmp) == o else { return fail() }
        } else {
            // 系统读不了：重新打开解析，每处标记都要等于新值，文件大小不变；系统若还给出方向，也要等于新值
            guard let h2 = try? FileHandle(forReadingFrom: tmp) else { return fail() }
            let again = spotValues(h2, orientationSpots(h2))
            try? h2.close()
            let sizeBefore = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
            let sizeAfter = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? UInt64) ?? nil
            guard again == o, sizeBefore != nil, sizeBefore == sizeAfter else { return fail() }
            if let src = CGImageSourceCreateWithURL(tmp as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
               let io = props[kCGImagePropertyOrientation as String] as? Int {
                guard (io == 0 ? 1 : io) == o else { return fail() }
            }
        }
        do {
            try Straighten.replaceFile(tmp, at: out)
            return (true, nil)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// 系统读到的方向；系统不认识这种 RAW（读不出尺寸）时为 nil，改读文件自己的方向标记
    private static func systemOrientation(_ url: URL) -> Int? {
        if forceUnrecognised { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              (props[kCGImagePropertyPixelWidth as String] as? Int ?? 0) > 0 else { return nil }
        let o = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        return o == 0 ? 1 : o
    }

    private struct Spot { var offset: UInt64; var littleEndian: Bool }

    // MARK: - 找方向标记

    private final class Reader {
        let h: FileHandle
        let size: UInt64
        init(_ h: FileHandle) { self.h = h; size = (try? h.seekToEnd()) ?? 0 }
        func read(_ off: UInt64, _ n: Int) -> Data? {
            guard n >= 0, off + UInt64(n) <= size else { return nil }
            h.seek(toFileOffset: off)
            guard let d = try? h.read(upToCount: n), d.count == n else { return nil }
            return Data(d)
        }
        func be32(_ off: UInt64) -> UInt64? {
            guard let d = read(off, 4) else { return nil }
            return d.reduce(0) { $0 << 8 | UInt64($1) }
        }
    }

    /// 文件里所有 TIFF 块（起点 + 字节序）里的方向标记位置
    private static func orientationSpots(_ h: FileHandle) -> [Spot] {
        let r = Reader(h)
        guard let head = r.read(0, 16) else { return [] }
        var bases: [UInt64] = []
        if head[0] == 0x49 && head[1] == 0x49 || head[0] == 0x4D && head[1] == 0x4D {
            bases.append(0)                                         // TIFF 结构：ARW NEF CR2 DNG PEF ORF RW2…
        } else if head.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
            // RAF：文件头 84 字节处是内嵌 JPEG 的位置，方向在它的 EXIF 里
            if let jpg = r.be32(84), let b = exifBase(inJPEGAt: jpg, r) { bases.append(b) }
        } else if head[4...7].elementsEqual(Array("ftyp".utf8)) {
            bases += cr3Bases(r)                                    // CR3：moov 里佳能 uuid 下的 CMT1
        }
        var spots: [Spot] = []
        var seenBases = Set<UInt64>()
        while let base = bases.first {
            bases.removeFirst()
            guard !seenBases.contains(base), seenBases.count < 8 else { continue }
            seenBases.insert(base)
            let (found, embedded) = scanTIFF(at: base, r)
            spots += found
            bases += embedded
        }
        return spots
    }

    /// 从 base 起的 TIFF：走主 IFD 链、SubIFD、EXIF IFD，收集方向标记；顺带找出内嵌 JPEG 里的 EXIF（RW2）
    private static func scanTIFF(at base: UInt64, _ r: Reader) -> ([Spot], [UInt64]) {
        guard let head = r.read(base, 8) else { return ([], []) }
        let le: Bool
        switch (head[0], head[1]) {
        case (0x49, 0x49): le = true
        case (0x4D, 0x4D): le = false
        default: return ([], [])
        }
        func u16(_ d: Data, _ i: Int) -> Int { le ? Int(d[i]) | Int(d[i + 1]) << 8 : Int(d[i]) << 8 | Int(d[i + 1]) }
        func u32(_ d: Data, _ i: Int) -> UInt64 {
            let b = (0..<4).map { UInt64(d[i + $0]) }
            return le ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }
        // 42 标准 TIFF；0x4F52 / 0x5352 奥林巴斯 ORF；0x55 松下 RW2
        guard [42, 0x4F52, 0x5352, 0x55].contains(u16(head, 2)) else { return ([], []) }
        var spots: [Spot] = []
        var embedded: [UInt64] = []
        var seen = Set<UInt64>()
        var queue: [UInt64] = [u32(head, 4)]
        while let rel = queue.first, seen.count < 32 {
            queue.removeFirst()
            let off = base + rel
            guard rel >= 8, !seen.contains(off), let cd = r.read(off, 2) else { continue }
            seen.insert(off)
            let n = u16(cd, 0)
            guard n > 0, n < 1000, let entries = r.read(off + 2, n * 12 + 4) else { continue }
            for i in 0..<n {
                let e = i * 12
                let tag = u16(entries, e), type = u16(entries, e + 2), count = u32(entries, e + 4)
                if tag == 0x0112, type == 3, count == 1 {
                    spots.append(Spot(offset: off + 2 + UInt64(e) + 8, littleEndian: le))
                } else if tag == 0x8769, count == 1 {          // EXIF IFD
                    queue.append(u32(entries, e + 8))
                } else if tag == 0x014A {                      // SubIFDs
                    if count == 1 { queue.append(u32(entries, e + 8)) }
                    else if count <= 16, let list = r.read(base + u32(entries, e + 8), Int(count) * 4) {
                        for k in 0..<Int(count) { queue.append(u32(list, k * 4)) }
                    }
                } else if tag == 0x002E, base == 0, count > 4 {  // RW2 的 JpgFromRaw：完整 JPEG，EXIF 里还有一份方向
                    if let b = exifBase(inJPEGAt: u32(entries, e + 8), r) { embedded.append(b) }
                }
            }
            let next = u32(entries, n * 12)
            if next != 0 { queue.append(next) }
        }
        return (spots, embedded)
    }

    /// JPEG 里 APP1 Exif 段的 TIFF 起点
    private static func exifBase(inJPEGAt start: UInt64, _ r: Reader) -> UInt64? {
        guard let soi = r.read(start, 2), soi[0] == 0xFF, soi[1] == 0xD8 else { return nil }
        var p = start + 2
        for _ in 0..<32 {
            guard let m = r.read(p, 4), m[0] == 0xFF else { return nil }
            let marker = m[1]
            if marker == 0xDA || marker == 0xD9 { return nil }     // 到图像数据了
            let len = UInt64(m[2]) << 8 | UInt64(m[3])
            if marker == 0xE1, let tag = r.read(p + 4, 6), tag.elementsEqual(Array("Exif".utf8) + [0, 0]) {
                return p + 10
            }
            p += 2 + len
        }
        return nil
    }

    /// CR3（ISO BMFF）：moov › uuid(85c0b687-820f-11e0-8111-f4ce462b6a48) › CMT1 是 IFD0 的 TIFF
    private static func cr3Bases(_ r: Reader) -> [UInt64] {
        let canon: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]
        /// 在 [from, to) 里逐个读盒子，返回 (类型, 内容起点, 结束)
        func boxes(_ from: UInt64, _ to: UInt64) -> [(String, UInt64, UInt64)] {
            var out: [(String, UInt64, UInt64)] = []
            var p = from
            while p + 8 <= to, out.count < 64 {
                guard let hd = r.read(p, 8) else { break }
                var size = hd[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let type = String(bytes: hd[4..<8], encoding: .ascii) ?? ""
                var body = p + 8
                if size == 1, let big = r.read(p + 8, 8) { size = big.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }; body = p + 16 }
                if size == 0 { size = to - p }
                guard size >= 8, p + size <= to else { break }
                out.append((type, body, p + size))
                p += size
            }
            return out
        }
        guard let moov = boxes(0, r.size).first(where: { $0.0 == "moov" }) else { return [] }
        for b in boxes(moov.1, moov.2) where b.0 == "uuid" {
            guard let id = r.read(b.1, 16), id.elementsEqual(canon) else { continue }
            return boxes(b.1 + 16, b.2).filter { $0.0 == "CMT1" }.map { $0.1 }
        }
        return []
    }
}

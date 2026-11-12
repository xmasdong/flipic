import Foundation
import ImageIO

/// RAW 无损转 90°：只改文件里的方向标记，照片数据一个字节不动。
/// 适用于 TIFF 结构的 RAW（索尼 ARW、尼康 NEF、佳能 CR2、DNG、宾得 PEF 等）。
/// 方向标记可能在好几个 IFD 里都有（ARW 三处），只改第一处系统不认，所以把能找到的都改掉。
/// 先在 APFS 克隆出来的临时副本上改，用系统重新读一遍方向确认改对了，再换回去
enum RawOrientation {
    /// 能无损改方向的扩展名（其余 RAW 仍然另存 JPEG）
    static let extensions: Set<String> = ["arw", "nef", "nrw", "cr2", "dng", "pef", "srw", "sr2", "srf", "erf", "3fr", "iiq", "mos", "mef"]

    private static let cycle = [1: 6, 6: 3, 3: 8, 8: 1]

    /// 这个文件能不能无损转（格式对、找得到方向标记、方向不是镜像）
    static func canRotate(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()), systemDecodes(url),
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let spots = orientationSpots(h), let first = spots.first else { return false }
        return cycle[first.value] != nil || first.value == 0
    }

    /// 转 turns 个 90°（顺时针）后写到 out。out 可以等于 url（覆盖原图）。成功返回 true
    static func write(url: URL, clockwiseTurns turns: Int, to out: URL) -> Bool {
        let turns = ((turns % 4) + 4) % 4
        let fm = FileManager.default
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".flipic-rotate-\(UUID().uuidString).\(url.pathExtension)")
        do { try fm.copyItem(at: url, to: tmp) } catch { return false }   // APFS 上是克隆，不占空间、很快
        func fail() -> Bool { try? fm.removeItem(at: tmp); return false }
        guard let h = try? FileHandle(forUpdating: tmp) else { return fail() }
        guard let spots = orientationSpots(h), let first = spots.first else { try? h.close(); return fail() }
        var o = first.value == 0 ? 1 : first.value
        guard cycle[o] != nil else { try? h.close(); return fail() }
        for _ in 0..<turns { o = cycle[o]! }
        for s in spots {
            h.seek(toFileOffset: s.offset)
            let v = UInt16(o)
            h.write(Data(s.littleEndian ? [UInt8(v & 0xff), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xff)]))
        }
        try? h.synchronize()
        try? h.close()
        // 用系统重新读：方向要等于算出来的值
        guard let src = CGImageSourceCreateWithURL(tmp as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              (props[kCGImagePropertyOrientation as String] as? Int ?? 1) == o else { return fail() }
        do {
            if fm.fileExists(atPath: out.path) { _ = try fm.replaceItemAt(out, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: out) }
            return true
        } catch { return fail() }
    }

    /// 系统认识这种 RAW（读得出尺寸）。不认识的新相机只能看内嵌预览，方向改了也确认不了，不碰
    private static func systemDecodes(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return false }
        return (props[kCGImagePropertyPixelWidth as String] as? Int ?? 0) > 0
    }

    private struct Spot { var offset: UInt64; var value: Int; var littleEndian: Bool }

    /// 找出所有 IFD（主链 + SubIFD + EXIF）里的方向标记位置，第一个是 IFD0 的
    private static func orientationSpots(_ h: FileHandle) -> [Spot]? {
        h.seek(toFileOffset: 0)
        guard let head = try? h.read(upToCount: 8), head.count == 8 else { return nil }
        let le: Bool
        switch (head[0], head[1]) {
        case (0x49, 0x49): le = true
        case (0x4D, 0x4D): le = false
        default: return nil
        }
        let size = (try? h.seekToEnd()) ?? 0
        func u16(_ d: Data, _ i: Int) -> Int { le ? Int(d[i]) | Int(d[i + 1]) << 8 : Int(d[i]) << 8 | Int(d[i + 1]) }
        func u32(_ d: Data, _ i: Int) -> UInt64 {
            let b = (0..<4).map { UInt64(d[i + $0]) }
            return le ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }
        guard u16(head, 2) == 42 else { return nil }   // 标准 TIFF 魔数（ORF / RW2 用别的，不碰）
        func read(_ off: UInt64, _ n: Int) -> Data? {
            guard off + UInt64(n) <= size else { return nil }
            h.seek(toFileOffset: off)
            guard let d = try? h.read(upToCount: n), d.count == n else { return nil }
            return d
        }
        var spots: [Spot] = []
        var seen = Set<UInt64>()
        var queue: [UInt64] = [u32(head, 4)]
        while let off = queue.first, seen.count < 32 {
            queue.removeFirst()
            guard off >= 8, !seen.contains(off), let cd = read(off, 2) else { continue }
            seen.insert(off)
            let n = u16(cd, 0)
            guard n > 0, n < 1000, let entries = read(off + 2, n * 12 + 4) else { continue }
            for i in 0..<n {
                let e = i * 12
                let tag = u16(entries, e), type = u16(entries, e + 2), count = u32(entries, e + 4)
                if tag == 0x0112, type == 3, count == 1 {
                    spots.append(Spot(offset: off + 2 + UInt64(e) + 8, value: u16(entries, e + 8), littleEndian: le))
                } else if tag == 0x8769, count == 1 {          // EXIF IFD
                    queue.append(u32(entries, e + 8))
                } else if tag == 0x014A {                      // SubIFDs
                    if count == 1 { queue.append(u32(entries, e + 8)) }
                    else if count <= 16, let list = read(u32(entries, e + 8), Int(count) * 4) {
                        for k in 0..<Int(count) { queue.append(u32(list, k * 4)) }
                    }
                }
            }
            let next = u32(entries, n * 12)
            if next != 0 { queue.append(next) }
        }
        // IFD0 的那个排第一（它决定当前方向）
        return spots.isEmpty ? nil : spots
    }
}

import Foundation
import ImageIO
import CryptoKit

/// `--rawrotatetest <工作文件夹> <RAW 文件夹>`：RAW 无损转向自测。
/// 每个 RAW 复制到工作文件夹，分别在「系统认识」和「系统不认识（forceUnrecognised）」两种情况下转 1、2、3、4 圈，
/// 查方向标记、像素数据（除方向标记的字节外逐字节相同）、临时文件。最后一行 RAWROTATE checks=N failures=M
enum RawRotateSelfTest {
    private static var checks = 0
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("RAWROTATE \(ok ? "ok  " : "FAIL") \(what)")
    }

    private static let cycle = [1: 6, 6: 3, 3: 8, 8: 1]

    private static func sipsOrientation(_ url: URL) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-g", "orientation", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "orientation: ") else { return nil }
        if text[r.upperBound...].hasPrefix("<nil>") { return 1 }   // sips 对默认方向不打印数字
        return Int(text[r.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// 第三方读法：exiftool（没装就跳过）
    static let exiftool = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"].first { FileManager.default.isExecutableFile(atPath: $0) }
    private static func exiftoolOrientation(_ url: URL) -> Int? {
        guard let exe = exiftool else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-n", "-s3", "-Orientation", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func ioOrientation(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        return props[kCGImagePropertyOrientation as String] as? Int
    }

    private static func hash(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "?" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func leftovers(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".flipic-rotate-") }
    }

    static func run(workDir: String, rawDir: String) -> Never {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: workDir), src = URL(fileURLWithPath: rawDir)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let names = ((try? fm.contentsOfDirectory(atPath: src.path)) ?? []).sorted()
            .filter { RawOrientation.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        check(!names.isEmpty, "found \(names.count) RAW files in \(rawDir)")

        for name in names {
            let original = src.appendingPathComponent(name)
            let originalHash = hash(original)
            for forced in [true, false] {
                let tag = "\(name) \(forced ? "unrecognised" : "system")"
                let dir = work.appendingPathComponent(forced ? "forced" : "system")
                try? fm.removeItem(at: dir.appendingPathComponent(name))
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(name)
                guard (try? fm.copyItem(at: original, to: url)) != nil else { check(false, "\(tag) copy"); continue }
                RawOrientation.forceUnrecognised = forced
                defer { RawOrientation.forceUnrecognised = false }

                let baseBytes = (try? Data(contentsOf: url)) ?? Data()
                let spots = Set(RawOrientation.spotOffsets(url).flatMap { [$0, $0 + 1] })
                check(!spots.isEmpty, "\(tag) found orientation spots (\(spots.count / 2))")
                check(RawOrientation.canRotate(url), "\(tag) canRotate")
                check(Straighten.canOverwrite(url), "\(tag) canOverwrite")
                guard var expected = RawOrientation.fileOrientation(url) else { check(false, "\(tag) own parse of start orientation"); continue }
                if !forced, let sys = ioOrientation(url) { check(sys == expected || (sys == 0 && expected == 1), "\(tag) start: ImageIO \(sys) == own \(expected)") }
                let startOrientation = expected

                for turns in 1...4 {
                    for _ in 0..<turns { expected = cycle[expected]! }
                    let out = Straighten.save(url: url, quarterTurns: turns, degrees: 0, crop: nil, overwrite: true)
                    check(out.result == .lossless && out.url == url, "\(tag) turns=\(turns) result lossless")
                    check(RawOrientation.fileOrientation(url) == expected, "\(tag) turns=\(turns) own parser == \(expected)")
                    if !forced {
                        check(ioOrientation(url) == expected, "\(tag) turns=\(turns) ImageIO == \(expected) (got \(ioOrientation(url).map(String.init) ?? "nil"))")
                        // sips 对 RAW 不报方向（恒为 nil），只在它真给出数字时才比
                        if let sp = sipsOrientation(url), sp != 1 || expected == 1 { check(sp == expected, "\(tag) turns=\(turns) sips == \(expected)") }
                    } else if let io = ioOrientation(url) {
                        check(io == expected, "\(tag) turns=\(turns) ImageIO (still readable here) == \(expected)")
                    }
                    if RawRotateSelfTest.exiftool != nil {
                        check(exiftoolOrientation(url) == expected, "\(tag) turns=\(turns) exiftool == \(expected) (got \(exiftoolOrientation(url).map(String.init) ?? "nil"))")
                    }
                    let now = (try? Data(contentsOf: url)) ?? Data()
                    var same = now.count == baseBytes.count
                    var diff = 0
                    if same {
                        let chunk = 1 << 20
                        var start = 0
                        while start < now.count, same {
                            let end = min(start + chunk, now.count)
                            if now[start..<end] != baseBytes[start..<end] {   // 只对有差异的块逐字节找
                                for i in start..<end where now[i] != baseBytes[i] { diff += 1; if !spots.contains(UInt64(i)) { same = false; break } }
                            }
                            start = end
                        }
                    }
                    check(same && diff <= spots.count, "\(tag) turns=\(turns) only orientation bytes changed (\(diff) bytes differ)")
                    check(leftovers(dir).isEmpty, "\(tag) turns=\(turns) no .flipic-rotate-* leftovers")
                    // 查看器路径：内嵌预览读到的方向（强制不认识时 ImageIO 路径被跳过，只剩自己解析）
                    EmbeddedPreview.forget(url)
                    if let f = EmbeddedPreview.locate(url) {
                        check(f.orientation == expected, "\(tag) turns=\(turns) EmbeddedPreview orientation \(f.orientation) == \(expected)")
                    } else { check(false, "\(tag) turns=\(turns) EmbeddedPreview found preview") }
                }
                check(expected == cycle[cycle[startOrientation]!]!, "\(tag) 10 quarter turns in total = start rotated 180 degrees")
                // 拒绝路径：标记被人为改得不一致时，不能无损转
                if forced, let spot = RawOrientation.spotOffsets(url).first, RawOrientation.spotOffsets(url).count > 1 {
                    let copy = dir.appendingPathComponent("mixed-" + name)
                    try? fm.removeItem(at: copy)
                    if (try? fm.copyItem(at: url, to: copy)) != nil, let h = try? FileHandle(forUpdating: copy) {
                        let cur = RawOrientation.fileOrientation(copy) ?? 1
                        h.seek(toFileOffset: spot)
                        let other = cur == 3 ? 6 : 3
                        let le = [UInt8(other), 0], be = [0, UInt8(other)]
                        // 按原字节序写：读出原来两字节判断
                        let before = (try? Data(contentsOf: copy).subdata(in: Int(spot)..<Int(spot) + 2)) ?? Data()
                        h.write(Data(before.first == 0 && before.last != 0 ? be : le))
                        try? h.close()
                        check(RawOrientation.fileOrientation(copy) == nil, "\(tag) mixed spots -> own parse nil")
                        check(!RawOrientation.canRotate(copy), "\(tag) mixed spots -> not rotatable")
                    }
                    try? fm.removeItem(at: copy)
                }
                try? fm.removeItem(at: url)
            }
            check(hash(original) == originalHash, "\(name) source file untouched")
        }
        print("RAWROTATE checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

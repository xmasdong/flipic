import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 拉直（任意角度旋转）：转完自动居中裁成和原图同比例的最大正矩形，跟「照片」App、Lightroom 的拉直一样。
/// 角度顺时针为正，范围 ±45°；更大的角度先用 90° 旋转（R / L）
enum Straighten {
    static let maxDegrees: Double = 45

    /// 转 degrees 度之后，保持原比例、完全落在照片里的最大裁剪框，是原尺寸的几分之几
    static func cropScale(width w: CGFloat, height h: CGFloat, degrees: Double) -> CGFloat {
        let t = abs(degrees) * .pi / 180
        guard t > 0, w > 0, h > 0 else { return 1 }
        let c = CGFloat(cos(t)), s = CGFloat(sin(t))
        return min(w / (w * c + h * s), h / (w * s + h * c))
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 先转 quarterTurns 个 90°（顺时针为正），再顺时针转 degrees 度，居中裁成同比例的正矩形
    static func render(_ src: CGImage, quarterTurns: Int = 0, degrees: Double) -> CGImage? {
        var ci = CIImage(cgImage: src)
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: ci = ci.oriented(.right)
        case 2: ci = ci.oriented(.down)
        case 3: ci = ci.oriented(.left)
        default: break
        }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        let w = ci.extent.width, h = ci.extent.height
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        if degrees != 0 {
            // Core Image 的坐标 y 朝上，逆时针为正，所以顺时针要取负
            let rad = -degrees * .pi / 180
            let center = CGPoint(x: w / 2, y: h / 2)
            ci = ci.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: rad).translatedBy(x: -center.x, y: -center.y))
            let k = cropScale(width: w, height: h, degrees: degrees)
            let cw = max(1, (w * k).rounded(.down)), ch = max(1, (h * k).rounded(.down))
            rect = CGRect(x: ((w - cw) / 2).rounded(.up), y: ((h - ch) / 2).rounded(.up), width: cw, height: ch)
        }
        let deep = src.bitsPerComponent > 8
        let space = src.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(ci, from: rect, format: deep ? .RGBAh : .RGBA8, colorSpace: space)
    }

    // MARK: - 保存

    enum Target: String { case ask, overwrite, copy }

    /// 设置 › 看图 › 保存旋转：每次询问 / 覆盖原图 / 另存一份
    static var saveTarget: Target {
        get { Target(rawValue: UserDefaults.standard.string(forKey: "rotationSaveTarget") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "rotationSaveTarget") }
    }

    /// 翻到别的照片时，提醒这张的旋转还没保存。默认开
    static var remindUnsaved: Bool {
        get { UserDefaults.standard.object(forKey: "rotationRemindUnsaved") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rotationRemindUnsaved") }
    }

    /// 能原样写回这种格式吗（WebP 等只能另存成 JPEG）。
    /// RAW 只转 90° 时可以只改方向标记、无损写回；拉直过的 RAW 只能另存成 JPEG
    static func canOverwrite(_ url: URL, degrees: Double = 0) -> Bool {
        if CleanupUnit.isRaw(url) { return degrees == 0 && RawOrientation.canRotate(url) }
        guard
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(src) else { return false }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(type as String)
    }

    /// 另存的文件名：IMG_1234-旋转.jpg，重名就 IMG_1234-旋转 2.jpg
    static func copyURL(for url: URL, ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + L10n.t("rot.copySuffix", "-旋转")
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) \(n)"
            let candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    struct Outcome {
        var result: ImageLoader.RotationWriteResult
        var url: URL?
    }

    /// 把视图上的旋转写进文件。overwrite = false 时另存一份，原图不动。
    /// 只转了 90° 的：能写方向标记的格式不动像素（无损）；拉直过的要重新编码，JPEG/HEIC 用 0.95 质量，拍摄信息保留
    static func save(url: URL, quarterTurns: Int, degrees: Double, overwrite: Bool) -> Outcome {
        let turns = ((quarterTurns % 4) + 4) % 4
        // RAW 只转 90°：改方向标记，原图或副本都保持 RAW。改不了就退回另存 JPEG
        if CleanupUnit.isRaw(url), degrees == 0, RawOrientation.canRotate(url) {
            let out = overwrite ? url : copyURL(for: url, ext: url.pathExtension)
            if overwrite { FolderWatcher.noteOwnWrite(url) }
            if RawOrientation.write(url: url, clockwiseTurns: turns, to: out) {
                if overwrite { ImageLoader.shared.evict(url: url) }
                return Outcome(result: .lossless, url: out)
            }
            let fallback = copyURL(for: url, ext: "jpg")
            let r = reencode(url: url, turns: turns, degrees: degrees, to: fallback, type: UTType.jpeg.identifier)
            return Outcome(result: r, url: r == .failed ? nil : fallback)
        }
        // RAW 走到这里说明拉直过（或改不了方向标记）：只能另存 JPEG
        let writable = !CleanupUnit.isRaw(url) && canOverwrite(url)
        if overwrite {
            guard writable else { return Outcome(result: .failed, url: nil) }
            if degrees == 0 {
                return Outcome(result: ImageLoader.writeRotation(url: url, clockwiseTurns: turns), url: url)
            }
            let r = reencode(url: url, turns: turns, degrees: degrees, to: url, type: nil)
            if r != .failed {
                FolderWatcher.noteOwnWrite(url)
                ImageLoader.shared.evict(url: url)
            }
            return Outcome(result: r, url: url)
        }
        // 另存：能写回的格式用原格式，RAW 等存成 JPEG
        let ext = writable ? url.pathExtension : "jpg"
        let out = copyURL(for: url, ext: ext)
        if degrees == 0, writable, let lossless = losslessCopy(url: url, turns: turns, to: out) {
            return Outcome(result: lossless, url: out)
        }
        let r = reencode(url: url, turns: turns, degrees: degrees, to: out, type: writable ? nil : UTType.jpeg.identifier)
        return Outcome(result: r, url: r == .failed ? nil : out)
    }

    /// 只转 90°、另存：原样拷贝数据，只改方向标记。格式不支持方向标记时返回 nil，改走重新编码
    private static func losslessCopy(url: URL, turns: Int, to out: URL) -> ImageLoader.RotationWriteResult? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(src) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let cycle = [1: 6, 6: 3, 3: 8, 8: 1]
        var orientation = (props[kCGImagePropertyOrientation as String] as? Int).map { $0 == 0 ? 1 : $0 } ?? 1
        for _ in 0..<turns { orientation = cycle[orientation] ?? orientation }
        props[kCGImagePropertyOrientation as String] = orientation
        let tmp = tempURL(near: out)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return nil }
        guard let check = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let written = (CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [String: Any])?[kCGImagePropertyOrientation as String] as? Int,
              written == orientation else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return place(tmp, at: out) ? .lossless : .failed
    }

    /// 解全分辨率（已按方向校正）→ 转 + 裁 → 按 type（nil = 原格式）编码，拍摄信息带过去，方向改成正常
    private static func reencode(url: URL, turns: Int, degrees: Double, to out: URL, type: String?) -> ImageLoader.RotationWriteResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let srcType = CGImageSourceGetType(src),
              let full = ImageLoader.decodedFull(url: url),
              let rendered = render(full, quarterTurns: turns, degrees: degrees) else { return .failed }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = rendered.width
            exif[kCGImagePropertyExifPixelYDimension as String] = rendered.height
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                  kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            props.removeValue(forKey: k as String)
        }
        props[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        let tmp = tempURL(near: out)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, (type ?? srcType as String) as CFString, 1, nil) else { return .failed }
        CGImageDestinationAddImage(dest, rendered, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); return .failed }
        return place(tmp, at: out) ? .reencoded : .failed
    }

    private static func tempURL(near out: URL) -> URL {
        out.deletingLastPathComponent().appendingPathComponent(".flipic-rotate-\(UUID().uuidString).\(out.pathExtension)")
    }

    /// 临时文件换到目标位置（覆盖时用 replaceItem，保留原文件的创建时间、标签等）
    private static func place(_ tmp: URL, at out: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: out.path) {
                _ = try fm.replaceItemAt(out, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: out)
            }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
    }
}

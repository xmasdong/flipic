import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 裁剪与拉直。拉直（任意角度旋转）：没手动裁时，转完自动居中裁成和原图同比例的最大正矩形，跟「照片」App、Lightroom 的拉直一样；
/// 手动裁过就按裁剪框（CropGeometry）出图。角度顺时针为正，范围 ±45°；更大的角度先用 90° 旋转（R / L）
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

    /// 输出的像素尺寸。turned 是转好 90° 的照片尺寸，crop 是手动裁剪框（nil = 没裁，拉直时取同比例最大框）
    static func outputSize(turned q: CGSize, degrees: Double, crop: CropGeometry.Crop?) -> CGSize {
        if let crop { return CropGeometry.pixelRect(crop, image: q, degrees: degrees).size }
        guard degrees != 0 else { return q }
        let k = cropScale(width: q.width, height: q.height, degrees: degrees)
        return CGSize(width: max(1, (q.width * k).rounded(.down)), height: max(1, (q.height * k).rounded(.down)))
    }

    /// 先转 quarterTurns 个 90°（顺时针为正），再顺时针转 degrees 度；
    /// crop（单位是 src 转好 90° 后的像素）非 nil 时按它裁，否则居中裁成同比例的正矩形
    static func render(_ src: CGImage, quarterTurns: Int = 0, degrees: Double, crop: CropGeometry.Crop? = nil) -> CGImage? {
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
            // 先把边缘像素往外延伸再转：裁剪框贴着照片边时，角上的像素不会混进透明（存成 JPEG 就是发黑的一个点）
            ci = ci.clampedToExtent().transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: rad).translatedBy(x: -center.x, y: -center.y))
        }
        if let crop {
            // 裁剪框是左上原点、y 朝下；Core Image 是左下原点
            let r = CropGeometry.pixelRect(crop, image: CGSize(width: w, height: h), degrees: degrees)
            rect = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        } else if degrees != 0 {
            let k = cropScale(width: w, height: h, degrees: degrees)
            let cw = max(1, (w * k).rounded(.down)), ch = max(1, (h * k).rounded(.down))
            rect = CGRect(x: ((w - cw) / 2).rounded(.up), y: ((h - ch) / 2).rounded(.up), width: cw, height: ch)
        }
        let deep = src.bitsPerComponent > 8
        let space = src.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(ci, from: rect, format: deep ? .RGBAh : .RGBA8, colorSpace: space)
    }

    /// 视图上的裁剪框换到解出来的全图上（两边尺寸万一不一样，按比例换算）
    static func scaledCrop(_ crop: CropSpec?, full: CGImage, turns: Int) -> CropGeometry.Crop? {
        guard let crop, crop.space.width > 0 else { return nil }
        let k = ((turns % 4) + 4) % 4
        let turnedWidth = CGFloat(k % 2 == 0 ? full.width : full.height)
        return crop.crop.scaled(by: turnedWidth / crop.space.width)
    }

    /// 把视图上看到的样子（90° 旋转、拉直角度、裁剪框）用到一张解好的图上。导出用；只转了 90° 的走原来的路
    static func applied(to full: CGImage, turns: Int, degrees: Double, crop: CropSpec?) -> CGImage? {
        if degrees == 0, crop == nil { return ImageLoader.rotated(full, quarterTurns: turns) }
        return render(full, quarterTurns: turns, degrees: degrees, crop: scaledCrop(crop, full: full, turns: turns))
    }

    // MARK: - 保存

    enum Target: String { case ask, overwrite, copy }

    /// 测试用：保存各阶段的耗时（--cropspeedtest 挂上，平时是 nil）
    static var profile: ((String, Double) -> Void)?
    @inline(__always) static func stage<T>(_ name: String, _ body: () -> T) -> T {
        guard let profile else { return body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = body()
        profile(name, CFAbsoluteTimeGetCurrent() - t0)
        return r
    }

    /// 设置 › 看图 › 保存修改：每次询问 / 覆盖原图 / 另存一份。裁剪过的不会不问就覆盖原图（见 ViewerViewController.saveRotation）
    static var saveTarget: Target {
        get { Target(rawValue: UserDefaults.standard.string(forKey: "rotationSaveTarget") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "rotationSaveTarget") }
    }

    /// 翻到别的照片时，提醒这张的修改（旋转、拉直、裁剪）还没保存。默认开
    static var remindUnsaved: Bool {
        get { UserDefaults.standard.object(forKey: "rotationRemindUnsaved") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rotationRemindUnsaved") }
    }

    /// 能原样写回这种格式吗（WebP 等只能另存成 JPEG）。
    /// RAW 只转 90° 时可以只改方向标记、无损写回；裁剪或拉直过的 RAW 只能另存成 JPEG
    static func canOverwrite(_ url: URL, degrees: Double = 0, cropped: Bool = false) -> Bool {
        if CleanupUnit.isRaw(url) { return degrees == 0 && !cropped && RawOrientation.canRotate(url) }
        guard
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(src) else { return false }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(type as String)
    }

    /// 另存的文件名：IMG_1234-旋转.jpg，裁过的是 IMG_1234-裁剪.jpg；重名就 IMG_1234-旋转 2.jpg
    static func copyURL(for url: URL, ext: String, cropped: Bool = false) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
            + (cropped ? L10n.t("rot.cropSuffix", "-裁剪") : L10n.t("rot.copySuffix", "-旋转"))
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
        /// 重新编码写出的文件的像素尺寸（旋转、拉直、裁剪后）；无损旋转时是 nil
        var pixelSize: CGSize?
    }

    /// 手动裁剪框和它所在的尺寸（转好 90° 的原图像素）。保存时解出来的全图尺寸万一不一样，按比例换算
    struct CropSpec {
        var crop: CropGeometry.Crop
        var space: CGSize
    }

    /// 把视图上的旋转和裁剪写进文件。overwrite = false 时另存一份，原图不动。
    /// 只转了 90° 的：能写方向标记的格式不动像素（无损）；裁剪或拉直过的要重新编码，JPEG/HEIC 用 0.95 质量，拍摄信息保留
    static func save(url: URL, quarterTurns: Int, degrees: Double, crop: CropSpec? = nil, overwrite: Bool) -> Outcome {
        beginSave()
        defer { endSave() }
        let turns = ((quarterTurns % 4) + 4) % 4
        let cropped = crop != nil
        // RAW 只转 90°：改方向标记，原图或副本都保持 RAW。改不了就退回另存 JPEG
        if CleanupUnit.isRaw(url), degrees == 0, !cropped, RawOrientation.canRotate(url) {
            let out = overwrite ? url : copyURL(for: url, ext: url.pathExtension)
            if overwrite { FolderWatcher.noteOwnWrite(url) }
            if RawOrientation.write(url: url, clockwiseTurns: turns, to: out) {
                if overwrite { ImageLoader.shared.evict(url: url) }
                return Outcome(result: .lossless, url: out)
            }
            let fallback = copyURL(for: url, ext: "jpg")
            let r = reencode(url: url, turns: turns, degrees: degrees, to: fallback, type: UTType.jpeg.identifier)
            return Outcome(result: r.result, url: r.result == .failed ? nil : fallback, pixelSize: r.size)
        }
        // RAW 走到这里说明裁剪或拉直过（或改不了方向标记）：只能另存 JPEG
        let writable = !CleanupUnit.isRaw(url) && canOverwrite(url)
        if overwrite {
            guard writable else { return Outcome(result: .failed, url: nil) }
            if degrees == 0, !cropped {
                return Outcome(result: ImageLoader.writeRotation(url: url, clockwiseTurns: turns), url: url)
            }
            let r = reencode(url: url, turns: turns, degrees: degrees, crop: crop, to: url, type: nil)
            if r.result != .failed {
                FolderWatcher.noteOwnWrite(url)
                ImageLoader.shared.evict(url: url)
            }
            return Outcome(result: r.result, url: url, pixelSize: r.size)
        }
        // 另存：能写回的格式用原格式，RAW 等存成 JPEG
        let ext = writable ? url.pathExtension : "jpg"
        let out = copyURL(for: url, ext: ext, cropped: cropped)
        if degrees == 0, !cropped, writable, let lossless = losslessCopy(url: url, turns: turns, to: out) {
            return Outcome(result: lossless, url: out)
        }
        let r = reencode(url: url, turns: turns, degrees: degrees, crop: crop, to: out, type: writable ? nil : UTType.jpeg.identifier)
        return Outcome(result: r.result, url: r.result == .failed ? nil : out, pixelSize: r.size)
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
    private static func reencode(url: URL, turns: Int, degrees: Double, crop: CropSpec? = nil, to out: URL, type: String?) -> (result: ImageLoader.RotationWriteResult, size: CGSize?) {
        let failed: (result: ImageLoader.RotationWriteResult, size: CGSize?) = (.failed, nil)
        // 点保存之前就在后台解好的全图（见 prewarm）：和下面自己解的是同一个调用，文件没动过才用
        let warmed = takeWarm(url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let srcType = CGImageSourceGetType(src),
              let full = warmed ?? stage("1.decode", { ImageLoader.decodedFull(url: url) }) else { return failed }
        guard let rendered = stage("2.render", { render(full, quarterTurns: turns, degrees: degrees, crop: scaledCrop(crop, full: full, turns: turns)) }) else { return failed }
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
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, (type ?? srcType as String) as CFString, 1, nil) else { return failed }
        // 连同文件里原样的 XMP / IPTC 一起带过去（只按属性字典写会丢图库自定义的 XMP、IPTC 的拍摄日期等）；
        // 方向和像素尺寸改成新的。读不出元数据的格式退回只写属性字典
        let fixedMeta = stage("3.metadata", { ImageExporter.fixedMetadata(from: src, width: rendered.width, height: rendered.height) })
        stage("4a.addImage") {
            if let fixed = fixedMeta {
                let options: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.95, kCGImagePropertyOrientation as String: 1]
                CGImageDestinationAddImageAndMetadata(dest, rendered, fixed, options as CFDictionary)
            } else {
                CGImageDestinationAddImage(dest, rendered, props as CFDictionary)
            }
        }
        guard stage("4b.encode", { CGImageDestinationFinalize(dest) }) else { try? FileManager.default.removeItem(at: tmp); return failed }
        return stage("5.replace", { place(tmp, at: out) }) ? (.reencoded, CGSize(width: rendered.width, height: rendered.height)) : failed
    }

    // MARK: - 提前解码

    /// 裁剪、拉直要把整张照片解开再编码，解码是保存里最长的一段（6000 万像素的 JPEG 要 0.2～0.4 秒）。
    /// 点「完成」的时候就在后台解好，用户看对话框、点「覆盖原图」的这段时间里它已经备好了。
    /// 解的是 ImageLoader.decodedFull(url:)，和保存时自己解的完全是同一个调用；记下解之前文件的修改时间和大小，
    /// 保存时文件变过就不用，重新解。一次只留一张（最多约 1.5 亿像素，8 位约 600 MB 以内）
    final class WarmDecode {
        let url: URL
        let stamp: FolderWatcher.Stamp?
        private let group = DispatchGroup()
        private var image: CGImage?
        init(url: URL) {
            self.url = url
            stamp = FolderWatcher.stamp(of: url)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return }
                let w = p[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                guard w * h <= 150_000_000, CGImageSourceGetCount(src) == 1 else { return }
                image = ImageLoader.decodedFull(url: url)
            }
        }
        func wait() -> CGImage? { group.wait(); return image }
    }

    private static var warm: WarmDecode?
    private static let warmLock = NSLock()

    static func prewarm(_ url: URL) {
        warmLock.lock(); defer { warmLock.unlock() }
        if let w = warm, w.url == url, w.stamp == FolderWatcher.stamp(of: url) { return }
        let w = WarmDecode(url: url)
        warm = w
        // 一直没保存也不留着占内存：两分钟后放掉（保存时会重新解）
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            warmLock.lock(); defer { warmLock.unlock() }
            if warm === w { warm = nil }
        }
    }

    static func releaseWarm() {
        warmLock.lock(); warm = nil; warmLock.unlock()
    }

    /// 取走备好的全图（等它解完）；不是这个文件、或文件在解之后变过，返回 nil
    static func takeWarm(_ url: URL) -> CGImage? {
        warmLock.lock()
        let w = warm
        warm = nil
        warmLock.unlock()
        guard let w, w.url == url, w.stamp != nil, w.stamp == FolderWatcher.stamp(of: url) else { return nil }
        return w.wait()
    }

    // MARK: - 正在写盘的保存（退出时要等它写完）

    private static var activeSaves = 0
    private static var idleHandlers: [() -> Void] = []
    private static let saveLock = NSLock()

    private static func beginSave() { saveLock.lock(); activeSaves += 1; saveLock.unlock() }

    private static func endSave() {
        saveLock.lock()
        activeSaves -= 1
        let handlers = activeSaves == 0 ? idleHandlers : []
        if activeSaves == 0 { idleHandlers = [] }
        saveLock.unlock()
        if !handlers.isEmpty { DispatchQueue.main.async { handlers.forEach { $0() } } }
    }

    static var hasActiveSave: Bool { saveLock.lock(); defer { saveLock.unlock() }; return activeSaves > 0 }

    /// 没有保存在写盘时马上回调，否则等最后一个写完（在主线程回调）
    static func whenSavesDone(_ f: @escaping () -> Void) {
        saveLock.lock()
        if activeSaves == 0 { saveLock.unlock(); f(); return }
        idleHandlers.append(f)
        saveLock.unlock()
    }

    private static func tempURL(near out: URL) -> URL {
        out.deletingLastPathComponent().appendingPathComponent("\(FolderWatcher.tempPrefix)\(UUID().uuidString).\(out.pathExtension)")
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

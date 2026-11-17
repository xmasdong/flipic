import CoreGraphics
import Foundation
import Vision

/// 裁剪、切图时把框放到主体上（免费功能，共用代码）。
/// 主体：缩成 1024 像素以内的小图交给 Vision，先找人脸（取几张脸的并集，小脸不算），没有脸就用注意力显著性的显著物体并集，
/// 都没有就是 nil（框留在照片中心）。结果是归一化的框（0…1，左上原点，相对没转过的照片），按「照片路径 + 修改时间」缓存。
/// 全部在后台队列跑，不联网
enum CropSubject {
    /// 小于最大那张脸这个比例的脸不算主体（路人、背景里的小脸）
    static let faceWeightFloor: CGFloat = 0.25
    /// 老的裁剪自测假定框在正中，跑它时关掉对准主体
    static var disabledForTest = false
    static let maxSide = 1024

    private static let queue = DispatchQueue(label: "flipic.cropsubject", qos: .userInitiated)
    private static let lock = NSLock()
    private static var cache: [String: CGRect?] = [:]
    private static var order: [String] = []
    private static var waiting: [String: [(CGRect?) -> Void]] = [:]

    /// 缓存键：照片路径 + 修改时间
    static func key(for url: URL) -> String {
        let t = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(t)"
    }

    /// 缓存里有就返回（外层 nil = 没算过；内层 nil = 算过，没有主体）
    static func cached(_ key: String) -> CGRect?? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    static func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]; order = []
    }

    /// 后台找主体，完成后在主线程回调；同一张图同时来几次只算一遍
    static func find(key: String, image: CGImage, completion: @escaping (CGRect?) -> Void) {
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            completion(hit)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            lock.unlock()
            return
        }
        waiting[key] = [completion]
        lock.unlock()
        queue.async {
            let rect = detect(image)
            lock.lock()
            cache[key] = .some(rect)
            order.append(key)
            if order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }
            let done = waiting.removeValue(forKey: key) ?? []
            lock.unlock()
            DispatchQueue.main.async { for f in done { f(rect) } }
        }
    }

    /// 同步检测（调用方放在后台）。返回归一化、左上原点的主体框
    static func detect(_ image: CGImage) -> CGRect? {
        guard let small = downscaled(image) else { return nil }
        let handler = VNImageRequestHandler(cgImage: small, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faces])) != nil, let found = faces.results, !found.isEmpty {
            return topLeft(faceBox(found.map(\.boundingBox)))
        }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([attention])) != nil, let obs = attention.results?.first,
           let objects = obs.salientObjects, !objects.isEmpty {
            return topLeft(objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) })
        }
        return nil
    }

    /// 几张脸取并集，但比最大的脸小太多的不算（越大的脸权重越高）
    static func faceBox(_ faces: [CGRect]) -> CGRect {
        let biggest = faces.map { $0.width * $0.height }.max() ?? 0
        let kept = faces.filter { $0.width * $0.height >= biggest * faceWeightFloor }
        return (kept.isEmpty ? faces : kept).reduce(CGRect.null) { $0.union($1) }
    }

    private static func topLeft(_ r: CGRect) -> CGRect {
        let c = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !c.isNull, c.width > 0, c.height > 0 else { return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        return CGRect(x: c.minX, y: 1 - c.maxY, width: c.width, height: c.height)
    }

    private static func downscaled(_ image: CGImage) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > 0 else { return nil }
        let k = min(1, CGFloat(maxSide) / CGFloat(long))
        let w = max(1, Int((CGFloat(image.width) * k).rounded())), h = max(1, Int((CGFloat(image.height) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 几何

    /// 归一化的框（左上原点）跟着照片顺时针转 turns 个 90°
    static func turned(_ r: CGRect, clockwise turns: Int) -> CGRect {
        var out = r
        for _ in 0..<(((turns % 4) + 4) % 4) {
            // (u, v) → (1 - v, u)
            out = CGRect(x: 1 - out.maxY, y: out.minX, width: out.height, height: out.width)
        }
        return out
    }

    /// 这个比例的框：尽量大，挪到主体上（主体框尽量整个落在框里、框尽量以主体为中心），再夹在照片里。
    /// subject 是转好 90° 的照片里归一化的主体框，nil 就是居中。degrees 是拉直角度，框按 CropGeometry 的规则留在转过的照片里
    static func place(ratio: CGFloat, image: CGSize, degrees: Double, subject: CGRect?) -> CropGeometry.Crop {
        let base = CropGeometry.fitted(CropGeometry.Crop(center: .zero, size: CGSize(width: ratio, height: 1)),
                                       image: image, degrees: degrees, grow: true)
        guard let s = subject, image.width > 0, image.height > 0 else { return base }
        let p = CGPoint(x: (s.midX - 0.5) * image.width, y: (s.midY - 0.5) * image.height)
        return CropGeometry.moved(base, to: CropGeometry.fromImage(p, degrees: degrees), image: image, degrees: degrees)
    }
}

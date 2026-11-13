import Foundation
import ImageIO
import Vision
import CryptoKit

/// 清理模式里的一张「照片」：RAW+JPG 同名时合成一项，分析用 JPG，删除时连带 RAW
struct CleanupUnit: Hashable {
    let primary: URL
    let companions: [URL]
    let fileSize: Int
    let modified: Date?

    var allURLs: [URL] { [primary] + companions }

    static let rawExtensions: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
                                             "nrw", "crw", "sr2", "srf", "3fr", "fff", "iiq", "erf", "rwl", "mrw", "kdc", "dcr", "mef", "mos", "gpr", "x3f"]

    static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }

    /// 按「文件夹 + 不含扩展名的文件名」配对
    static func make(from items: [ImageItem]) -> [CleanupUnit] {
        var groups: [String: [ImageItem]] = [:]
        var order: [String] = []
        // 清理只看照片，视频不参与
        for it in items where !Video.isVideo(it.url) {
            let key = it.url.deletingPathExtension().path.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(it)
        }
        var units: [CleanupUnit] = []
        for key in order {
            let g = groups[key]!
            // 有非 RAW 的就用它分析（解码快、所见即所得），其余作为附带文件
            let main = g.first { !isRaw($0.url) } ?? g[0]
            let rest = g.filter { $0.url != main.url }.map(\.url)
            if !isRaw(main.url), g.filter({ !isRaw($0.url) }).count > 1 {
                // 同名的 JPG 与 PNG 等不是一组相机输出，各自独立
                for it in g {
                    units.append(CleanupUnit(primary: it.url, companions: [], fileSize: it.fileSize, modified: it.modified))
                }
                continue
            }
            units.append(CleanupUnit(primary: main.url, companions: rest,
                                     fileSize: g.reduce(0) { $0 + $1.fileSize }, modified: main.modified))
        }
        return units
    }
}

/// 单张照片的分析结果，按「文件名 + 大小 + 修改时间」缓存到磁盘
struct CleanupMetrics: Codable {
    var fileSize: Int
    var modified: Double
    var captureDate: Double
    /// 全图清晰度：最清晰的几块区域的拉普拉斯方差均值（大光圈虚化背景不拉低它）
    var sharpness: Float
    /// 最大那张人脸区域的清晰度；没有足够大的人脸为 nil
    var faceSharpness: Float?
    var faceCount: Int
    /// 闭眼的人脸框（归一化，左上原点）
    var closedFaces: [CGRect]
    /// 每张可判定人脸的睁眼程度（两眼里较大的那只，高/宽），供调阈值
    var eyeOpenness: [Float]
    /// 每张可判定人脸眼睛区域里深色像素的比例（两眼取大）
    var eyeDarkness: [Float]
    /// 每张可判定人脸的位置和睁眼数据，连拍里按位置认出同一个人（Pro 的连拍比对用）
    var faces: [FaceEyes]?
    var featurePrint: Data?
    var printRevision: Int
    /// 分析算法或阈值改了就加一，旧缓存自动作废
    var version: Int
}

struct FaceEyes: Codable {
    /// 人脸框（归一化，左上原点）
    var rect: CGRect
    var openness: Float
    var darkness: Float
}

/// 后台逐张分析文件夹，结果回主线程
final class CleanupScanner {
    let units: [CleanupUnit]
    private(set) var metrics: [URL: CleanupMetrics] = [:]
    /// 内容完全相同的文件：sha256 → 主文件
    private(set) var hashes: [URL: String] = [:]
    private(set) var done = 0
    private(set) var finished = false
    private(set) var elapsed: TimeInterval = 0

    var onProgress: (() -> Void)?
    var onFinish: (() -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Flipic.cleanup"
        q.maxConcurrentOperationCount = CleanupScanner.workers
        q.qualityOfService = .utility
        return q
    }()
    /// 并行路数：核心数的一半，2~6 路。实测 917 张人像 2 路 21 秒、4 路 11 秒、6 路 8 秒，再多基本不涨；
    /// 每多一路内存多约 20MB。FLIPIC_CLEANUP_WORKERS 仅测速用
    static let workers: Int = {
        if let v = Int(ProcessInfo.processInfo.environment["FLIPIC_CLEANUP_WORKERS"] ?? ""), v > 0 { return v }
        return min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 6)
    }()
    private let lock = NSLock()
    private let cacheURL: URL?
    private var cancelled = false
    private var prints: [URL: VNFeaturePrintObservation] = [:]

    static let analysisMaxPixel: CGFloat = 1280
    static let metricsVersion = 2

    init(folder: URL, units: [CleanupUnit], useCache: Bool = true) {
        self.units = units
        cacheURL = useCache ? Self.cacheFile(for: folder) : nil
    }

    deinit { queue.cancelAllOperations() }

    func featurePrint(for url: URL) -> VNFeaturePrintObservation? {
        if let p = prints[url] { return p }
        guard let data = metrics[url]?.featurePrint,
              let p = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else { return nil }
        prints[url] = p
        return p
    }

    func start() {
        let started = Date()
        #if FLIPIC_PRO
        // 工作台在后台还有没写完的缓存（刚查完又打开同一个文件夹）：等它写完再读；没有时立刻往下走
        Self.saveQueue.sync {}
        #endif
        let cached = loadCache()
        var todo: [CleanupUnit] = []
        for u in units {
            if let m = cached[u.primary.lastPathComponent], m.fileSize == u.fileSize,
               m.modified == (u.modified?.timeIntervalSince1970 ?? 0), m.printRevision == Self.printRevision, m.version == Self.metricsVersion {
                metrics[u.primary] = m
            } else {
                todo.append(u)
            }
        }
        done = units.count - todo.count
        DispatchQueue.main.async { self.onProgress?() }

        // 只对大小相同的文件算哈希，绝大多数文件一次都不用读全
        let bySize = Dictionary(grouping: units.filter { $0.fileSize > 0 }, by: \.fileSize).values.filter { $0.count > 1 }
        let hashOp = BlockOperation { [weak self] in
            for group in bySize {
                for u in group {
                    guard let self, !self.cancelled else { return }
                    if let h = Self.sha256(of: u.primary) {
                        self.lock.lock(); self.hashes[u.primary] = h; self.lock.unlock()
                    }
                }
            }
        }
        queue.addOperation(hashOp)

        var lastPing = Date()
        for u in todo {
            queue.addOperation { [weak self] in
                guard let self, !self.cancelled else { return }
                let m = autoreleasepool { Self.analyze(u) }
                DispatchQueue.main.async {
                    guard !self.cancelled else { return }
                    if let m { self.metrics[u.primary] = m }
                    self.done += 1
                    // 进度回调限流，避免几千张时主线程被刷新淹没
                    if Date().timeIntervalSince(lastPing) > 0.25 || self.done == self.units.count {
                        lastPing = Date()
                        self.onProgress?()
                    }
                }
            }
        }
        queue.addBarrierBlock { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                self.finished = true
                self.elapsed = Date().timeIntervalSince(started)
                self.saveCache()
                self.onProgress?()
                self.onFinish?()
            }
        }
    }

    func cancel() {
        cancelled = true
        queue.cancelAllOperations()
        saveCache()
    }

    func hash(of url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hashes[url]
    }

    // MARK: - 单张分析

    static var printRevision: Int {
        if #available(macOS 14.0, *) { return VNGenerateImageFeaturePrintRequestRevision2 }
        return VNGenerateImageFeaturePrintRequestRevision1
    }

    static func analyze(_ unit: CleanupUnit) -> CleanupMetrics? {
        let url = unit.primary
        // RAW 用内嵌的大预览，JPEG 等走降采样解码
        guard let img = ImageLoader.renderThumbnail(url: url, maxPixel: analysisMaxPixel,
                                                    allowEmbedded: CleanupUnit.isRaw(url)) else { return nil }
        let gray = GrayImage(img)

        let faces = VNDetectFaceLandmarksRequest()
        let printReq = VNGenerateImageFeaturePrintRequest()
        printReq.revision = printRevision
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([faces, printReq])

        var closed: [CGRect] = []
        var openness: [Float] = []
        var darkness: [Float] = []
        var faceEyes: [FaceEyes] = []
        var faceSharp: Float?
        var faceCount = 0
        var largest: CGFloat = 0
        let size = CGSize(width: img.width, height: img.height)
        for f in faces.results ?? [] {
            let box = f.boundingBox
            let px = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                            width: box.width * size.width, height: box.height * size.height)
            // 太小的脸看不清眼睛，判不准就不判
            guard px.height >= 40 else { continue }
            faceCount += 1
            if px.height > largest {
                largest = px.height
                faceSharp = gray.laplacianVariance(in: px.insetBy(dx: px.width * 0.12, dy: px.height * 0.12))
            }
            if let yaw = f.yaw?.doubleValue, abs(yaw) > 1.0 { continue }
            guard let lm = f.landmarks, let l = lm.leftEye, let r = lm.rightEye else { continue }
            let o = max(eyeOpenness(l, size), eyeOpenness(r, size))
            // 睁开的眼睛里有一块深色的瞳孔/虹膜，闭上只剩一条睫毛线
            let dark = max(gray.darkFraction(eyeRect(l, size), face: px), gray.darkFraction(eyeRect(r, size), face: px))
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            openness.append(o)
            darkness.append(dark)
            faceEyes.append(FaceEyes(rect: rect, openness: o, darkness: dark))
            if o < closedEyeThreshold || (o < closedEyeSoftThreshold && dark < closedEyeDarkThreshold) {
                closed.append(rect)
            }
        }

        var printData: Data?
        if let obs = printReq.results?.first {
            printData = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
        }
        let capture = FolderModel.readCaptureDate(url: url, fallback: unit.modified)
        return CleanupMetrics(fileSize: unit.fileSize, modified: unit.modified?.timeIntervalSince1970 ?? 0,
                              captureDate: capture.timeIntervalSince1970,
                              sharpness: gray.sharpness(), faceSharpness: faceSharp, faceCount: faceCount,
                              closedFaces: closed, eyeOpenness: openness, eyeDarkness: darkness, faces: faceEyes,
                              featurePrint: printData, printRevision: printRevision, version: metricsVersion)
    }

    /// 两眼都低于这个睁开程度（眼裂高/宽）算闭眼
    static let closedEyeThreshold: Float = 0.19

    /// 眼裂偏窄、眼睛区域又几乎没有深色瞳孔时也算闭眼（眼镜反光、侧光时轮廓点不准）
    static let closedEyeSoftThreshold: Float = 0.36
    static let closedEyeDarkThreshold: Float = 0.14

    /// 眼睛轮廓的外接矩形（左上原点像素坐标）
    private static func eyeRect(_ region: VNFaceLandmarkRegion2D, _ size: CGSize) -> CGRect {
        let pts = region.pointsInImage(imageSize: size)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return .zero }
        return CGRect(x: minX, y: size.height - maxY, width: maxX - minX, height: maxY - minY)
    }

    private static func eyeOpenness(_ region: VNFaceLandmarkRegion2D, _ size: CGSize) -> Float {
        let pts = region.pointsInImage(imageSize: size)
        guard pts.count >= 4 else { return 1 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
        return w > 0 ? Float(h / w) : 1
    }

    private static func sha256(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        // 每块读完立即释放，否则后台线程上几百 MB 的读缓冲会一直攒到操作结束
        while autoreleasepool(invoking: {
            guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 缓存（放在 Flipic 自己的缓存目录，不往照片文件夹写任何东西）

    private static func cacheFile(for folder: URL) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Flipic/Cleanup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".plist")
    }

    private func loadCache() -> [String: CleanupMetrics] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? PropertyListDecoder().decode([String: CleanupMetrics].self, from: data)) ?? [:]
    }

    #if FLIPIC_PRO
    /// 工作台用：缓存在后台编码写盘，几千张时不卡主线程（清理模式不设，照旧当场写）
    var savesCacheInBackground = false
    private static let saveQueue = DispatchQueue(label: "flipic.cleanup.save", qos: .utility)
    #endif

    private func saveCache() {
        guard let cacheURL, !metrics.isEmpty else { return }
        #if FLIPIC_PRO
        if savesCacheInBackground {
            let snapshot = metrics
            Self.saveQueue.async { Self.write(snapshot, to: cacheURL) }
            return
        }
        #endif
        Self.write(metrics, to: cacheURL)
    }

    private static func write(_ metrics: [URL: CleanupMetrics], to cacheURL: URL) {
        var out: [String: CleanupMetrics] = [:]
        for (u, m) in metrics { out[u.lastPathComponent] = m }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        try? enc.encode(out).write(to: cacheURL, options: .atomic)
    }
}

// MARK: - 灰度图与清晰度

private struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(_ img: CGImage) {
        width = img.width
        height = img.height
        var buf = [UInt8](repeating: 0, count: width * height)
        buf.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                   bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
        }
        pixels = buf
    }

    /// 矩形（左上原点像素坐标）内四个方向（横、竖、两条对角）二阶差分的能量，取最弱的方向：
    /// 手抖的运动模糊只抹掉一个方向的细节，用最弱方向才能把它和清楚的照片分开
    func laplacianVariance(in rect: CGRect) -> Float {
        let x0 = max(1, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX))
        let y0 = max(1, Int(rect.minY)), y1 = min(height - 1, Int(rect.maxY))
        guard x1 - x0 > 4, y1 - y0 > 4 else { return 0 }
        var e = [Double](repeating: 0, count: 4)
        var n = 0
        let w = width
        pixels.withUnsafeBufferPointer { p in
            for y in y0..<y1 {
                let row = y * w
                for x in x0..<x1 {
                    let i = row + x
                    let c = 2 * Int(p[i])
                    let h = Int(p[i - 1]) + Int(p[i + 1]) - c
                    let v = Int(p[i - w]) + Int(p[i + w]) - c
                    let d1 = Int(p[i - w - 1]) + Int(p[i + w + 1]) - c
                    let d2 = Int(p[i - w + 1]) + Int(p[i + w - 1]) - c
                    e[0] += Double(h * h); e[1] += Double(v * v)
                    e[2] += Double(d1 * d1); e[3] += Double(d2 * d2)
                    n += 1
                }
            }
        }
        // 对角方向步长是 √2，能量按距离平方折算回来
        let dirs = [e[0], e[1], e[2] / 2, e[3] / 2]
        return Float(dirs.min()! / Double(n))
    }

    /// 眼睛矩形里比人脸中间亮度暗一半以上的像素占比
    func darkFraction(_ eye: CGRect, face: CGRect) -> Float {
        let fx0 = max(0, Int(face.minX)), fx1 = min(width, Int(face.maxX))
        let fy0 = max(0, Int(face.minY)), fy1 = min(height, Int(face.maxY))
        // 眼睛框上下各放宽一点，免得轮廓点压着瞳孔时漏掉
        let e = eye.insetBy(dx: 0, dy: -eye.height * 0.3)
        let ex0 = max(0, Int(e.minX)), ex1 = min(width, Int(e.maxX))
        let ey0 = max(0, Int(e.minY)), ey1 = min(height, Int(e.maxY))
        guard fx1 > fx0, fy1 > fy0, ex1 > ex0, ey1 > ey0 else { return 1 }
        var hist = [Int](repeating: 0, count: 256)
        var total = 0
        for y in stride(from: fy0, to: fy1, by: 2) {
            for x in stride(from: fx0, to: fx1, by: 2) { hist[Int(pixels[y * width + x])] += 1; total += 1 }
        }
        var acc = 0, median = 128
        for (v, c) in hist.enumerated() { acc += c; if acc * 2 >= total { median = v; break } }
        let cut = median / 2
        var dark = 0, n = 0
        for y in ey0..<ey1 {
            for x in ex0..<ex1 { if Int(pixels[y * width + x]) < cut { dark += 1 }; n += 1 }
        }
        return n > 0 ? Float(dark) / Float(n) : 1
    }

    /// 切成 6×6 块，取最清晰的 4 块的均值：画面里有一处清楚（对上焦的主体）就不算糊
    func sharpness() -> Float {
        let cols = 6, rows = 6
        let tw = CGFloat(width) / CGFloat(cols), th = CGFloat(height) / CGFloat(rows)
        var tiles: [Float] = []
        for r in 0..<rows {
            for c in 0..<cols {
                tiles.append(laplacianVariance(in: CGRect(x: CGFloat(c) * tw, y: CGFloat(r) * th, width: tw, height: th)))
            }
        }
        let top = tiles.sorted(by: >).prefix(4)
        return top.reduce(0, +) / Float(top.count)
    }
}

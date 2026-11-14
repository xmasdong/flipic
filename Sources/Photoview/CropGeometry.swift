import CoreGraphics
import Foundation

/// 裁剪框的几何，全是纯函数，不碰界面。
/// 坐标：原点在「转好 90° 的照片」中心，x 朝右、y 朝下，单位是原图像素。
/// 裁剪框永远是正的（和屏幕对齐），照片在它下面绕中心顺时针转了 degrees 度。
/// 裁剪框不露出照片外面 = 框的四个角转回照片自己的坐标后都落在 W×H 里
enum CropGeometry {
    struct Crop: Equatable {
        var center: CGPoint
        var size: CGSize

        init(center: CGPoint, size: CGSize) {
            self.center = center
            self.size = size
        }

        init(rect: CGRect) {
            center = CGPoint(x: rect.midX, y: rect.midY)
            size = rect.size
        }

        var rect: CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }

        var aspect: CGFloat { size.height > 0 ? size.width / size.height : 1 }

        /// 换算到另一个分辨率（预览图上算显示、原图上算保存）
        func scaled(by k: CGFloat) -> Crop {
            Crop(center: CGPoint(x: center.x * k, y: center.y * k), size: CGSize(width: size.width * k, height: size.height * k))
        }
    }

    /// 比例：原比例、自由、1:1、4:5、3:2、16:9
    enum Aspect: Int, CaseIterable {
        case original, free, square, r4x5, r3x2, r16x9

        /// 能不能横竖互换（自由和 1:1 换了也一样）
        var swappable: Bool { self != .free && self != .square }

        /// 宽 / 高；自由返回 nil。swapped = 横竖互换过
        func ratio(image: CGSize, swapped: Bool) -> CGFloat? {
            let r: CGFloat
            switch self {
            case .free: return nil
            case .original: r = image.height > 0 ? image.width / image.height : 1
            case .square: r = 1
            case .r4x5: r = 4.0 / 5.0
            case .r3x2: r = 3.0 / 2.0
            case .r16x9: r = 16.0 / 9.0
            }
            return swapped ? 1 / r : r
        }
    }

    /// 八个手柄：dx / dy 是它在框的哪一边（-1 左 / 上，0 中间，1 右 / 下）
    enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var direction: (dx: Int, dy: Int) {
            switch self {
            case .topLeft: return (-1, -1)
            case .top: return (0, -1)
            case .topRight: return (1, -1)
            case .right: return (1, 0)
            case .bottomRight: return (1, 1)
            case .bottom: return (0, 1)
            case .bottomLeft: return (-1, 1)
            case .left: return (-1, 0)
            }
        }

        /// 手柄在框上的位置
        func point(on r: CGRect) -> CGPoint {
            let d = direction
            return CGPoint(x: d.dx < 0 ? r.minX : (d.dx > 0 ? r.maxX : r.midX),
                           y: d.dy < 0 ? r.minY : (d.dy > 0 ? r.maxY : r.midY))
        }
    }

    private static func trig(_ degrees: Double) -> (c: CGFloat, s: CGFloat) {
        let t = degrees * .pi / 180
        return (CGFloat(cos(t)), CGFloat(sin(t)))
    }

    /// 屏幕方向的点 → 照片自己的坐标（把顺时针转的 degrees 转回去）
    static func toImage(_ p: CGPoint, degrees: Double) -> CGPoint {
        let (c, s) = trig(degrees)
        return CGPoint(x: p.x * c + p.y * s, y: -p.x * s + p.y * c)
    }

    /// 照片自己的坐标 → 屏幕方向
    static func fromImage(_ p: CGPoint, degrees: Double) -> CGPoint {
        let (c, s) = trig(degrees)
        return CGPoint(x: p.x * c - p.y * s, y: p.x * s + p.y * c)
    }

    /// 框转回照片坐标后，在照片的宽、高方向各占多少（一半）
    private static func halfExtent(_ size: CGSize, degrees: Double) -> CGSize {
        let (c, s) = trig(abs(degrees))
        let a = size.width / 2, b = size.height / 2
        return CGSize(width: a * c + b * s, height: a * s + b * c)
    }

    /// 裁剪框是不是整个落在转过的照片里
    static func contains(_ crop: Crop, image: CGSize, degrees: Double, tolerance: CGFloat = 1e-4) -> Bool {
        let ci = toImage(crop.center, degrees: degrees)
        let e = halfExtent(crop.size, degrees: degrees)
        return abs(ci.x) + e.width <= image.width / 2 + tolerance && abs(ci.y) + e.height <= image.height / 2 + tolerance
    }

    /// 把框放进转过的照片里：尽量保持中心和比例。
    /// grow = true：以这个中心取该比例能放下的最大框（没手动拉过大小时，角度变了框跟着变大变小）；
    /// grow = false：放得下就原样，放不下等比缩小。中心太靠边、缩到 minSide 还放不下时才往里挪中心
    static func fitted(_ crop: Crop, image: CGSize, degrees: Double, grow: Bool, minSide: CGFloat = 16) -> Crop {
        guard image.width > 0, image.height > 0, crop.size.width > 0, crop.size.height > 0 else { return crop }
        // 本来就放得下的原样返回（不经过来回换算，一个比特都不变）
        if !grow, contains(crop, image: image, degrees: degrees, tolerance: 0) { return crop }
        let r = crop.aspect
        let (c, s) = trig(abs(degrees))
        // 两条边都不小于 minSide 的最小框（本来就比它小的不放大）
        let minH = min(crop.size.height, max(minSide, minSide / r))
        let minE = halfExtent(CGSize(width: minH * r, height: minH), degrees: degrees)
        var ci = toImage(crop.center, degrees: degrees)
        let mx = max(0, image.width / 2 - minE.width), my = max(0, image.height / 2 - minE.height)
        ci.x = min(max(ci.x, -mx), mx)
        ci.y = min(max(ci.y, -my), my)
        // 半高 b、半宽 r·b：照片宽方向占 b(r·c + s)，高方向占 b(r·s + c)
        let room = min((image.width / 2 - abs(ci.x)) / (r * c + s), (image.height / 2 - abs(ci.y)) / (r * s + c))
        let b = max(0, grow ? room : min(crop.size.height / 2, room))
        return Crop(center: fromImage(ci, degrees: degrees), size: CGSize(width: 2 * r * b, height: 2 * b))
    }

    /// 不拉直也不手动裁时的默认框：居中、原比例、能放下的最大（和 Straighten.cropScale 是同一个结果）
    static func automatic(image: CGSize, degrees: Double) -> Crop {
        fitted(Crop(center: .zero, size: image), image: image, degrees: degrees, grow: true, minSide: 0)
    }

    /// 整个框挪到新的中心，大小不变；碰到照片边就贴着边滑
    static func moved(_ crop: Crop, to center: CGPoint, image: CGSize, degrees: Double) -> Crop {
        let e = halfExtent(crop.size, degrees: degrees)
        var ci = toImage(center, degrees: degrees)
        let mx = max(0, image.width / 2 - e.width), my = max(0, image.height / 2 - e.height)
        ci.x = min(max(ci.x, -mx), mx)
        ci.y = min(max(ci.y, -my), my)
        return Crop(center: fromImage(ci, degrees: degrees), size: crop.size)
    }

    /// 拖手柄：对面的角（或边）不动，被拖的角跟着 point 走，出不了照片。
    /// aspect 非 nil 时保持这个宽高比（拖边时另一个方向以中线为轴一起变）
    static func resized(_ start: Crop, handle: Handle, to point: CGPoint, aspect: CGFloat?,
                        image: CGSize, degrees: Double, minSide: CGFloat) -> Crop {
        let r0 = start.rect
        let d = handle.direction
        let ax = d.dx > 0 ? r0.minX : (d.dx < 0 ? r0.maxX : r0.midX)
        let ay = d.dy > 0 ? r0.minY : (d.dy < 0 ? r0.maxY : r0.midY)
        func make(_ w: CGFloat, _ h: CGFloat) -> Crop {
            let x = d.dx > 0 ? ax : (d.dx < 0 ? ax - w : ax - w / 2)
            let y = d.dy > 0 ? ay : (d.dy < 0 ? ay - h : ay - h / 2)
            return Crop(rect: CGRect(x: x, y: y, width: w, height: h))
        }
        func ok(_ w: CGFloat, _ h: CGFloat) -> Bool { contains(make(w, h), image: image, degrees: degrees) }
        /// 从放得下的 a 往 b 走，返回还放得下的最远处（放得下的范围是凸的，二分就行）
        func farthest(_ a: CGSize, _ b: CGSize) -> CGSize {
            if ok(b.width, b.height) { return b }
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<40 {
                let m = (lo + hi) / 2
                if ok(a.width + (b.width - a.width) * m, a.height + (b.height - a.height) * m) { lo = m } else { hi = m }
            }
            return CGSize(width: a.width + (b.width - a.width) * lo, height: a.height + (b.height - a.height) * lo)
        }

        var w = d.dx == 0 ? r0.width : max(minSide, (point.x - ax) * CGFloat(d.dx))
        let h = d.dy == 0 ? r0.height : max(minSide, (point.y - ay) * CGFloat(d.dy))
        if let aspect, aspect > 0 {
            if d.dx != 0 && d.dy != 0 {
                w = max(w, h * aspect)
            } else if d.dx == 0 {
                w = h * aspect
            }
            w = max(w, minSide * max(1, aspect))
            // 缩在起始框里的同比例框一定放得下，从它往目标大小走
            let inside = min(w, r0.width, r0.height * aspect)
            let size = farthest(CGSize(width: inside, height: inside / aspect), CGSize(width: w, height: w / aspect))
            return make(size.width, size.height)
        }
        // 自由比例：先沿直线走到边，再分别沿宽、高各自能走多远走多远（没拉直时就是各自贴到照片边）
        var size = farthest(CGSize(width: min(w, r0.width), height: min(h, r0.height)), CGSize(width: w, height: h))
        size = farthest(size, CGSize(width: w, height: size.height))
        size = farthest(size, CGSize(width: size.width, height: h))
        return make(size.width, size.height)
    }

    /// 照片顺时针转 turns 个 90°，框跟着照片一起转（框住的还是同一块画面）
    static func turned(_ crop: Crop, clockwise turns: Int) -> Crop {
        var c = crop
        for _ in 0..<(((turns % 4) + 4) % 4) {
            c = Crop(center: CGPoint(x: -c.center.y, y: c.center.x), size: CGSize(width: c.size.height, height: c.size.width))
        }
        return c
    }

    /// 落到整像素上的输出框（左上原点，照片左上角是 0,0）。
    /// 没拉直：宽高各自取整（正好 2000 宽的框不会因为压在半个像素上变成 1999），位置就近取整、夹在照片里。
    /// 拉直过：四边都往里取整，保证不伸出转过的照片；这时框可以伸到没转时的 W×H 外面（转过的照片四个角那里），所以不夹在 0…W 里
    static func pixelRect(_ crop: Crop, image: CGSize, degrees: Double) -> CGRect {
        let r = crop.rect.offsetBy(dx: image.width / 2, dy: image.height / 2)
        let e: CGFloat = 1e-3
        if degrees == 0 {
            let w = max(1, min(image.width, (r.width + e).rounded(.down))), h = max(1, min(image.height, (r.height + e).rounded(.down)))
            return CGRect(x: min(max(0, r.minX.rounded()), image.width - w), y: min(max(0, r.minY.rounded()), image.height - h), width: w, height: h)
        }
        let x0 = (r.minX - e).rounded(.up), y0 = (r.minY - e).rounded(.up)
        let x1 = max(x0 + 1, (r.maxX + e).rounded(.down)), y1 = max(y0 + 1, (r.maxY + e).rounded(.down))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

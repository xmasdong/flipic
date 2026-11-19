import Foundation

/// 照片里的 GPS 是国际通用的 WGS-84，Apple 地图在中国大陆用的是国测局坐标（GCJ-02），
/// 直接拿 WGS-84 去画地图会偏几百米（蛇口邮轮母港的 iPhone 照片实测偏到了 600 米外的邮轮大道上）。
/// 只在画地图、打开「地图」App 时换算；面板上显示的坐标文字照旧是照片里的原值。
/// 香港、澳门、台湾的地图不偏移，不换算
enum ChinaCoordinate {
    /// 给 Apple 地图用的坐标：在中国大陆就换成 GCJ-02，其他地方原样返回
    static func forMap(latitude lat: Double, longitude lon: Double) -> (lat: Double, lon: Double) {
        guard inMainlandChina(latitude: lat, longitude: lon) else { return (lat, lon) }
        return wgs84ToGcj02(latitude: lat, longitude: lon)
    }

    /// 点坐标在「地图」App 里打开的链接（坐标先按上面换算）
    static func mapsURL(latitude lat: Double, longitude lon: Double) -> URL? {
        let c = forMap(latitude: lat, longitude: lon)
        return URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%.6f,%.6f", c.lat, c.lon, c.lat, c.lon))
    }

    // MARK: - 区域判断

    /// 粗框在中国范围内，并且不在香港、澳门、台湾（含金门）的范围里
    static func inMainlandChina(latitude lat: Double, longitude lon: Double) -> Bool {
        guard lon >= 72.004, lon <= 137.8347, lat >= 0.8293, lat <= 55.8271 else { return false }
        if contains(hongKong, lat, lon) { return false }
        if lat >= 22.10, lat <= 22.218, lon >= 113.52, lon <= 113.61 { return false }        // 澳门
        if lat >= 21.8, lat <= 25.4, lon >= 119.3, lon <= 122.1 { return false }              // 台湾本岛、澎湖
        if lat >= 24.38, lat <= 24.53, lon >= 118.2, lon <= 118.5 { return false }            // 金门
        return true
    }

    /// 香港的大致轮廓（纬度, 经度）。北边沿深圳河、深圳湾里的分界走，蛇口（22.47, 113.91）在线外
    private static let hongKong: [(Double, Double)] = [
        (22.565, 114.45), (22.565, 114.22), (22.548, 114.13), (22.535, 114.08),
        (22.517, 114.03), (22.505, 114.00), (22.470, 113.95), (22.430, 113.90),
        (22.360, 113.84), (22.180, 113.80), (22.130, 113.83), (22.130, 114.45),
    ]

    private static func contains(_ poly: [(Double, Double)], _ lat: Double, _ lon: Double) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let (yi, xi) = poly[i], (yj, xj) = poly[j]
            if (yi > lat) != (yj > lat), lon < (xj - xi) * (lat - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: - WGS-84 → GCJ-02（公开的标准算法）

    static func wgs84ToGcj02(latitude lat: Double, longitude lon: Double) -> (lat: Double, lon: Double) {
        let a = 6378245.0, ee = 0.00669342162296594323
        var dLat = transformLat(lon - 105.0, lat - 35.0)
        var dLon = transformLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (lat + dLat, lon + dLon)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        r += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        r += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        r += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return r
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        r += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        r += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        r += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return r
    }
}

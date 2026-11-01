import AppKit

/// 检查新版本：只向官网请求一个 version.json（版本号、下载地址、作废的激活码名单），不发送任何数据。
/// 默认不联网：只有用户点「检查更新…」或在设置里打开「自动检查更新」时才会请求
enum UpdateChecker {
    /// 测试时可以用环境变量 FLIPIC_UPDATE_FEED 指向本地文件
    static let feedURL = ProcessInfo.processInfo.environment["FLIPIC_UPDATE_FEED"].flatMap(URL.init(string:))
        ?? URL(string: "https://flipic.app/version.json")!
    static let fallbackDownload = URL(string: "https://github.com/xmasdong/flipic/releases/latest/download/Flipic.dmg")!

    /// 每次读到 version.json 都交一份给这里（Pro 用它读作废的激活码名单）
    static var onFeed: (([String: Any]) -> Void)?

    struct Release {
        let version: String
        let download: URL
    }

    enum Result {
        case newer(Release)
        case upToDate(String)
        case failed(String)
    }

    static var autoCheck: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCheckUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }

    /// 用户在提示上点了「不再提醒这个版本」的版本号
    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "skippedUpdateVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedUpdateVersion") }
    }

    private static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func check(_ done: @escaping (Result) -> Void) {
        let config = URLSessionConfiguration.ephemeral   // 不存 cookie、不留缓存
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        var request = URLRequest(url: feedURL)
        request.setValue("Flipic/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            let result: Result
            if let error {
                result = .failed(error.localizedDescription)
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["version"] as? String {
                lastCheck = Date()
                DispatchQueue.main.async { onFeed?(json) }
                let download = (json["download"] as? String).flatMap(URL.init(string:)) ?? fallbackDownload
                result = isNewer(version, than: currentVersion)
                    ? .newer(Release(version: version, download: download)) : .upToDate(currentVersion)
            } else {
                result = .failed((response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "-")
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    /// 启动时调用：打开了自动检查且距上次超过一天才去查；有新版本、且用户没跳过这个版本时才回调
    static func checkIfDue(_ found: @escaping (Release) -> Void) {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check { result in
            if case .newer(let r) = result, r.version != skippedVersion { found(r) }
        }
    }

    /// 0.6.10 比 0.6.9 新：按点分开逐段比数字
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

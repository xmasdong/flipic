import AppKit

/// 检查新版本：向官网请求一个 version.json（版本号、下载地址、作废的激活码名单）。
/// 默认每天自动检查一次（设置里可关），也可以点「检查更新…」。请求只带三样东西：
/// 软件版本号（User-Agent）、安装时长所在的三个区间之一（a=0-6 / 7-29 / 30+ 天）、是否已用激活码激活 Pro（p=1 或 0）；
/// 手动检查还会多带 m=1。没有任何标识，不带确切日期和天数，服务器只按区间累加次数、不存 IP。
enum UpdateChecker {
    /// 测试时可以用环境变量 FLIPIC_UPDATE_FEED 指向本地文件
    static let feedURL = ProcessInfo.processInfo.environment["FLIPIC_UPDATE_FEED"].flatMap(URL.init(string:))
        ?? URL(string: "https://flipic.app/version.json")!
    static let fallbackDownload = URL(string: "https://github.com/xmasdong/flipic/releases/latest/download/Flipic.dmg")!

    /// 每次读到 version.json 都交一份给这里，需要里面别的字段的地方自己取
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

    static let autoCheckKey = "autoCheckUpdates"

    /// 没设置过就是开；设置过（开或关）就按用户的选择
    static func autoCheckEnabled(_ d: UserDefaults = .standard) -> Bool {
        (d.object(forKey: autoCheckKey) as? Bool) ?? true
    }

    static var autoCheck: Bool {
        get { autoCheckEnabled() }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    // MARK: - 安装时长（只发区间，不发日期）

    static let firstLaunchKey = "firstLaunchDate"

    /// 第一次用的日期。没记过就记下：升级上来的用户取已有证据里最早的（Pro 试用开始、上次检查更新），都没有才是现在
    @discardableResult
    static func ensureInstallDate(_ d: UserDefaults = .standard, now: Date = Date()) -> Date {
        if let saved = d.object(forKey: firstLaunchKey) as? Date { return saved }
        let evidence = [d.object(forKey: "proTrialStart") as? Date, d.object(forKey: "lastUpdateCheck") as? Date]
            .compactMap { $0 }.filter { $0 <= now }
        let first = evidence.min() ?? now
        d.set(first, forKey: firstLaunchKey)
        return first
    }

    /// 装了多久，落进 0-6 / 7-29 / 30+ 天三个区间之一；时钟被往回拨（负数）算 0-6
    static func ageBucket(installed: Date, now: Date) -> String {
        let days = Int((now.timeIntervalSince(installed) / 86400).rounded(.down))
        return days >= 30 ? "30+" : days >= 7 ? "7-29" : "0-6"
    }

    /// 是否已用激活码激活 Pro；试用中、试用结束、没有 Pro 的构建都是 false
    static var proActivated: Bool {
        #if FLIPIC_PRO
        return License.info != nil
        #else
        return false
        #endif
    }

    /// 给 version.json 加上 a、p（手动检查再加 m=1）。自定义地址原有的参数保留
    static func requestURL(base: URL, bucket: String, pro: Bool, manual: Bool) -> URL {
        // 本地文件（测试用的 FLIPIC_UPDATE_FEED）不能带参数
        guard base.scheme == "https" || base.scheme == "http",
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        // 用百分号编码的形式拼：区间里的「+」必须写成 %2B，否则服务器按表单规则会读成空格
        var items = (c.percentEncodedQueryItems ?? []).filter { !["a", "p", "m"].contains($0.name) }
        items.append(URLQueryItem(name: "a", value: bucket.replacingOccurrences(of: "+", with: "%2B")))
        items.append(URLQueryItem(name: "p", value: pro ? "1" : "0"))
        if manual { items.append(URLQueryItem(name: "m", value: "1")) }
        c.percentEncodedQueryItems = items
        return c.url ?? base
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

    /// manual：用户自己点「检查更新…」发起的；每天自动查的传 false
    static func check(manual: Bool = true, _ done: @escaping (Result) -> Void) {
        let config = URLSessionConfiguration.ephemeral   // 不存 cookie、不留缓存
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let bucket = ageBucket(installed: ensureInstallDate(), now: Date())
        var request = URLRequest(url: requestURL(base: feedURL, bucket: bucket, pro: proActivated, manual: manual))
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
        ensureInstallDate()
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(manual: false) { result in
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

import AppKit

// App Store 版在沙盒里读不了 ~/Library/Logs/DiagnosticReports，这个功能整个不编进去

/// 上次异常退出的崩溃报告：下次启动时问一次，用户点「发送」才发，什么都不会自动发出。
/// 发出去的是从系统 .ips 报告里提炼并脱敏的一段文字（崩在哪、版本、机型、崩溃线程的调用栈），
/// 不含照片、文件名、用户名、其他线程，也不是原始文件。
/// 所有输入（报告文件夹、存储、「现在」、发送函数）都能注入，自测不碰真实文件夹、偏好设置和网络
enum CrashReporter {
    // MARK: - 常量与设置

    static let enabledKey = "crashReportAsk"
    static let handledKey = "crashReportLastHandled"
    static let urlEnvKey = "FLIPIC_CRASH_URL"
    static let defaultEndpoint = "https://pay.flipic.app/crash"
    static let maxAge: TimeInterval = 7 * 86400
    static let maxReportChars = 60_000
    static let maxFrames = 60
    static let maxNote = 500
    static let maxSignature = 300
    static let truncationMarker = "\n[truncated]"

    /// 测试时用环境变量 FLIPIC_CRASH_URL 指向本地服务器
    /// 返回的是地址字符串，发请求时才变成 URL。（-Osize 下这里返回 URL 时，调用方拿到过坏掉的对象，自测一跑就崩）
    static func endpoint(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let s = env[urlEnvKey], !s.isEmpty { return s }
        return defaultEndpoint
    }

    /// 设置里的开关（默认开）
    static var askEnabled: Bool {
        get { enabled(in: UserDefaults.standard, key: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func enabled(in store: CrashStore, key: String = enabledKey) -> Bool {
        (store.object(forKey: key) as? Bool) ?? true
    }

    /// 不该问的场合：自测环境变量、任何 --xxx 启动参数（各种自测、截图模式）
    static func disabledByEnvironment(env: [String: String], args: [String]) -> Bool {
        if env["FLIPIC_QUIET_TEST"] != nil { return true }
        return args.dropFirst().contains { $0.hasPrefix("--") }
    }

    // MARK: - 注入的环境

    struct Context {
        var reportsDir: URL
        var store: CrashStore
        var now: Date
        var bundleID: String?
        var home: String
        var enabledKey = CrashReporter.enabledKey
        var handledKey = CrashReporter.handledKey

        static var live: Context {
            Context(reportsDir: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports"),
                    store: UserDefaults.standard, now: Date(), bundleID: Bundle.main.bundleIdentifier, home: NSHomeDirectory())
        }
    }

    /// 找到的待处理报告
    struct Pending {
        let file: URL
        let date: Date
        let condensed: Condensed
        /// 回答之后记为「已处理」的时间：这次看到的所有新报告里最晚的那个
        let handledMark: Date
    }

    /// 提炼后的内容
    struct Condensed {
        var text: String
        var signature: String
        var app: String
        var build: String
        var os: String
        var model: String
        var arch: String
    }

    /// 发送函数：给请求，回调里说成没成（注入后自测不联网）
    typealias Sender = (URLRequest, @escaping (Bool) -> Void) -> Void

    // MARK: - 找报告（启动时只列一次目录）

    /// 文件名 Flipic-YYYY-MM-DD-HHMMSS.ips 里的本地时间
    static func date(fromName name: String) -> Date? {
        guard name.hasPrefix("Flipic-"), name.hasSuffix(".ips") else { return nil }
        let core = name.dropFirst("Flipic-".count).dropLast(".ips".count)
        let p = core.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 4, p[3].count == 6, let y = Int(p[0]), let mo = Int(p[1]), let d = Int(p[2]), let t = Int(p[3]) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        c.hour = t / 10000; c.minute = (t / 100) % 100; c.second = t % 100
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /// 只有文件名比上次处理的时间新才会去读文件。
    /// 有新报告但都不是本 App 的：悄悄记为已处理（不再重复看），返回 nil
    static func findPending(_ c: Context) -> Pending? {
        guard enabled(in: c.store, key: c.enabledKey), let bundleID = c.bundleID else { return nil }
        let last = (c.store.object(forKey: c.handledKey) as? Double) ?? 0
        let oldest = c.now.addingTimeInterval(-maxAge)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: c.reportsDir.path)) ?? []
        var cands: [(name: String, date: Date)] = []
        for n in names {
            guard let d = date(fromName: n), d.timeIntervalSince1970 > last, d >= oldest, d <= c.now.addingTimeInterval(3600) else { continue }
            cands.append((n, d))
        }
        guard let newest = cands.map({ $0.date }).max() else { return nil }
        for cand in cands.sorted(by: { $0.date > $1.date }) {
            let url = c.reportsDir.appendingPathComponent(cand.name)
            guard let data = try? Data(contentsOf: url), headerBundleID(data) == bundleID,
                  let cond = condense(data: data, home: c.home) else { continue }
            return Pending(file: url, date: cand.date, condensed: cond, handledMark: newest)
        }
        c.store.set(newest.timeIntervalSince1970, forKey: c.handledKey)
        return nil
    }

    static func markHandled(_ p: Pending, in c: Context) {
        c.store.set(p.handledMark.timeIntervalSince1970, forKey: c.handledKey)
    }

    private static func headerBundleID(_ data: Data) -> String? {
        let nl = data.firstIndex(of: 0x0A) ?? data.endIndex
        guard let o = try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl]) as? [String: Any] else { return nil }
        return o["bundleID"] as? String
    }

    // MARK: - 脱敏

    private static let usersRegex = try! NSRegularExpression(pattern: #"/Users/[^/\s"'<>()\[\]{},;:|*\\]+"#)
    private static let volumesRegex = try! NSRegularExpression(pattern: #"/Volumes/[^\n"'<>]*"#)
    private static let homePathRegex = try! NSRegularExpression(pattern: #"~(?:/[^/\s"'<>()\[\]{},;:|*\\]+)+"#)
    private static let absPathRegex = try! NSRegularExpression(
        pattern: #"(?<![\w~.\-])/(?:[^/\s"'<>()\[\]{},;|*\\]+/)*([^/\s"'<>()\[\]{},;|*\\]+)"#)

    /// 用户的家目录和任何 /Users/<名字> 换成 ~；其他绝对路径只留最后一段
    static func sanitize(_ s: String, home: String) -> String {
        var out = s
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        out = usersRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
        // 外置盘名字里常有空格：整段 /Volumes/... 只留最后一段
        let ns = out as NSString
        var rebuilt = ""
        var pos = 0
        for m in volumesRegex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            rebuilt += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            let last = ns.substring(with: m.range).split(separator: "/").last.map(String.init) ?? ""
            rebuilt += last
            pos = m.range.location + m.range.length
        }
        rebuilt += ns.substring(from: pos)
        out = rebuilt
        out = absPathRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        // 家目录下面的路径（出错信息里可能带着照片的位置和名字）：文件夹和文件名都不要，只留扩展名，够判断是哪种格式
        let hs = out as NSString
        var result = ""
        var at = 0
        for m in homePathRegex.matches(in: out, range: NSRange(location: 0, length: hs.length)) {
            result += hs.substring(with: NSRange(location: at, length: m.range.location - at))
            let ext = (hs.substring(with: m.range) as NSString).pathExtension
            let plain = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            result += plain ? "~/[file].\(ext.lowercased())" : "~/[path]"
            at = m.range.location + m.range.length
        }
        result += hs.substring(from: at)
        return result
    }

    // MARK: - 提炼

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    /// 一帧写成一行；image 名只取名字
    private static func frameLine(_ i: Int, _ f: [String: Any], images: [[String: Any]], home: String) -> String {
        let idx = int(f["imageIndex"])
        var image = "?"
        if let idx, idx >= 0, idx < images.count {
            image = str(images[idx]["name"]) ?? str(images[idx]["path"]).map { ($0 as NSString).lastPathComponent } ?? "?"
        }
        var line = String(format: "%3d  ", i) + sanitize(image, home: home)
        if let off = int(f["imageOffset"]) { line += "  +0x" + String(off, radix: 16) }
        if let sym = str(f["symbol"]) {
            line += "  " + sanitize(sym, home: home)
            if let loc = int(f["symbolLocation"]) { line += " + \(loc)" }
        }
        if let file = str(f["sourceFile"]) {
            line += "  (" + (file as NSString).lastPathComponent   // 源文件只留文件名（是代码的文件，不是用户的）
            if let n = int(f["sourceLine"]) { line += ":\(n)" }
            line += ")"
        }
        return line
    }

    private static func mapFrames(_ frames: [[String: Any]], images: [[String: Any]], home: String) -> [String] {
        frames.prefix(maxFrames).enumerated().map { frameLine($0.offset, $0.element, images: images, home: home) }
    }

    /// 签名里一帧的写法：有符号用符号，没有用偏移
    private static func sigLabel(_ f: [String: Any], home: String) -> String {
        if let sym = str(f["symbol"]) { return sanitize(sym, home: home) }
        if let off = int(f["imageOffset"]) { return "+0x" + String(off, radix: 16) }
        return "?"
    }

    /// 从系统的 .ips（第一行是 JSON 头，其余是 JSON 正文）提炼；读不懂返回 nil
    static func condense(data: Data, home: String) -> Condensed? {
        guard let nl = data.firstIndex(of: 0x0A),
              let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl])) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...])) as? [String: Any] else { return nil }
        func S(_ v: Any?) -> String { sanitize(v as? String ?? "", home: home) }

        let bundle = body["bundleInfo"] as? [String: Any] ?? [:]
        let app = str(bundle["CFBundleShortVersionString"]) ?? str(header["app_version"]) ?? ""
        let build = str(bundle["CFBundleVersion"]) ?? str(header["build_version"]) ?? ""
        let osInfo = body["osVersion"] as? [String: Any] ?? [:]
        let osTrain = str(osInfo["train"]) ?? str(header["os_version"]) ?? ""
        let osNumber = osTrain.replacingOccurrences(of: "macOS ", with: "").split(separator: " ").first.map(String.init) ?? ""
        let osBuild = str(osInfo["build"]) ?? ""
        let model = str(body["modelCode"]) ?? ""
        let cpu = str(body["cpuType"]) ?? ""
        let images = (body["usedImages"] as? [[String: Any]]) ?? []

        // 主程序在映像表里的位置：路径等于进程路径，否则名字等于进程名，否则第 0 个
        let procPath = str(body["procPath"]), procName = str(body["procName"])
        let mainIdx = images.firstIndex { procPath != nil && str($0["path"]) == procPath }
            ?? images.firstIndex { procName != nil && str($0["name"]) == procName } ?? 0
        let mainImage = images.indices.contains(mainIdx) ? images[mainIdx] : [:]
        let arch = str(mainImage["arch"]) ?? (cpu.uppercased().hasPrefix("ARM") ? "arm64" : cpu.uppercased().hasPrefix("X86") ? "x86_64" : cpu.lowercased())

        // 崩溃时间只留日期和钟点
        let capture = str(body["captureTime"]) ?? str(header["timestamp"]) ?? ""
        let parts = capture.split(separator: " ").map(String.init)
        var when = "unknown"
        if parts.count >= 2 {
            when = parts[0] + " " + String(parts[1].prefix(2)) + "h"
            if let z = parts.last, parts.count >= 3, z.hasPrefix("+") || z.hasPrefix("-") { when += " (\(z))" }
        }
        var uptimeLine: String?
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        if let l = str(body["procLaunch"]).flatMap(fmt.date(from:)), let c = fmt.date(from: capture), c >= l {
            uptimeLine = "Process uptime: \(Int(c.timeIntervalSince(l))) s"
        }

        var lines: [String] = []
        lines.append("Flipic crash report (condensed)")
        lines.append("App: \(S(body["procName"] ?? "Flipic")) \(app) (\(build))")
        lines.append("macOS: \(osNumber)" + (osBuild.isEmpty ? "" : " (\(osBuild))"))
        lines.append("Mac model: \(model)")
        lines.append("CPU: \(cpu) (\(arch))")
        lines.append("Crash time: \(when)")
        if let uptimeLine { lines.append(uptimeLine) }
        if let r = str(body["procRole"]) { lines.append("Process role: \(S(r))") }
        if body["translated"] as? Bool == true { lines.append("Translated: yes (Rosetta)") }

        lines.append("")
        let exc = body["exception"] as? [String: Any] ?? [:]
        let excType = str(exc["type"]) ?? ""
        lines.append("Exception type: \(S(excType))" + (str(exc["signal"]).map { " (\(S($0)))" } ?? ""))
        if let c = str(exc["codes"]) { lines.append("Exception codes: \(S(c))") }
        if let s = str(exc["subtype"]) { lines.append("Exception subtype: \(S(s))") }
        if let t = body["termination"] as? [String: Any] {
            var bits: [String] = []
            if let v = str(t["namespace"]) { bits.append("namespace \(S(v))") }
            if let v = str(t["indicator"]) { bits.append("indicator \(S(v))") }
            if let v = str(t["code"]) { bits.append("code \(S(v))") }
            if let v = str(t["reason"]) { bits.append("reason \(S(v))") }
            if !bits.isEmpty { lines.append("Termination: " + bits.joined(separator: ", ")) }
        }
        // 应用自己写的信息（abort 消息、崩溃信息）
        if let asi = body["asi"] as? [String: Any], !asi.isEmpty {
            lines.append("Application specific information:")
            for key in asi.keys.sorted() {
                let vals: [String] = (asi[key] as? [Any])?.compactMap { str($0) } ?? [str(asi[key])].compactMap { $0 }
                for v in vals { lines.append("  " + S(String(v.prefix(2000))).replacingOccurrences(of: "\n", with: "\n  ")) }
            }
        }

        // 崩溃的那条线程；其他线程不要
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        var crashed: [String: Any]?
        if let fi = int(body["faultingThread"]), threads.indices.contains(fi) { crashed = threads[fi] }
        else { crashed = threads.first { $0["triggered"] as? Bool == true } }
        let crashedFrames = (crashed?["frames"] as? [[String: Any]]) ?? []
        lines.append("")
        lines.append("Crashed thread backtrace (\(min(crashedFrames.count, maxFrames)) of \(crashedFrames.count) frames):")
        lines += mapFrames(crashedFrames, images: images, home: home)

        let lastExc = (body["lastExceptionBacktrace"] as? [[String: Any]]) ?? []
        if !lastExc.isEmpty {
            lines.append("")
            lines.append("Last exception backtrace (\(min(lastExc.count, maxFrames)) of \(lastExc.count) frames):")
            lines += mapFrames(lastExc, images: images, home: home)
        }

        // 主程序的 UUID（以后还原符号要用）；其他映像只写名字
        lines.append("")
        let mainName = S(mainImage["name"] ?? procName ?? "")
        lines.append("Main binary: \(mainName)  UUID \(str(mainImage["uuid"]) ?? "?")  arch \(arch)")
        var others: [String] = []
        for (i, im) in images.enumerated() where i != mainIdx {
            if let n = str(im["name"]) ?? str(im["path"]).map({ ($0 as NSString).lastPathComponent }) { others.append(S(n)) }
        }
        lines.append("Other images (\(others.count), names only): " + others.joined(separator: ", "))

        // 一行签名：异常类型 + 前三帧属于本 App 的帧
        func appFrames(_ fs: [[String: Any]]) -> [[String: Any]] { fs.filter { int($0["imageIndex"]) == mainIdx } }
        var own = appFrames(crashedFrames)
        if own.isEmpty { own = appFrames(lastExc) }
        let labels = own.prefix(3).map { sigLabel($0, home: home) }
        var sig = excType.isEmpty ? "unknown" : S(excType)
        if !labels.isEmpty { sig += ": " + labels.joined(separator: " > ") }
        if sig.count > maxSignature { sig = String(sig.prefix(maxSignature)) }
        lines.append("")
        lines.append("Signature: \(sig)")

        var text = lines.joined(separator: "\n")
        if text.count > maxReportChars { text = String(text.prefix(maxReportChars - truncationMarker.count)) + truncationMarker }
        return Condensed(text: text, signature: sig, app: app, build: build, os: osNumber, model: model, arch: arch)
    }

    // MARK: - 发送

    /// 请求体：固定这十个字段。备注只做家目录脱敏、限 500 字
    static func requestBody(_ c: Condensed, note: String, lang: String, variant: String, home: String) -> Data? {
        let n = String(sanitizeNote(note, home: home).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNote))
        let body: [String: String] = [
            "app": c.app, "build": c.build, "os": c.os, "model": c.model, "arch": c.arch,
            "lang": lang, "variant": variant, "signature": c.signature, "note": n, "report": c.text,
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func sanitizeNote(_ s: String, home: String) -> String {
        var out = s
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        return usersRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
    }

    static func makeRequest(body: Data, address: String) -> URLRequest? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Flipic/\(FeedbackWindowController.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    /// 真正联网的发送：只有 HTTP 200 且回了 {"ok":true,...} 才算成功
    static let liveSender: Sender = { request, done in
        let config = URLSessionConfiguration.ephemeral   // 不存 cookie、不留缓存
        config.timeoutIntervalForRequest = 20
        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = error == nil && http?.statusCode == 200 && json?["ok"] as? Bool == true
            if !ok { NSLog("CRASHREPORT send failed http=%d error=%@", http?.statusCode ?? 0, error.map { "\($0)" } ?? "-") }
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    // MARK: - 流程

    struct Answer {
        var send: Bool
        var note: String
        var dontAskAgain: Bool
    }

    /// 完整流程（不含界面）：找报告 → 问 → 记为已处理 → 要发就发。返回找到的报告，没有就是 nil。
    /// 无论回答什么、发没发成，这批报告都记为已处理，不会重试
    @discardableResult
    static func process(_ c: Context, lang: String, variant: String, url: String,
                        ask: (Pending) -> Answer, sender: Sender, completion: ((Bool) -> Void)? = nil) -> Pending? {
        guard let p = findPending(c) else { return nil }
        let a = ask(p)
        markHandled(p, in: c)
        if a.dontAskAgain { c.store.set(false, forKey: c.enabledKey) }
        guard a.send, let body = requestBody(p.condensed, note: a.note, lang: lang, variant: variant, home: c.home),
              let request = makeRequest(body: body, address: url) else {
            completion?(false)
            return p
        }
        sender(request) { ok in completion?(ok) }
        return p
    }

    /// 启动时调用（必须在打开任何照片之前）：没有待处理报告时只是列一次目录，没有任何延迟
    static func checkOnLaunch() {
        launchCheck(env: ProcessInfo.processInfo.environment, args: CommandLine.arguments, context: .live,
                    ask: { CrashPrompt.ask($0) }, sender: liveSender) { ok in
            if ok {
                (NSApp.delegate as? AppDelegate)?.activeViewer?.flash(L10n.t("crash.sent", "崩溃报告已发送，谢谢"))
            }
        }
    }

    /// checkOnLaunch 的本体，参数都能换，自测走的就是这一段
    @discardableResult
    static func launchCheck(env: [String: String], args: [String], context: Context,
                            ask: (Pending) -> Answer, sender: Sender, completion: ((Bool) -> Void)? = nil) -> Pending? {
        guard !disabledByEnvironment(env: env, args: args) else { return nil }
        return process(context, lang: Bundle.main.preferredLocalizations.first ?? "", variant: FeedbackWindowController.variant,
                       url: endpoint(env: env), ask: ask, sender: sender, completion: completion)
    }
}

/// 简单的内存存储，自测用
final class MemoryCrashStore: CrashStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// UserDefaults 和自测用的内存存储共用
protocol CrashStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: CrashStore {}

// MARK: - 询问框

enum CrashPrompt {
    private final class Limiter: NSObject, NSTextFieldDelegate {
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField, f.stringValue.count > CrashReporter.maxNote else { return }
            f.stringValue = String(f.stringValue.prefix(CrashReporter.maxNote))
        }
    }

    private final class Viewer: NSObject {
        let text: String
        weak var host: NSWindow?
        var panel: NSWindow?
        init(text: String) { self.text = text }

        @objc func show(_ sender: Any?) {
            guard let host else { return }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 640, height: 396))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            tv.string = text
            scroll.documentView = tv
            let close = NSButton(title: L10n.t("crash.close", "关闭"), target: self, action: #selector(dismiss(_:)))
            close.keyEquivalent = "\r"
            close.frame = NSRect(x: 640 - 96, y: 8, width: 84, height: 28)
            close.autoresizingMask = [.minXMargin]
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = L10n.t("crash.viewTitle", "将要发送的内容")
            panel.contentView?.addSubview(scroll)
            panel.contentView?.addSubview(close)
            self.panel = panel
            host.beginSheet(panel)
        }

        @objc func dismiss(_ sender: Any?) {
            guard let panel, let host else { return }
            host.endSheet(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    static func ask(_ p: CrashReporter.Pending) -> CrashReporter.Answer {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.t("crash.title", "Flipic 上次意外退出了。把崩溃报告发给开发者吗？")
        alert.informativeText = L10n.t("crash.info", "报告里有崩在哪里、软件和系统的版本、Mac 的型号，不含照片、文件名和路径。点「发送」才会发出。")
        alert.addButton(withTitle: L10n.t("crash.send", "发送"))
        alert.addButton(withTitle: L10n.t("crash.dontSend", "不发送"))

        let limiter = Limiter()
        let note = NSTextField()
        note.placeholderString = L10n.t("crash.note", "你当时在做什么？（可不填）")
        note.usesSingleLineMode = true
        note.cell?.isScrollable = true
        note.delegate = limiter

        let dont = NSButton(checkboxWithTitle: L10n.t("crash.dontAsk", "不再询问"), target: nil, action: nil)
        let viewer = Viewer(text: p.condensed.text)
        let view = NSButton(title: L10n.t("crash.view", "查看报告内容…"), target: viewer, action: #selector(Viewer.show(_:)))
        view.bezelStyle = .rounded
        view.controlSize = .small

        let stack = NSStackView(views: [note, dont, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 360).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 90)
        alert.accessoryView = stack
        viewer.host = alert.window

        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        _ = limiter
        return CrashReporter.Answer(send: r == .alertFirstButtonReturn, note: note.stringValue, dontAskAgain: dont.state == .on)
    }
}

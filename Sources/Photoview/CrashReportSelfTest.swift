import Foundation


/// `Flipic --crashreporttest <工作文件夹>`：崩溃报告提炼、脱敏、挑选和「已处理」状态的自测。
/// 不碰真实的 DiagnosticReports、偏好设置和网络：报告文件夹、存储、现在、发送函数都是注入的，.ips 假文件在工作文件夹里现造。
/// 环境变量 CRASHTEST_REAL=<路径> 时再用真报告跑一次脱敏烟测，只打印通过与否和长度。最后一行 CRASHTEST summary
enum CrashReportSelfTest {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("CRASHTEST \(ok ? "ok  " : "FAIL") \(what)")
    }

    static func finish() -> Never {
        print("CRASHTEST summary checks=\(checks) failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    static func fail(_ what: String) -> Never {
        check(false, what)
        finish()
    }

    // MARK: - 假报告

    static let fakeHome = "/Users/janedoe"
    static let mainUUID = "AAAAAAAA-1111-2222-3333-444444444444"
    static let secretKey = "CRK-SECRET-1234-ABCD"
    static let bootUUID = "BOOT-SESSION-UUID-999"
    static let wakeUUID = "SLEEPWAKE-UUID-777"
    static let abortMsg = "Fatal error: Unable to read /Users/janedoe/Pictures/holiday/IMG_0001.jpg"

    static func frame(_ image: Int, off: Int, symbol: String? = nil, loc: Int? = nil, file: String? = nil, line: Int? = nil) -> [String: Any] {
        var f: [String: Any] = ["imageIndex": image, "imageOffset": off]
        if let symbol { f["symbol"] = symbol }
        if let loc { f["symbolLocation"] = loc }
        if let file { f["sourceFile"] = file }
        if let line { f["sourceLine"] = line }
        return f
    }

    /// .ips：第一行 JSON 头，后面 JSON 正文
    static func makeIPS(bundleID: String, frames: [[String: Any]]? = nil, extraImages: Int = 0, asi: [String: Any]? = nil) -> Data {
        var images: [[String: Any]] = [
            ["name": "Flipic", "path": fakeHome + "/Applications/Flipic.app/Contents/MacOS/Flipic", "uuid": mainUUID, "arch": "arm64", "base": 4294967296, "size": 1000000],
            ["name": "libsystem_kernel.dylib", "path": "/usr/lib/system/libsystem_kernel.dylib", "uuid": "BBBBBBBB-0000-0000-0000-000000000001", "arch": "arm64e"],
            ["name": "SwiftUI", "path": "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI", "uuid": "BBBBBBBB-0000-0000-0000-000000000002", "arch": "arm64e"],
        ]
        for i in 0..<extraImages { images.append(["name": "ExtraImageNumber\(i)xxxxxxxxxxxxxxxxxx", "path": "/usr/lib/extra\(i).dylib", "uuid": "U\(i)"]) }
        let crashed: [[String: Any]] = frames ?? [
            frame(1, off: 9000, symbol: "__pthread_kill", loc: 8),
            frame(0, off: 1000, symbol: "crashingFunctionOne", loc: 40, file: fakeHome + "/src/Flipic/Foo.swift", line: 12),
            frame(0, off: 0x2b50),
            frame(2, off: 77, symbol: "SwiftUIThing", loc: 4),
            frame(0, off: 3000, symbol: "crashingFunctionThree", loc: 6),
            frame(0, off: 4000, symbol: "crashingFunctionFour", loc: 6),
        ]
        let body: [String: Any] = [
            "procName": "Flipic", "procPath": fakeHome + "/Applications/Flipic.app/Contents/MacOS/Flipic",
            "procRole": "Foreground", "translated": false,
            "captureTime": "2026-11-17 10:12:31.4000 +0800", "procLaunch": "2026-11-17 10:12:01.1000 +0800",
            "uptime": 5100, "modelCode": "Mac15,6", "cpuType": "ARM-64",
            "osVersion": ["train": "macOS 26.3.1", "build": "25D771280a", "releaseType": "User"],
            "bundleInfo": ["CFBundleShortVersionString": "1.0.46", "CFBundleVersion": "86", "CFBundleIdentifier": bundleID],
            "crashReporterKey": secretKey, "bootSessionUUID": bootUUID, "sleepWakeUUID": wakeUUID, "userID": 501,
            "deviceName": "Jane's MacBook Pro", "hostName": "janes-macbook.local",
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "codes": "0x0000000000000001, 0x00000001a58dad20", "subtype": "EXC_ARM_BREAKPOINT"],
            "termination": ["namespace": "SIGNAL", "indicator": "Trace/BPT trap: 5", "code": 5, "byProc": "exc handler", "byPid": 42],
            "asi": asi ?? ["libswiftCore.dylib": [abortMsg, "see /private/var/folders/ab/cd/T/tmp123/leak.dat"]],
            "faultingThread": 0,
            "threads": [
                ["triggered": true, "id": 1, "queue": "com.apple.main-thread", "frames": crashed],
                ["id": 2, "frames": [frame(0, off: 5000, symbol: "otherThreadSecretSymbol", loc: 1)]],
            ],
            "lastExceptionBacktrace": [frame(0, off: 6000, symbol: "lastExcFunc", loc: 2), frame(2, off: 88, symbol: "SwiftUILast", loc: 3)],
            "usedImages": images,
        ]
        let header: [String: Any] = ["app_name": "Flipic", "timestamp": "2026-11-17 10:12:31.00 +0800", "app_version": "1.0.46",
                                     "build_version": "86", "bundleID": bundleID, "bug_type": "309", "os_version": "macOS 26.3.1 (25D771280a)"]
        var out = (try? JSONSerialization.data(withJSONObject: header)) ?? Data()
        out.append(0x0A)
        out.append((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        return out
    }

    static func nameFor(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Flipic-" + f.string(from: d) + ".ips"
    }

    static func makeDir(_ url: URL) -> URL {
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil else {
            fail("cannot create \(url.lastPathComponent)")
        }
        return url
    }

    static func write(_ data: Data, as name: String, in dir: URL) {
        if (try? data.write(to: dir.appendingPathComponent(name))) == nil { fail("cannot write fixture \(name)") }
    }

    // MARK: - 检查

    static func run(outDir: String?) -> Never {
        guard let outDir, !outDir.isEmpty else { fail("missing <outDir> argument: usage --crashreporttest <outDir>") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outDir, isDirectory: &isDir), isDir.boolValue else { fail("outDir does not exist: \(outDir)") }
        let root = makeDir(URL(fileURLWithPath: outDir).appendingPathComponent("crashtest-fixtures"))
        let bid = "com.example.flipic.test"
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        func ctx(_ dir: URL, store: CrashStore = MemoryCrashStore(), home: String = fakeHome) -> CrashReporter.Context {
            CrashReporter.Context(reportsDir: dir, store: store, now: now, bundleID: bid, home: home)
        }

        // 文件名与小工具
        check(CrashReporter.date(fromName: "Flipic-2026-11-17-101231.ips") != nil, "file name parses")
        check(CrashReporter.date(fromName: "Other-2026-11-17-101231.ips") == nil && CrashReporter.date(fromName: "Flipic-2026-11-17.ips") == nil, "other file names ignored")
        check(CrashReporter.disabledByEnvironment(env: ["FLIPIC_QUIET_TEST": "1"], args: ["Flipic"]), "disabled under FLIPIC_QUIET_TEST")
        check(CrashReporter.disabledByEnvironment(env: [:], args: ["Flipic", "--cardmarktest", "x"]), "disabled with a --...test argument")
        check(!CrashReporter.disabledByEnvironment(env: [:], args: ["Flipic", "/tmp/a.jpg"]), "enabled for a normal launch with a file argument")
        check(CrashReporter.endpoint(env: [:]) == "https://pay.flipic.app/crash", "default endpoint")
        check(CrashReporter.endpoint(env: ["FLIPIC_CRASH_URL": "http://127.0.0.1:9/crash"]) == "http://127.0.0.1:9/crash", "endpoint override")

        // 脱敏
        func san(_ s: String) -> String { CrashReporter.sanitize(s, home: fakeHome) }
        check(san("open /Users/janedoe/a/b.jpg") == "open ~/[file].jpg", "sanitize: home -> ~")
        check(CrashReporter.sanitize("x /Users/other/a.jpg", home: "/Users/me") == "x ~/[file].jpg", "sanitize: any /Users/<name> -> ~")
        check(san("/usr/lib/system/libfoo.dylib") == "libfoo.dylib", "sanitize: other absolute path -> last component")
        check(san("/Volumes/NO NAME/DCIM/IMG_1.CR3 failed") == "IMG_1.CR3 failed" || san("/Volumes/NO NAME/DCIM/IMG_1.CR3 failed").hasPrefix("IMG_1.CR3"), "sanitize: /Volumes path with a space")
        check(!san("/Volumes/My Card/DCIM/100/IMG_1.CR3").contains("My Card"), "sanitize: volume name not leaked")
        check(san("a / b and ~/Pictures/x") == "a / b and ~/[path]", "sanitize: plain slash untouched, ~ path reduced")
        check(san("file:///private/var/x/y.jpg") == "file://y.jpg", "sanitize: file URL")

        // 夹具
        let dirA = makeDir(root.appendingPathComponent("reports-main"))
        let good = nameFor(ago(2 * 3600)), olderGood = nameFor(ago(5 * 3600)), wrongNewest = nameFor(ago(1800))
        let corrupt = nameFor(ago(3600)), tooOld = nameFor(ago(10 * 86400))
        write(makeIPS(bundleID: bid), as: good, in: dirA)
        write(makeIPS(bundleID: bid, frames: [frame(0, off: 1, symbol: "olderReportFunction")]), as: olderGood, in: dirA)
        write(makeIPS(bundleID: "com.example.other"), as: wrongNewest, in: dirA)
        write(Data("{\"bundleID\":\"\(bid)\"}\nnot json".utf8), as: corrupt, in: dirA)
        write(makeIPS(bundleID: bid), as: tooOld, in: dirA)
        write(makeIPS(bundleID: bid), as: "Other-" + String(good.dropFirst(7)), in: dirA)

        // 选最新匹配的；第一次运行算近 7 天
        let store1 = MemoryCrashStore()
        guard let p = CrashReporter.findPending(ctx(dirA, store: store1)) else { fail("no report found in main fixture dir") }
        check(p.file.lastPathComponent == good, "picks the newest matching report (skips wrong bundle id, unparsable newer file, older matching)")
        check(abs(p.handledMark.timeIntervalSince(ago(1800))) < 1, "handled mark = newest report seen (even a wrong-bundle one)")
        let t = p.condensed.text
        // 看得见的样例（只是假夹具的输出）
        try? t.write(to: root.appendingPathComponent("sample-output.txt"), atomically: true, encoding: .utf8)
        check(t.contains("EXC_BREAKPOINT") && t.contains("SIGTRAP") && t.contains("0x00000001a58dad20") && t.contains("EXC_ARM_BREAKPOINT"), "output has exception type, signal, codes, subtype")
        check(t.contains("Trace/BPT trap: 5") && t.contains("indicator"), "output has termination info")
        check(t.contains("crashingFunctionOne + 40") && t.contains("crashingFunctionThree") && t.contains("+0x2b50") && t.contains("Foo.swift:12"), "output has crashed-thread frames (symbol, offset, source line)")
        check(t.contains("lastExcFunc"), "output has lastExceptionBacktrace")
        check(t.contains(mainUUID) && t.contains("Main binary: Flipic"), "output has main binary name and UUID")
        check(t.contains("libsystem_kernel.dylib") && t.contains("SwiftUI") && !t.contains("/System/Library"), "other images by name only")
        check(t.contains("Fatal error: Unable to read ~/[file].jpg") && !t.contains("IMG_0001") && !t.contains("holiday") && t.contains("leak.dat") && !t.contains("/private"), "abort message sanitized")
        check(t.contains("2026-11-17 10h (+0800)") && !t.contains("10:12"), "crash time is date + hour only")
        check(t.contains("Process uptime: 30 s"), "process uptime")
        check(t.contains("Mac15,6") && t.contains("1.0.46 (86)") && t.contains("26.3.1"), "version, build, macOS, model")
        check(!t.contains("janedoe") && !t.contains("/Users/"), "no user name, no /Users/")
        check(!t.contains(secretKey) && !t.contains(bootUUID) && !t.contains(wakeUUID) && !t.contains("MacBook") && !t.contains("macbook"), "no crashReporterKey, boot/wake UUIDs, device name")
        check(!t.contains("otherThreadSecretSymbol"), "no other-thread frames")
        check(p.condensed.signature == "EXC_BREAKPOINT: crashingFunctionOne > +0x2b50 > crashingFunctionThree", "signature = type + first 3 app frames (got: \(p.condensed.signature))")
        check(p.condensed.signature.count <= 300, "signature <= 300")
        check(p.condensed.app == "1.0.46" && p.condensed.build == "86" && p.condensed.os == "26.3.1" && p.condensed.model == "Mac15,6" && p.condensed.arch == "arm64", "version fields from the report")
        // 家目录和测试里的不一样时也不能漏用户名
        if let p2 = CrashReporter.findPending(ctx(dirA, home: "/Users/someoneelse")) {
            check(!p2.condensed.text.contains("janedoe") && !p2.condensed.text.contains("/Users/"), "no user name when the real home differs (generic /Users/<name> rule)")
        } else { check(false, "second context found no report") }

        // 其他筛选条件
        let dirWrong = makeDir(root.appendingPathComponent("reports-wrongid"))
        write(makeIPS(bundleID: "com.example.other"), as: good, in: dirWrong)
        let sw = MemoryCrashStore()
        check(CrashReporter.findPending(ctx(dirWrong, store: sw)) == nil, "ignores wrong bundle id")
        check((sw.object(forKey: CrashReporter.handledKey) as? Double) != nil, "wrong-bundle-only files are marked seen")
        let dirOld = makeDir(root.appendingPathComponent("reports-old"))
        write(makeIPS(bundleID: bid), as: tooOld, in: dirOld)
        check(CrashReporter.findPending(ctx(dirOld)) == nil, "ignores reports older than 7 days")
        let sh = MemoryCrashStore()
        sh.set(ago(1200).timeIntervalSince1970, forKey: CrashReporter.handledKey)
        check(CrashReporter.findPending(ctx(dirA, store: sh)) == nil, "ignores reports older than last-handled")
        let sh2 = MemoryCrashStore()
        sh2.set(ago(3 * 3600).timeIntervalSince1970, forKey: CrashReporter.handledKey)
        check(CrashReporter.findPending(ctx(dirA, store: sh2))?.file.lastPathComponent == good, "report newer than last-handled still qualifies")
        check(CrashReporter.findPending(ctx(root.appendingPathComponent("does-not-exist"))) == nil, "missing reports folder -> nothing")
        let soff = MemoryCrashStore()
        soff.set(false, forKey: CrashReporter.enabledKey)
        check(CrashReporter.findPending(ctx(dirA, store: soff)) == nil, "nothing selected when the feature is off")
        check(CrashReporter.findPending(CrashReporter.Context(reportsDir: dirA, store: MemoryCrashStore(), now: now, bundleID: nil, home: fakeHome)) == nil, "no bundle id -> nothing")

        // 流程：发送、已处理、不再询问
        var sent: [URLRequest] = []
        var asked = 0
        let url = "http://127.0.0.1:1/crash"
        let sf = MemoryCrashStore()
        var okResult: Bool?
        let r1 = CrashReporter.process(ctx(dirA, store: sf), lang: "zh-Hans", variant: "site", url: url,
                                       ask: { _ in asked += 1; return .init(send: true, note: String(repeating: "n", count: 600) + " /Users/janedoe/x", dontAskAgain: false) },
                                       sender: { req, done in sent.append(req); done(true) }, completion: { okResult = $0 })
        check(r1 != nil && asked == 1 && sent.count == 1 && okResult == true, "send: asked once, one request, completion ok")
        if let req = sent.first, let body = req.httpBody, let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            check(req.httpMethod == "POST" && req.url?.absoluteString == url && req.value(forHTTPHeaderField: "Content-Type") == "application/json", "request: POST, URL, content type")
            check(Set(obj.keys) == ["app", "build", "os", "model", "arch", "lang", "variant", "signature", "note", "report"], "JSON body has exactly the agreed fields")
            check(obj.values.allSatisfy { $0 is String }, "all fields are strings")
            check(obj["app"] as? String == "1.0.46" && obj["build"] as? String == "86" && obj["os"] as? String == "26.3.1" && obj["model"] as? String == "Mac15,6" && obj["arch"] as? String == "arm64", "body: app/build/os/model/arch")
            check(obj["lang"] as? String == "zh-Hans" && obj["variant"] as? String == "site", "body: lang and variant")
            check((obj["note"] as? String)?.count == 500, "note capped at 500 characters")
            check(obj["signature"] as? String == p.condensed.signature && obj["report"] as? String == p.condensed.text, "body: signature and report")
            check(!(String(data: body, encoding: .utf8) ?? "").contains("janedoe"), "whole body has no user name")
        } else { check(false, "request body is a JSON object") }
        let note2 = (try? JSONSerialization.jsonObject(with: CrashReporter.requestBody(p.condensed, note: "  crashed at /Users/janedoe/x  ", lang: "en", variant: "site", home: fakeHome) ?? Data())) as? [String: Any]
        check(note2?["note"] as? String == "crashed at ~/x", "note: trimmed and home replaced")
        asked = 0
        check(CrashReporter.process(ctx(dirA, store: sf), lang: "en", variant: "site", url: url, ask: { _ in asked += 1; return .init(send: true, note: "", dontAskAgain: false) },
                                    sender: { r, d in sent.append(r); d(true) }) == nil && asked == 0 && sent.count == 1, "handled: no second prompt, nothing sent")

        // 不发送 + 不再询问
        let sd = MemoryCrashStore()
        var sentD = 0
        let r2 = CrashReporter.process(ctx(dirA, store: sd), lang: "en", variant: "site", url: url, ask: { _ in .init(send: false, note: "ignored", dontAskAgain: true) },
                                       sender: { _, d in sentD += 1; d(true) })
        check(r2 != nil && sentD == 0, "Don't Send: nothing sent")
        check(!CrashReporter.enabled(in: sd), "Don't ask again turns the feature off")
        let dirNew = makeDir(root.appendingPathComponent("reports-new"))
        write(makeIPS(bundleID: bid), as: nameFor(ago(60)), in: dirNew)
        check(CrashReporter.findPending(ctx(dirNew, store: sd)) == nil, "after Don't ask again a new report is not offered")
        // 失败：记为已处理，不重试
        let sx = MemoryCrashStore()
        var failedResult: Bool?
        _ = CrashReporter.process(ctx(dirA, store: sx), lang: "en", variant: "site", url: url, ask: { _ in .init(send: true, note: "", dontAskAgain: false) },
                                  sender: { _, d in d(false) }, completion: { failedResult = $0 })
        check(failedResult == false && CrashReporter.findPending(ctx(dirA, store: sx)) == nil, "failed send is still marked handled (no retry)")

        // 上限
        let bigDir = makeDir(root.appendingPathComponent("reports-big"))
        let many = (0..<100).map { frame(0, off: $0, symbol: "frameNumber\($0)", loc: 1) }
        write(makeIPS(bundleID: bid, frames: many, extraImages: 3000), as: nameFor(ago(60)), in: bigDir)
        if let big = CrashReporter.findPending(ctx(bigDir)) {
            check(big.condensed.text.count == CrashReporter.maxReportChars && big.condensed.text.hasSuffix(CrashReporter.truncationMarker), "60,000-character cap with truncation marker")
            let frameLines = big.condensed.text.split(separator: "\n").filter { $0.contains("frameNumber") }.count
            check(frameLines == 60, "crashed thread limited to 60 frames (got \(frameLines))")
        } else { check(false, "big fixture found") }
        let longSym = String(repeating: "s", count: 200)
        let sigDir = makeDir(root.appendingPathComponent("reports-sig"))
        write(makeIPS(bundleID: bid, frames: [frame(0, off: 1, symbol: longSym + "1"), frame(0, off: 2, symbol: longSym + "2"), frame(0, off: 3, symbol: longSym + "3")]), as: nameFor(ago(60)), in: sigDir)
        if let sg = CrashReporter.findPending(ctx(sigDir)) { check(sg.condensed.signature.count == 300, "long signature cut to 300") } else { check(false, "sig fixture found") }
        // 没有可读内容
        check(CrashReporter.condense(data: Data(), home: fakeHome) == nil && CrashReporter.condense(data: Data("{}".utf8), home: fakeHome) == nil, "empty or malformed input -> nil, no crash")

        // 真报告烟测：只打印通过与否和长度
        if let real = ProcessInfo.processInfo.environment["CRASHTEST_REAL"], !real.isEmpty {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: real)), let c = CrashReporter.condense(data: data, home: NSHomeDirectory()) {
                var leaks = c.text.contains("/Users/") || c.text.contains(NSHomeDirectory()) || c.text.contains(NSUserName())
                if let nl = data.firstIndex(of: 0x0A), let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...])) as? [String: Any] {
                    for k in ["crashReporterKey", "bootSessionUUID", "sleepWakeUUID"] { if let v = body[k] as? String, !v.isEmpty, c.text.contains(v) { leaks = true } }
                }
                check(!leaks && c.text.count <= CrashReporter.maxReportChars && !c.signature.isEmpty && c.signature.count <= 300, "real report smoke (output length \(c.text.count), signature length \(c.signature.count))")
            } else {
                check(false, "real report smoke: could not read or parse CRASHTEST_REAL")
            }
        }
        // 脱敏：家目录下的路径不留文件夹和文件名
        let hp = CrashReporter.sanitize("Unable to read /Users/janedoe/Pictures/holiday/IMG_0001.JPG and ~/Desktop/secret folder", home: fakeHome)
        check(!hp.contains("IMG_0001") && !hp.contains("holiday") && !hp.contains("Desktop") && hp.contains("~/[file].jpg"), "home paths keep only the extension: \(hp)")

        CrashReportLaunchTest.run(root: root)
        finish()
    }
}

import AppKit

/// --crashreporttest 的后半段：走和正式启动同一段代码（CrashReporter.launchCheck）。
/// 平时用假的发送器；环境变量 CRASHTEST_SEND=1 时真的往线上发一条假报告，看服务器认不认
/// --crashprompttest <输出文件夹>：用假报告弹出询问窗口，截一张图后自动关掉（只给人看样子，不发送）
enum CrashPromptShot {
    static func run(outDir: String) {
        let T = CrashReportSelfTest.self
        let root = T.makeDir(URL(fileURLWithPath: outDir).appendingPathComponent("prompt-fixture"))
        let bid = "com.example.flipic.promptshot"
        T.write(T.makeIPS(bundleID: bid), as: T.nameFor(Date().addingTimeInterval(-60)), in: root)
        let c = CrashReporter.Context(reportsDir: root, store: MemoryCrashStore(), now: Date(), bundleID: bid, home: T.fakeHome)
        guard let p = CrashReporter.findPending(c) else { print("PROMPTSHOT FAIL no fixture"); exit(1) }
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 1.2, repeats: false) { _ in
            if let w = NSApp.modalWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Alert") }),
               let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outDir + "/crash-prompt.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("PROMPTSHOT ok")
            } else {
                print("PROMPTSHOT FAIL no alert window")
            }
            NSApp.abortModal()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        _ = CrashPrompt.ask(p)
        fflush(stdout)
        exit(0)
    }
}

enum CrashReportLaunchTest {
    static func run(root: URL) {
        let T = CrashReportSelfTest.self
        let bid = "com.example.flipic.launchtest"
        let now = Date()
        func fixture(_ name: String) -> CrashReporter.Context {
            let dir = T.makeDir(root.appendingPathComponent(name))
            T.write(T.makeIPS(bundleID: bid), as: T.nameFor(now.addingTimeInterval(-120)), in: dir)
            return CrashReporter.Context(reportsDir: dir, store: MemoryCrashStore(), now: now, bundleID: bid, home: T.fakeHome)
        }
        let yes: (CrashReporter.Pending) -> CrashReporter.Answer = { _ in .init(send: true, note: "联调测试，请忽略", dontAskAgain: false) }

        // 一、假发送器：地址是默认的线上地址，请求格式对
        var captured: URLRequest?
        let c1 = fixture("launch-fake")
        let p1 = CrashReporter.launchCheck(env: [:], args: ["Flipic"], context: c1, ask: yes, sender: { req, done in captured = req; done(true) })
        T.check(p1 != nil && captured?.url?.absoluteString == CrashReporter.defaultEndpoint && captured?.httpMethod == "POST"
                && captured?.value(forHTTPHeaderField: "Content-Type") == "application/json" && (captured?.httpBody?.count ?? 0) > 100,
                "launch path: finds the report and builds a POST to the default endpoint")
        T.check(CrashReporter.findPending(c1) == nil, "launch path: report marked handled, no second prompt")
        var asked = false
        let c2 = fixture("launch-quiet")
        let p2 = CrashReporter.launchCheck(env: ["FLIPIC_QUIET_TEST": "1"], args: ["Flipic"], context: c2, ask: { _ in asked = true; return .init(send: false, note: "", dontAskAgain: false) }, sender: { _, done in done(false) })
        T.check(p2 == nil && !asked, "launch path: nothing happens under FLIPIC_QUIET_TEST")
        // 真实的目录和设置只读一遍，不写：确认正式用的 Context 能建出来、能查
        _ = CrashReporter.findPending(.live)
        T.check(true, "launch path: live context listing did not crash")

        // 二、真的发一次
        guard ProcessInfo.processInfo.environment["CRASHTEST_SEND"] == "1" else { return }
        var result: Bool?
        CrashReporter.launchCheck(env: [:], args: ["Flipic"], context: fixture("launch-live"), ask: yes, sender: CrashReporter.liveSender) { result = $0 }
        let until = Date().addingTimeInterval(25)
        while result == nil && Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        T.check(result == true, "launch path: live send accepted by the server")
    }
}

import AppKit

/// `Flipic --updatestattest`：检查更新请求里的安装时长区间、Pro 标记、手动标记，以及自动检查默认开启的自测。
/// 全程用临时的 UserDefaults，不碰真正的偏好设置。最后一行 UPDATESTAT checks=N failures=M
enum UpdateStatSelfTest {
    static var checks = 0
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("UPDATESTAT \(ok ? "ok  " : "FAIL") \(what)")
    }

    static func run() {
        let now = Date()
        func ago(_ days: Double, _ extra: Double = 0) -> Date { now.addingTimeInterval(-days * 86400 - extra) }

        // 区间边界
        let cases: [(String, Date, String)] = [
            ("0 天", ago(0), "0-6"), ("6 天 23 小时", ago(6, 23 * 3600), "0-6"), ("7 天", ago(7), "7-29"),
            ("29 天 23 小时", ago(29, 23 * 3600), "7-29"), ("30 天", ago(30), "30+"), ("400 天", ago(400), "30+"),
            ("时钟往回拨 3 天", now.addingTimeInterval(3 * 86400), "0-6"),
        ]
        for (name, installed, want) in cases {
            let got = UpdateChecker.ageBucket(installed: installed, now: now)
            check(got == want, "bucket \(name) -> \(got) (want \(want))")
        }

        // 第一次使用日期的来源
        func suite(_ tag: String) -> UserDefaults {
            let name = "com.xmasdong.photoview.updatestattest.\(tag)"
            UserDefaults().removePersistentDomain(forName: name)
            return UserDefaults(suiteName: name)!
        }
        let fresh = suite("fresh")
        let seeded = UpdateChecker.ensureInstallDate(fresh, now: now)
        check(abs(seeded.timeIntervalSince(now)) < 1, "seed: nothing known -> now")
        check(UpdateChecker.ensureInstallDate(fresh, now: now.addingTimeInterval(99 * 86400)) == seeded, "seed: stored once, not overwritten")

        let trial = suite("trial")
        trial.set(ago(12), forKey: "proTrialStart")
        check(UpdateChecker.ensureInstallDate(trial, now: now) == ago(12), "seed: from proTrialStart")

        let last = suite("last")
        last.set(ago(40), forKey: "lastUpdateCheck")
        check(UpdateChecker.ensureInstallDate(last, now: now) == ago(40), "seed: from lastUpdateCheck")

        let both = suite("both")
        both.set(ago(12), forKey: "proTrialStart")
        both.set(ago(40), forKey: "lastUpdateCheck")
        check(UpdateChecker.ensureInstallDate(both, now: now) == ago(40), "seed: earliest of the two")

        let future = suite("future")
        future.set(now.addingTimeInterval(5 * 86400), forKey: "proTrialStart")
        check(abs(UpdateChecker.ensureInstallDate(future, now: now).timeIntervalSince(now)) < 1, "seed: evidence in the future ignored")

        // 请求地址
        let plain = URL(string: "https://flipic.app/version.json")!
        check(UpdateChecker.requestURL(base: plain, bucket: "7-29", pro: true, manual: false).absoluteString == "https://flipic.app/version.json?a=7-29&p=1", "url: auto, pro")
        check(UpdateChecker.requestURL(base: plain, bucket: "30+", pro: false, manual: true).absoluteString == "https://flipic.app/version.json?a=30%2B&p=0&m=1", "url: manual adds m=1, + encoded as %2B")
        let auto = UpdateChecker.requestURL(base: plain, bucket: "0-6", pro: false, manual: false)
        check(URLComponents(url: auto, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "m" } == false, "url: auto has no m")
        let custom = URL(string: "http://127.0.0.1:8080/feed.json?token=x&a=old")!
        let customOut = URLComponents(url: UpdateChecker.requestURL(base: custom, bucket: "0-6", pro: false, manual: false), resolvingAgainstBaseURL: false)
        check(customOut?.host == "127.0.0.1" && customOut?.port == 8080 && customOut?.path == "/feed.json", "url: custom feed host/path kept")
        let q = Dictionary(uniqueKeysWithValues: (customOut?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        check(q["token"] == "x" && q["a"] == "0-6" && q["p"] == "0" && q["m"] == nil, "url: existing query kept, a replaced (\(q))")
        let file = URL(fileURLWithPath: "/tmp/feed.json")
        check(UpdateChecker.requestURL(base: file, bucket: "0-6", pro: false, manual: true) == file, "url: file feed untouched")
        #if !FLIPIC_PRO
        check(!UpdateChecker.proActivated, "pro flag false without Pro build")
        #endif

        // 自动检查默认开
        let d = suite("auto")
        check(UpdateChecker.autoCheckEnabled(d), "autoCheck: key unset -> on")
        d.set(true, forKey: UpdateChecker.autoCheckKey)
        check(UpdateChecker.autoCheckEnabled(d), "autoCheck: true -> on")
        d.set(false, forKey: UpdateChecker.autoCheckKey)
        check(!UpdateChecker.autoCheckEnabled(d), "autoCheck: false -> off")

        for t in ["fresh", "trial", "last", "both", "future", "auto"] {
            UserDefaults().removePersistentDomain(forName: "com.xmasdong.photoview.updatestattest.\(t)")
        }
        print("UPDATESTAT checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

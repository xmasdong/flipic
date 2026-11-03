import AppKit
import Darwin

/// --bench <文件夹>：自动翻页跑分，输出内存峰值、翻页出图延迟、主线程最长卡顿（仅诊断用）
enum BenchProbe {
    static var enabled = false
    static let traceNav = CommandLine.arguments.contains("--fadeseq")
    private static var navAt: CFAbsoluteTime?
    private static var latencies: [Double] = []
    static var fullWidth = 0
    /// 每次翻页的序号、按下时刻；首个像素（草图或清晰图）与清晰图各自的到达延迟，按序号记
    private static var navSeq = 0
    private static var lastNavAt: CFAbsoluteTime = 0
    private static var sharpPending = false
    private static var firstPixel: [Int: Double] = [:]
    private static var sharpAt: [Int: Double] = [:]
    /// 屏幕上有过图之后，又出现「当前没图」的采样次数（内存压力测试用：当前照片不能变空白）
    private static var hadImage = false
    private static var blankSamples = 0

    private static let trace = ProcessInfo.processInfo.environment["BENCH_TRACE"] != nil
    private static let t0 = CFAbsoluteTimeGetCurrent()
    static func log(_ what: @autoclosure () -> String) {
        if trace { print(String(format: "BENCHTRACE %7.1f %@", (CFAbsoluteTimeGetCurrent() - t0) * 1000, what())) }
    }

    static func navigated() {
        guard enabled else { return }
        log("nav \(navSeq + 1)")
        navAt = CFAbsoluteTimeGetCurrent()
        lastNavAt = navAt!
        navSeq += 1
        sharpPending = true
    }

    /// 新图第一次上屏时调用（草图也算）
    static func adopted() {
        log("adopt")
        guard enabled, let t = navAt else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        latencies.append(ms)
        firstPixel[navSeq] = ms
        navAt = nil
    }

    /// 当前照片的清晰图（屏幕尺寸预览或原图）上屏时调用
    static func sharpShown() {
        log("sharp")
        guard enabled, sharpPending else { return }
        sharpAt[navSeq] = (CFAbsoluteTimeGetCurrent() - lastNavAt) * 1000
        sharpPending = false
    }

    private static func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        guard !s.isEmpty else { return "n=0" }
        return String(format: "n=%d p50=%.0fms max=%.0fms", s.count, s[s.count / 2], s.last!)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func run(folder: String, open: (URL) -> Void, forward: @escaping () -> Void, zoomActual: @escaping () -> Void,
                    state: @escaping () -> String = { "" }, hasImage: @escaping () -> Bool = { true },
                    capture: @escaping (String) -> Void = { _ in }, shownLevel: @escaping () -> String = { "" }) {
        enabled = true
        let env = ProcessInfo.processInfo.environment
        // BENCH_PRESSURE_MS=500：每 500ms 直接触发一次内存压力处理（BENCH_PRESSURE=critical 时按严重级别），模拟忙碌的 16GB Mac
        var pressureTimer: Timer?
        if let ms = Double(env["BENCH_PRESSURE_MS"] ?? ""), ms > 0 {
            let critical = env["BENCH_PRESSURE"] == "critical"
            pressureTimer = Timer(timeInterval: ms / 1000, repeats: true) { _ in ImageLoader.shared.handleMemoryPressure(critical: critical) }
            RunLoop.main.add(pressureTimer!, forMode: .common)
        }
        var peak = 0.0
        var maxGap = 0.0
        var phase = "open"
        var phaseGap: [String: Double] = [:]
        var last = CFAbsoluteTimeGetCurrent()
        let sampler = Timer(timeInterval: 0.016, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let gap = (now - last) * 1000
            maxGap = max(maxGap, gap)
            phaseGap[phase] = max(phaseGap[phase] ?? 0, gap)
            last = now
            peak = max(peak, footprintMB())
            if hasImage() { hadImage = true } else if hadImage { blankSamples += 1 }
        }
        RunLoop.main.add(sampler, forMode: .common)
        let cpu0 = cpuSeconds()
        navigated()
        open(URL(fileURLWithPath: folder))

        // 每一步按点准时触发：asyncAfter 默认允许约 10% 的误差，2 秒后的 30ms 连按会被合并成三五个一批同时到，
        // 不像真实的按键重复。BENCH_LOOSE=1 时按旧方式排（与旧版跑分对照用）
        let loose = env["BENCH_LOOSE"] != nil
        let start = DispatchTime.now()
        func at(_ t: Double, _ block: @escaping () -> Void) {
            if loose {
                DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: block)
                return
            }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: start + t, leeway: .milliseconds(1))
            timer.setEventHandler { block(); timer.cancel() }
            timer.resume()
        }
        var t = 2.0
        let afterOpen = { () -> Double in footprintMB() }
        var openMB = 0.0
        at(t) { openMB = afterOpen() }
        // 快速连翻 40 次（默认 120ms 一张，模拟按住方向键；BENCH_FAST_MS 可改，系统最快的按键重复约 30ms）
        let fastStep = (Double(env["BENCH_FAST_MS"] ?? "") ?? 120) / 1000
        at(t) { phase = "fast" }
        // BENCH_SHOTS=<文件夹>：快翻到第 20、30 下时（下一下之前）和停下来 1 秒后各截一张本窗口，看草图摆得对不对
        let shots = env["BENCH_SHOTS"]
        for k in 0..<40 {
            t += fastStep
            at(t) { navigated(); forward() }
            if let shots, k == 19 || k == 29 {
                at(t + fastStep * 0.8) {
                    print("BENCH shot mid-burst-\(k + 1) shown=\(shownLevel()) " + state())
                    capture(shots + "/mid-burst-\(k + 1).png")
                }
            }
        }
        if let shots {
            at(t + 1.0) {
                print("BENCH shot settled shown=\(shownLevel()) " + state())
                capture(shots + "/settled.png")
            }
        }
        t += 2.0
        var fastMB = 0.0
        at(t) { fastMB = footprintMB() }
        // 正常浏览 10 次（800ms 一张）
        at(t) { phase = "slow" }
        for _ in 0..<10 {
            t += 0.8
            at(t) { navigated(); forward() }
        }
        t += 1.5
        var slowMB = 0.0
        var slowLat: [Double] = []
        at(t) {
            slowMB = footprintMB()
            slowLat = Array(latencies.suffix(10))
            phase = "zoom"
            zoomActual()
        }
        // 放大到 1:1 后翻到下一张：应回到适应窗口并居中
        var navState = ""
        t += 2.0
        at(t) { print("BENCH zoomed: " + state()); phase = "navFromZoom"; forward() }
        t += 1.0
        at(t) { navState = state(); print("BENCH afterNav: " + navState) }
        t += 1.0
        at(t) {
            sampler.invalidate()
            pressureTimer?.invalidate()
            let zoomMB = footprintMB()
            let sorted = slowLat.sorted()
            let p = { (q: Double) -> Double in sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            let fast = latencies.dropFirst().dropLast(10).sorted()
            let line = String(format: "BENCH open=%.0fMB afterFast=%.0fMB afterSlow=%.0fMB afterZoom1:1=%.0fMB peak=%.0fMB | slowNav p50=%.0fms max=%.0fms | fastNav shown=%d/40 | firstOpen=%.0fms | mainMaxStall=%.0fms | cpu=%.1fs | zoomedBackingWidth=%d",
                              openMB, fastMB, slowMB, zoomMB, peak, p(0.5), sorted.last ?? -1,
                              fast.count, latencies.first ?? -1, maxGap, cpuSeconds() - cpu0, fullWidth)
            print(line)
            // 序号：1 = 打开，2...41 = 快翻，42...51 = 慢翻
            let fastSeq = 2...41, slowSeq = 42...51
            let line2 = "BENCH fastFirstPixel " + stats(fastSeq.compactMap { firstPixel[$0] })
                + String(format: " | fastSharpAfterLastKey=%.0fms", sharpAt[41] ?? -1)
                + " | fastSharpSteps=\(fastSeq.filter { sharpAt[$0] != nil }.count)/40"
                + " | slowFirstPixel " + stats(slowSeq.compactMap { firstPixel[$0] })
                + " | slowSharp " + stats(slowSeq.compactMap { sharpAt[$0] })
                + " | blankSamples=\(blankSamples)"
                + (pressureTimer != nil ? " | pressure=\(env["BENCH_PRESSURE"] ?? "warning")@\(env["BENCH_PRESSURE_MS"]!)ms" : "")
            print(line2)
            print("BENCH stallByPhase " + phaseGap.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))ms" }.joined(separator: " "))
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}

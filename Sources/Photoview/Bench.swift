import AppKit
import Darwin

/// --bench <文件夹>：自动翻页跑分，输出内存峰值、翻页出图延迟、主线程最长卡顿（仅诊断用）
enum BenchProbe {
    static var enabled = false
    private static var navAt: CFAbsoluteTime?
    private static var latencies: [Double] = []
    static var fullWidth = 0

    static func navigated() {
        guard enabled else { return }
        navAt = CFAbsoluteTimeGetCurrent()
    }

    /// 新图第一次上屏时调用
    static func adopted() {
        guard enabled, let t = navAt else { return }
        latencies.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        navAt = nil
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
                    state: @escaping () -> String = { "" }) {
        enabled = true
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
        }
        RunLoop.main.add(sampler, forMode: .common)
        let cpu0 = cpuSeconds()
        navigated()
        open(URL(fileURLWithPath: folder))

        var t = 2.0
        let afterOpen = { () -> Double in footprintMB() }
        var openMB = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { openMB = afterOpen() }
        // 快速连翻 40 次（120ms 一张，模拟按住方向键）
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { phase = "fast" }
        for _ in 0..<40 {
            t += 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { navigated(); forward() }
        }
        t += 2.0
        var fastMB = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { fastMB = footprintMB() }
        // 正常浏览 10 次（800ms 一张）
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { phase = "slow" }
        for _ in 0..<10 {
            t += 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { navigated(); forward() }
        }
        t += 1.5
        var slowMB = 0.0
        var slowLat: [Double] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            slowMB = footprintMB()
            slowLat = Array(latencies.suffix(10))
            phase = "zoom"
            zoomActual()
        }
        // 放大到 1:1 后翻到下一张：应回到适应窗口并居中
        var navState = ""
        t += 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { print("BENCH zoomed: " + state()); phase = "navFromZoom"; forward() }
        t += 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { navState = state(); print("BENCH afterNav: " + navState) }
        t += 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            sampler.invalidate()
            let zoomMB = footprintMB()
            let sorted = slowLat.sorted()
            let p = { (q: Double) -> Double in sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            let fast = latencies.dropFirst().dropLast(10).sorted()
            let line = String(format: "BENCH open=%.0fMB afterFast=%.0fMB afterSlow=%.0fMB afterZoom1:1=%.0fMB peak=%.0fMB | slowNav p50=%.0fms max=%.0fms | fastNav shown=%d/40 | firstOpen=%.0fms | mainMaxStall=%.0fms | cpu=%.1fs | zoomedBackingWidth=%d",
                              openMB, fastMB, slowMB, zoomMB, peak, p(0.5), sorted.last ?? -1,
                              fast.count, latencies.first ?? -1, maxGap, cpuSeconds() - cpu0, fullWidth)
            print(line)
            print("BENCH stallByPhase " + phaseGap.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))ms" }.joined(separator: " "))
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}

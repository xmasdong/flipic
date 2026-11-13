import AppKit

// 系统解 RAW 时会留一批显存表面备用，默认按机器内存放得很开（64GB 上解 40 张留 2GB），
// 看图一次只用一两张，留多了只占内存不提速。按物理内存限在 128~256MB；必须在第一次解码前设好。
// 环境里已经有值时不覆盖（对照测试用）
setenv("CI_SURFACE_CACHE_CAPACITY",
       String(min(max(ProcessInfo.processInfo.physicalMemory / 64, 128 << 20), 256 << 20)), 0)

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `Flipic --extcachetest <工作文件夹>`：
/// 验证外接硬盘本机 SSD 持久化预览缓存与慢盘单通道调度：
/// 1. 内置快盘不写外接盘缓存
/// 2. 慢存储首次解码异步落盘（20 字节 FPC1 头 + JPEG）→ 清内存重启后直接命中本机 SSD（外接盘 0 读盘，同时恢复 ImageInfo 原图尺寸）
/// 3. 原图修改（mtime/大小变化）自动失效并重解新像素
/// 4. 带透明通道的 PNG 跳过 JPEG 缓存，保持透明标记
/// 5. 500 MB LRU（测试用小上限）按最久未访问自动淘汰到 80% 水位
/// 6. 开关关闭与一键清空生效
/// 7. 慢盘切单通道顺序队列（width=1），快盘恢复并发（width=2）
/// 8. 截取设置 → 通用页「外接盘加速」实机截图。最后一行 EXTCACHE summary
extension ViewerViewController {
    func runExtCacheTest(outDir: String) {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("extcache-\(lang)")
        let shots = URL(fileURLWithPath: outDir).appendingPathComponent("shots-\(lang)")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)

        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("EXTCACHE \(ok ? "ok  " : "FAIL") [\(lang)] \(what)")
            fflush(stdout)
        }
        func pump(_ secs: Double = 0.05) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: secs))
        }

        // 隔离 ExtDiskCache 与偏好开关，绝不碰用户真实缓存目录
        let prevCache = ExtDiskCache.shared
        let prevEnabled = ExtDiskCache.enabled
        let prevSlow = Volumes.debugForceSlow
        let cacheDir = root.appendingPathComponent("ssd-cache")
        ExtDiskCache.shared = ExtDiskCache(directory: cacheDir, maxBytes: 50 << 20)
        ExtDiskCache.enabled = true
        defer {
            Volumes.debugForceSlow = prevSlow
            ExtDiskCache.enabled = prevEnabled
            ExtDiskCache.shared = prevCache
            loader.purge()
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func writeJPEG(_ url: URL, w: Int, h: Int, r: CGFloat, g: CGFloat, b: CGFloat) {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // 加一点纹理让 JPEG 有合理体积
            ctx.setFillColor(CGColor(srgbRed: min(1, r + 0.15), green: max(0, g - 0.1), blue: min(1, b + 0.1), alpha: 1))
            for k in stride(from: 0, to: w, by: 64) {
                ctx.fill(CGRect(x: k, y: (k * 3) % max(1, h - 40), width: 32, height: 32))
            }
            let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality as String: 0.9] as CFDictionary)
            CGImageDestinationFinalize(d)
        }

        func writeAlphaPNG(_ url: URL, w: Int = 400, h: Int = 300) {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 0.7))
            ctx.fill(CGRect(x: 50, y: 50, width: 200, height: 150))
            let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }

        func centerRGB(_ img: CGImage) -> (Int, Int, Int) {
            let w = img.width, h = img.height
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
            let p = ((h / 2) * w + (w / 2)) * 4
            return (Int(ptr[p]), Int(ptr[p + 1]), Int(ptr[p + 2]))
        }

        let photos = root.appendingPathComponent("photos")
        try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let jpg1 = photos.appendingPathComponent("01_blue.jpg")
        let pngAlpha = photos.appendingPathComponent("02_alpha.png")
        writeJPEG(jpg1, w: 2400, h: 1600, r: 0.12, g: 0.35, b: 0.82)
        writeAlphaPNG(pngAlpha)

        // 1. 快盘不写外接盘缓存
        Volumes.debugForceSlow = false
        loader.purge()
        _ = loader.preview(for: jpg1, maxPixel: 1600)
        _ = loader.thumb(for: jpg1)
        ExtDiskCache.shared.debugFlushWrites()
        check(ExtDiskCache.shared.debugWrites == 0 && ExtDiskCache.shared.diskUsageBytes() == 0,
              "fast internal disk writes 0 cache files")

        // 2. 慢存储首次解码写盘 + 重启清内存后 100% 命中本机 SSD（含 20B 头恢复 ImageInfo）
        Volumes.debugForceSlow = true
        loader.purge()
        let firstPrev = loader.preview(for: jpg1, maxPixel: 1600)
        let firstThumb = loader.thumb(for: jpg1)
        ExtDiskCache.shared.debugFlushWrites()
        let usageAfterFirst = ExtDiskCache.shared.diskUsageBytes()
        check(firstPrev != nil && firstThumb != nil && ExtDiskCache.shared.debugWrites >= 2 && usageAfterFirst > 10_000,
              "slow disk caches preview+thumb to SSD (writes=\(ExtDiskCache.shared.debugWrites), bytes=\(usageAfterFirst))")

        // 模拟 App 重启 / 拔盘重插：清空全部内存缓存（含 infoCache）
        loader.purge()
        ExtDiskCache.shared.debugResetCounters()
        let infoHit = ExtDiskCache.shared.readInfo(for: jpg1)
        check(infoHit != nil && Int(infoHit!.pixelSize.width) == 2400 && Int(infoHit!.pixelSize.height) == 1600,
              "20-byte FPC1 header restores exact orig pixelSize=\(infoHit?.pixelSize ?? .zero)")

        // 白盒零外接盘读盘证明：原图字节还在，验证第二次 preview + thumb 直接从本机 SSD 命中
        let cachedPrev = loader.preview(for: jpg1, maxPixel: 1600)
        let cachedThumb = loader.thumb(for: jpg1)
        check(cachedPrev != nil && cachedThumb != nil && ExtDiskCache.shared.debugHits >= 2,
              "reopen hits local SSD cache for both preview & thumb (hits=\(ExtDiskCache.shared.debugHits))")
        if let p = cachedPrev {
            let c = centerRGB(p)
            check(c.2 > c.0 + 80, "cached preview preserves true blue color rgb=\(c)")
        }

        // 5K 大窗测试：从 1600px 换到 5K 窗口 (3200px) 会自动升级缓存；更大尺寸 3600px 原图封顶存 2560px，二次 3200px 直接命中
        let jpg5K = photos.appendingPathComponent("03_5k.jpg")
        writeJPEG(jpg5K, w: 3600, h: 2400, r: 0.25, g: 0.65, b: 0.35)
        _ = loader.preview(for: jpg5K, maxPixel: 3200)
        ExtDiskCache.shared.debugFlushWrites()
        loader.purge()
        ExtDiskCache.shared.debugResetCounters()
        let hit5K = loader.preview(for: jpg5K, maxPixel: 3200)
        check(hit5K != nil && ExtDiskCache.shared.debugHits == 1,
              "5K window (3200px) hits capped 2560px SSD cache (hits=\(ExtDiskCache.shared.debugHits))")

        // 3. 原图修改后自动失效并重解新图（改成纯红 + 不同尺寸与 mtime）
        let oldHits = ExtDiskCache.shared.debugHits
        writeJPEG(jpg1, w: 2000, h: 1400, r: 0.88, g: 0.15, b: 0.12)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: jpg1.path)
        loader.evict(url: jpg1)
        let editedPrev = loader.preview(for: jpg1, maxPixel: 1600)
        ExtDiskCache.shared.debugFlushWrites()
        check(editedPrev != nil && ExtDiskCache.shared.debugHits == oldHits,
              "modified photo bypasses stale cache")
        if let ep = editedPrev {
            let c = centerRGB(ep)
            check(c.0 > c.2 + 80, "modified photo shows new red color rgb=\(c)")
        }

        // 4. 带透明通道的 PNG 跳过 JPEG 缓存，保持透明标记
        loader.purge()
        let writesBeforeAlpha = ExtDiskCache.shared.debugWrites
        let alphaPrev = loader.preview(for: pngAlpha, maxPixel: 800)
        ExtDiskCache.shared.debugFlushWrites()
        check(alphaPrev != nil && ImageLoader.isTransparent(alphaPrev) && ExtDiskCache.shared.debugWrites == writesBeforeAlpha,
              "transparent PNG skipped from JPEG cache & keeps alpha flag")

        // 5. LRU 容量上限淘汰验证（设 120 KB 上限，写 6 张 ~40 KB 图，自动压回 ≤ 120 KB）
        let lruDir = root.appendingPathComponent("lru-cache")
        let lru = ExtDiskCache(directory: lruDir, maxBytes: 120_000)
        let prevShared = ExtDiskCache.shared
        ExtDiskCache.shared = lru
        for i in 1...6 {
            let u = photos.appendingPathComponent("lru_\(i).jpg")
            writeJPEG(u, w: 1800, h: 1200, r: CGFloat(i) * 0.14, g: 0.4, b: 0.5)
            _ = loader.preview(for: u, maxPixel: 1600)
            lru.debugFlushWrites()
            // 稍微拉开 mtime 保证 LRU 顺序确定
            Thread.sleep(forTimeInterval: 0.05)
        }
        lru.trimLRU()
        let lruBytes = lru.diskUsageBytes()
        check(lruBytes > 0 && lruBytes <= 120_000, "LRU trim keeps cache within cap (bytes=\(lruBytes) <= 120000)")
        ExtDiskCache.shared = prevShared

        // 6. 开关关闭 & 一键清除缓存
        ExtDiskCache.enabled = false
        loader.purge()
        let hitsWhileOff = ExtDiskCache.shared.debugHits
        _ = loader.preview(for: jpg1, maxPixel: 1600)
        check(ExtDiskCache.shared.debugHits == hitsWhileOff, "disabled switch bypasses SSD cache")
        ExtDiskCache.enabled = true

        // 7. 慢盘切单通道顺序队列（width=1）与快盘恢复（width=2）
        Volumes.debugForceSlow = true
        open(url: jpg1)
        let d1 = Date().addingTimeInterval(3)
        while Date() < d1 && !debugShownSharp { pump(0.05) }
        check(debugShownSharp && decodeQueue.maxConcurrentOperationCount == 1,
              "slow folder sets single-lane decodeQueue (width=\(decodeQueue.maxConcurrentOperationCount))")

        // 截「设置 → 通用」（精简后）与「设置 → 看图」（滚到底部看到「外接盘加速」）实机截图
        func shootSettings(_ name: String) {
            if let sw = SettingsWindowController.shared.window,
               let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sw.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
               let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? png.write(to: shots.appendingPathComponent(name))
            }
        }
        SettingsWindowController.shared.show(.general)
        pump(0.25)
        shootSettings("settings_general_clean.png")
        SettingsWindowController.shared.show(.viewing)
        pump(0.35)
        // 滚动看图页让「外接盘加速」完全露在视口里
        func scrollToBottom(_ v: NSView) {
            if let sv = v as? NSScrollView, let doc = sv.documentView {
                doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - sv.contentView.bounds.height)))
                return
            }
            for sub in v.subviews { scrollToBottom(sub) }
        }
        if let cv = SettingsWindowController.shared.window?.contentView { scrollToBottom(cv) }
        pump(0.25)
        shootSettings("settings_viewing_extcache.png")
        SettingsWindowController.shared.window?.close()

        // 清除缓存验证归零
        var cleared = false
        ExtDiskCache.shared.clearAll { cleared = true }
        let d2 = Date().addingTimeInterval(2)
        while Date() < d2 && !cleared { pump(0.02) }
        check(cleared && ExtDiskCache.shared.diskUsageBytes() == 0, "clearAll wipes SSD cache to 0 bytes")

        Volumes.debugForceSlow = false
        open(url: jpg1)
        pump(0.2)
        check(decodeQueue.maxConcurrentOperationCount == 2,
              "fast internal folder restores concurrent decodeQueue (width=\(decodeQueue.maxConcurrentOperationCount))")

        print("EXTCACHE summary [\(lang)] checks=\(checks) failures=\(failures)")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}

import AppKit

/// `Flipic --foldersynctest <工作文件夹>`：打开的照片所在文件夹列不出内容时（桌面没获准访问、App Store 版只拿到单个文件），
/// 文件夹一有变化，正在看的照片不能被当成「不见了」拿掉、退回开始页。
/// 用权限 0311 的文件夹模拟：能按路径读文件、能往里写，但列不出目录。最后一行 FOLDERSYNC summary 是汇总
extension ViewerViewController {
    func runFolderSyncTest(outDir: String) {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print("FOLDERSYNC \(ok ? "ok  " : "FAIL") \(what)")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("locked")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        func writeJPEG(_ url: URL, _ color: NSColor) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill(); NSRect(x: 0, y: 0, width: 320, height: 240).fill()
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .jpeg, properties: [:])?.write(to: url)
        }
        let a = root.appendingPathComponent("a.jpg"), b = root.appendingPathComponent("b.jpg")
        writeJPEG(a, .systemRed)
        writeJPEG(b, .systemBlue)
        // 能进、能写、不能列
        try? fm.setAttributes([.posixPermissions: 0o311], ofItemAtPath: root.path)
        check((try? fm.contentsOfDirectory(atPath: root.path)) == nil, "模拟环境：文件夹列不出内容")

        func finish() {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            print("FOLDERSYNC summary checks=\(checks) failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        func showing(_ u: URL) -> Bool {
            folder.current?.url.lastPathComponent == u.lastPathComponent && emptyState.isHidden
        }

        open(url: a)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            check(showing(a), "打开后显示 a.jpg（count=\(folder.count)）")
            // 文件夹里来了新文件（比如桌面上新截了一张图），触发和磁盘对一遍
            writeJPEG(root.appendingPathComponent("c.jpg"), .systemGreen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                check(showing(a), "文件夹变化 4 秒后仍显示 a.jpg，没退回开始页（count=\(folder.count) empty=\(!emptyState.isHidden)）")
                // 对照：能列目录时，真删掉的照片照样拿掉
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
                try? fm.removeItem(at: a)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                    let cur = folder.current?.url.lastPathComponent ?? "-"
                    check(cur != "a.jpg" && folder.count >= 1 && emptyState.isHidden,
                          "删掉 a.jpg 后从列表拿掉、换到别的照片（当前 \(cur)，count=\(folder.count)）")
                    finish()
                }
            }
        }
    }
}

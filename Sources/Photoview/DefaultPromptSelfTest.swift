import AppKit
import UniformTypeIdentifiers

/// `Flipic --defaultprompttest <工作文件夹>`：从访达打开的照片格式不是默认用 Flipic 打开时，底部提示条的出现规则，
/// 以及 App 菜单「设为默认看图软件」和它的快捷键。不改系统默认：「是不是 Flipic 打开」「是不是在临时位置」和设置动作都换成假的。
/// 截图 bar-<语言>.png（工具条收着）、bar-toolbar-<语言>.png（工具条出来）、bar-narrow-<语言>.png（窄窗口）。最后一行 DEFAULTPROMPT summary
extension AppDelegate {
    func runDefaultPromptTest(outDir: String) {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1 }; print("DEFAULTPROMPT \(ok ? "ok  " : "FAIL") \(what)") }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("photos")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ name: String, _ type: NSBitmapImageRep.FileType, _ hue: CGFloat) -> URL {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1067, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // 上浅下深的渐变，截图里能看清提示条压在照片上的样子
            NSGradient(starting: NSColor(hue: hue, saturation: 0.35, brightness: 0.85, alpha: 1),
                       ending: NSColor(hue: hue, saturation: 0.6, brightness: 0.35, alpha: 1))?
                .draw(in: NSRect(x: 0, y: 0, width: 1600, height: 1067), angle: -90)
            NSGraphicsContext.restoreGraphicsState()
            let u = root.appendingPathComponent(name)
            try? rep.representation(using: type, properties: [:])?.write(to: u)
            return u
        }
        let a = write("a.jpg", .jpeg, 0.08), b = write("b.jpg", .jpeg, 0.55), c = write("c.png", .png, 0.33)
        _ = write("d.jpg", .jpeg, 0.75)
        let lang = (UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "x").replacingOccurrences(of: "/", with: "-")

        // 测试前的设置记下来，跑完还原
        let savedShown = DefaultPrompt.shownTypes, savedOff = DefaultPrompt.disabled
        func reset() { DefaultPrompt.shownTypes = []; DefaultPrompt.disabled = false }
        reset()
        var flipicTypes: (UTType) -> Bool = { _ in false }
        DefaultViewer.isFlipicOverride = { flipicTypes($0) }
        DefaultViewer.temporaryLocationOverride = false
        var makeCalls = 0
        DefaultViewer.makeOverride = {
            makeCalls += 1
            flipicTypes = { _ in true }
            return DefaultViewer.MakeResult(succeeded: DefaultViewer.types.count, failed: 0, firstError: nil)
        }

        func viewers() -> [ViewerViewController] {
            NSApp.windows.filter { $0.isVisible }.compactMap { $0.contentViewController as? ViewerViewController }
        }
        var v: ViewerViewController? { viewers().first }
        func shown() -> Bool { v?.debugDefaultPromptVisible ?? false }
        func closeAll() { for x in viewers() { x.view.window?.close() } }
        func open(_ u: URL) { closeAll(); self.application(NSApp, open: [u]) }
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            guard let w = v?.view.window else { return }
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            w.sendEvent(e)
        }
        func barViews() -> (bar: NSView, text: NSTextField, buttons: [NSButton])? {
            guard let bar = v?.defaultPromptBar else { return nil }
            var text: NSTextField?, buttons: [NSButton] = []
            func walk(_ x: NSView) {
                if let t = x as? NSTextField, !(x is NSButton) { text = t }
                if let b = x as? NSButton { buttons.append(b) }
                x.subviews.forEach(walk)
            }
            walk(bar)
            guard let text else { return nil }
            return (bar, text, buttons)
        }
        /// 字没被截：按现在的宽度排出来的高度放得下，按钮的字也都放得下
        func layoutReport(_ tag: String) {
            guard let v, let (bar, text, buttons) = barViews() else { check(false, "\(tag)：找不到提示条"); return }
            v.view.layoutSubtreeIfNeeded()
            let need = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.frame.width, height: 10_000)).height ?? 0
            check(need <= text.frame.height + 1, "\(tag)：文字没被截（需要高 \(Int(need))，实际 \(Int(text.frame.height))，宽 \(Int(text.frame.width))）")
            check(buttons.allSatisfy { $0.frame.width + 0.5 >= $0.fittingSize.width }, "\(tag)：按钮文字完整 \(buttons.map { "\($0.title.isEmpty ? "×" : $0.title)=\(Int($0.frame.width))" })")
            let imageFrame = v.imageView.frame
            check(imageFrame.insetBy(dx: 15, dy: 0).contains(bar.frame), "\(tag)：提示条在照片区里（bar \(NSStringFromRect(bar.frame))，照片区 \(NSStringFromRect(imageFrame))）")
            check(bar.frame.minY >= v.filmstrip.frame.maxY, "\(tag)：在缩略图栏上方（bar 底 \(Int(bar.frame.minY))，缩略图栏顶 \(Int(v.filmstrip.frame.maxY))）")
            let tb = v.toolbarForTest
            if !tb.isHidden && tb.alphaValue > 0.5 {
                check(!bar.frame.intersects(tb.frame), "\(tag)：和底部工具条不重叠（工具条 \(NSStringFromRect(tb.frame))）")
            }
            check(v.view.window?.firstResponder === v.imageView, "\(tag)：键盘焦点还在照片上")
        }

        var steps: [(Double, () -> Void)] = []
        var t = 0.0
        func at(_ dt: Double, _ f: @escaping () -> Void) { t += dt; steps.append((t, f)) }

        // 1. 不是默认：打开 JPG 出提示条，只记下这一种格式
        at(0.2) { open(a) }
        at(1.6) {
            check(shown(), "1 JPG 不是默认：出提示条")
            check(DefaultPrompt.shownTypes == ["public.jpeg"], "1 记下问过的格式 \(DefaultPrompt.shownTypes.sorted())")
            if let w = v?.view.window { w.setFrame(NSRect(x: 80, y: 80, width: 1180, height: 780), display: true) }
        }
        at(0.6) {
            layoutReport("1 普通窗口")
            v?.captureWindow(to: "\(outDir)/bar-\(lang).png", raw: true)
            v?.pokeControls()
        }
        at(0.5) {
            check(v?.shownZones.contains(.bottom) == true, "1 工具条出来了")
            layoutReport("1 工具条出来")
            v?.captureWindow(to: "\(outDir)/bar-toolbar-\(lang).png", raw: true)
            if let w = v?.view.window { w.setFrame(NSRect(x: 80, y: 80, width: 620, height: 520), display: true) }
        }
        at(0.6) {
            layoutReport("1 窄窗口")
            v?.captureWindow(to: "\(outDir)/bar-narrow-\(lang).png", raw: true)
            if let w = v?.view.window { w.setFrame(NSRect(x: 80, y: 80, width: 1180, height: 780), display: true) }
        }
        // 翻页不受影响：→ 照常翻，提示条还在，焦点还在照片上
        at(0.5) { key(String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)), 124) }
        at(0.8) {
            check(v?.folder.current?.url.lastPathComponent == "b.jpg", "1 按 → 翻到下一张：\(v?.folder.current?.url.lastPathComponent ?? "-")")
            check(shown(), "1 翻页后提示条还在")
            check(v?.view.window?.firstResponder === v?.imageView, "1 焦点还在照片上")
        }
        // 2. 贴合预览里藏起来，回来再出
        at(0.2) { v?.imageView.enterPeek() }
        at(0.8) { check(v?.imageView.isPeeking == true && !shown(), "2 贴合预览里不出") }
        at(0.1) { v?.imageView.endPeek() }
        at(0.8) { check(shown(), "2 回到普通窗口又出来") }
        // 3. 同一种格式只问一次
        at(0.2) { open(b) }
        at(1.6) { check(!shown(), "3 再打开一张 JPG：不再问") }
        // 4. 新格式问一次，× 关掉
        at(0.2) { open(c) }
        at(1.6) {
            check(shown(), "4 PNG 第一次：出提示条")
            v?.defaultPromptClose(nil)
            check(!shown(), "4 点 × 收起")
        }
        // 5. 已经是默认：不出
        at(0.2) { reset(); flipicTypes = { _ in true }; open(a) }
        at(1.6) { check(!shown(), "5 已经是默认：不出"); check(DefaultPrompt.shownTypes.isEmpty, "5 没记下格式") }
        // 6. 只有 JPG 是 Flipic 打开（别的格式不是）：打开 JPG 不出，打开 PNG 出
        at(0.2) { flipicTypes = { $0 == .jpeg }; open(a) }
        at(1.6) { check(!shown(), "6 这个格式已是 Flipic：不出") }
        at(0.2) { open(c) }
        at(1.6) { check(shown(), "6 PNG 不是：出") }
        // 7. 从磁盘映像 / 临时位置运行：什么都不出
        at(0.2) { reset(); flipicTypes = { _ in false }; DefaultViewer.temporaryLocationOverride = true; open(a) }
        at(1.6) { check(!shown(), "7 临时位置：不出") }
        // 8. 不再提示：收起，以后哪种格式都不问
        at(0.2) { reset(); DefaultViewer.temporaryLocationOverride = false; open(a) }
        at(1.6) {
            check(shown(), "8 出提示条")
            v?.defaultPromptNever(nil)
            check(!shown() && DefaultPrompt.disabled, "8 点「不再提示」：收起并关掉")
        }
        at(0.2) { DefaultPrompt.shownTypes = []; open(c) }
        at(1.6) { check(!shown(), "8 关掉以后新格式也不问") }
        // 9. 设为默认（假的设置动作）：提示条收起，短暂提示
        at(0.2) { reset(); open(a) }
        at(1.6) {
            check(shown(), "9 出提示条")
            v?.defaultPromptMake(nil)
        }
        at(0.6) {
            check(makeCalls == 1, "9 走了设置动作（\(makeCalls) 次）")
            check(!shown(), "9 设好后提示条收起")
            check(v?.debugLastFlash == L10n.t("dp.done", "以后双击照片都会用 Flipic 打开"), "9 提示「\(v?.debugLastFlash ?? "")」")
        }
        // 10. App 菜单里的「设为默认看图软件」和快捷键
        at(0.2) {
            let appMenu = NSApp.mainMenu?.items.first?.submenu
            let item = appMenu?.items.first { $0.action == #selector(AppDelegate.makeDefaultViewer(_:)) }
            check(item != nil, "10 App 菜单里有这一项：\(item?.title ?? "-")")
            check(item?.title == L10n.t("set.makeDefault", "设为默认看图软件") && item?.target === self, "10 标题和目标对")
            check(item?.keyEquivalent == "", "10 默认没有快捷键")
            let a = ShortcutAction.makeDefaultViewer
            check(a.isAvailable && a.defaultCombo == nil && Shortcuts.combo(for: a) == nil, "10 快捷键列表里有，默认不占键")
            check(ShortcutAction.Group.tools.actions.contains(a), "10 在「工具」一组里，标题「\(a.title)」")
            // 分一个带 ⌘ 的组合：挂到菜单项上
            Shortcuts.set(KeyCombo(keyCode: 2, mods: [.command, .option, .control], chars: "d"), for: a)
            check(item?.keyEquivalent == "d" && item?.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [.command, .option, .control],
                  "10 分了 ⌃⌥⌘D：菜单项上挂着 \(item?.keyEquivalent ?? "-") \(item?.keyEquivalentModifierMask.rawValue ?? 0)")
            // 分一个单键（F6）：看图界面里按下就走同一个流程
            Shortcuts.set(KeyCombo(keyCode: 97, chars: String(Character(UnicodeScalar(UInt16(NSF6FunctionKey))!))), for: a)
            check(item?.keyEquivalent == "", "10 改成单键后菜单上不挂")
        }
        at(0.2) { key(String(Character(UnicodeScalar(UInt16(NSF6FunctionKey))!)), 97) }
        at(0.6) {
            check(makeCalls == 2, "10 看图界面按 F6 走了设置动作（\(makeCalls) 次）")
            Shortcuts.set(nil, for: .makeDefaultViewer)
            check(!Shortcuts.isCustomized(.makeDefaultViewer), "10 还原成没有快捷键")
            SettingsWindowController.shared.show(.shortcuts)
        }
        // 设置 › 快捷键里这一行：滚到它，截图
        at(0.8) {
            let sw = SettingsWindowController.shared
            let rec = sw.debugRecorder(for: .makeDefaultViewer)
            check(rec != nil, "10 设置 › 快捷键里有这一行")
            sw.window?.layoutIfNeeded()
        }
        at(0.6) {
            if let w = SettingsWindowController.shared.window,
               let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber), [.bestResolution, .boundsIgnoreFraming]),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/shortcuts-\(lang).png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        at(0.3) {
            DefaultPrompt.shownTypes = savedShown
            DefaultPrompt.disabled = savedOff
            DefaultViewer.isFlipicOverride = nil
            DefaultViewer.temporaryLocationOverride = nil
            DefaultViewer.makeOverride = nil
            print("DEFAULTPROMPT summary checks=\(checks) failures=\(failures)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        for (dt, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + dt, execute: f) }
    }
}

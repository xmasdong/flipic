import AppKit
import UniformTypeIdentifiers

/// 从访达打开的照片，格式本身不是默认用 Flipic 打开（比如只对这一个文件选了「始终以此方式打开」，macOS 只记在那个文件上）：
/// 照片区底部出一条提示，问要不要让所有照片都用 Flipic 打开。每种格式每次安装最多问一次；「不再提示」以后都不问。
/// App Store 版沙盒里改不了默认打开方式，整段不编进去
enum DefaultPrompt {
    private static let shownKey = "defaultPromptShownTypes"
    private static let offKey = "defaultPromptOff"

    /// 「不再提示」
    static var disabled: Bool {
        get { UserDefaults.standard.bool(forKey: offKey) }
        set { UserDefaults.standard.set(newValue, forKey: offKey) }
    }

    /// 已经问过的格式（UTType identifier）
    static var shownTypes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: shownKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: shownKey) }
    }

    static func markShown(_ type: UTType) { shownTypes.insert(type.identifier) }

    /// 跑别的自测时不出提示条，免得截图和按键测试被它干扰
    static var suppressedByTest: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--") && $0 != "--defaultprompttest" }
    }

    static func type(of url: URL) -> UTType? {
        if let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// 这个格式算不算「照片」：在设为默认的那些格式里，或者是图片
    static func isPhotoType(_ t: UTType) -> Bool {
        DefaultViewer.types.contains { t == $0 || t.conforms(to: $0) } || t.conforms(to: .image)
    }

    /// 不管现在窗口是什么状态，这个格式该不该问
    static func shouldPrompt(for t: UTType) -> Bool {
        guard !disabled, !suppressedByTest, !DefaultViewer.isInTemporaryLocation,
              isPhotoType(t), !shownTypes.contains(t.identifier) else { return false }
        return !DefaultViewer.isFlipic(t) && !DefaultViewer.isDefault
    }
}

extension ViewerViewController {
    /// 打开了一张照片（不是文件夹）：等首图上屏后再看要不要问；打开文件夹时收起提示条
    func scheduleDefaultPrompt(for url: URL?) {
        defaultPromptWork?.cancel()
        defaultPromptWork = nil
        guard let url else {
            defaultPromptPending = nil
            removeDefaultPrompt()
            return
        }
        // 已经有一条在了（同一个窗口里又打开一张）：留着那条
        guard defaultPromptBar == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.defaultPromptWork = nil
            guard let t = DefaultPrompt.type(of: url), DefaultPrompt.shouldPrompt(for: t) else { return }
            self.defaultPromptPending = t
            self.refreshDefaultPrompt()
        }
        defaultPromptWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// 普通窗口里看单张时才出：贴合预览、放映、全屏、对比、清理模式里先藏着
    var defaultPromptAllowedNow: Bool {
        guard let w = view.window, w.isVisible, !w.styleMask.contains(.fullScreen) else { return false }
        return !isPeekingWindow && !slideshowActive && compareView == nil && cleanup == nil && folder.current != nil
    }

    /// 窗口状态变了（进出预览、放映、全屏、对比……）：提示条该藏就藏，等着的那条能出就出
    func refreshDefaultPrompt() {
        let allowed = defaultPromptAllowedNow
        if let bar = defaultPromptBar {
            if bar.isHidden == allowed {
                bar.isHidden = !allowed
                relayoutRatingBadge()
            }
            return
        }
        guard allowed, let t = defaultPromptPending else { return }
        defaultPromptPending = nil
        // 等的这段时间里可能已经在别处设好了
        guard DefaultPrompt.shouldPrompt(for: t) else { return }
        DefaultPrompt.markShown(t)
        defaultPromptType = t
        buildDefaultPromptBar()
    }

    /// 样式同顶部的新版本提示：一块 HUD 毛玻璃，一行字，两个小按钮，一个 ×。按钮不抢键盘焦点，← → 照常翻页
    private func buildDefaultPromptBar() {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.identifier = NSUserInterfaceItemIdentifier("defaultPromptBar")

        let text = NSTextField(wrappingLabelWithString: L10n.t("dp.message", "这张照片只对它自己设成了用 Flipic 打开。要让所有照片都用 Flipic 打开吗？"))
        text.font = .systemFont(ofSize: 12.5, weight: .medium)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 3
        text.isSelectable = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        func small(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.refusesFirstResponder = true
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        let make = small(L10n.t("dp.make", "设为默认"), #selector(defaultPromptMake(_:)))
        let never = small(L10n.t("dp.never", "不再提示"), #selector(defaultPromptNever(_:)))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("dp.close", "关闭"))!,
                             target: self, action: #selector(defaultPromptClose(_:)))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L10n.t("dp.close", "关闭")
        close.refusesFirstResponder = true
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [text, make, never, close])
        stack.spacing = 10
        stack.setCustomSpacing(6, after: make)
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        // 叠在照片上、底部工具条和视频条之下的层级里：放在照片区之上即可，工具条出来时它在工具条上方，不重叠
        view.addSubview(bar, positioned: .above, relativeTo: imageView)
        let maxWidth = bar.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor, constant: -32)
        maxWidth.priority = .required
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            bar.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -bottomToolbarClearance),
            maxWidth,
            // 一行放得下时就一行，不要无故折行
            text.widthAnchor.constraint(lessThanOrEqualToConstant: ceil(text.attributedStringValue.size().width) + 4),
        ])
        defaultPromptBar = bar
        view.layoutSubtreeIfNeeded()
        relayoutRatingBadge()
        if CommandLine.arguments.contains("--defaultprompttest") {
            NSLog("DEFAULTPROMPT shown type=%@", defaultPromptType?.identifier ?? "-")
        }
    }

    func removeDefaultPrompt() {
        guard let bar = defaultPromptBar else { return }
        bar.removeFromSuperview()
        defaultPromptBar = nil
        defaultPromptType = nil
        relayoutRatingBadge()
    }

    @objc func defaultPromptMake(_ sender: Any?) {
        DefaultViewer.makeInteractively(from: view.window) { [weak self] ok in
            if ok { self?.flashDefaultViewerSet() }
        }
    }

    @objc func defaultPromptNever(_ sender: Any?) {
        DefaultPrompt.disabled = true
        // 别的窗口里的也一起收起
        for w in NSApp.windows {
            (w.contentViewController as? ViewerViewController)?.removeDefaultPrompt()
        }
    }

    @objc func defaultPromptClose(_ sender: Any?) {
        removeDefaultPrompt()
    }

    /// 设好了：短暂提示一下，提示条收起
    func flashDefaultViewerSet() {
        removeDefaultPrompt()
        flash(L10n.t("dp.done", "以后双击照片都会用 Flipic 打开"), seconds: 2.5)
    }

    /// 别处（设置、菜单、另一个窗口的提示条）设好了：这个格式已经是 Flipic 打开的，就收起
    @objc func defaultViewerDidChange(_ note: Notification) {
        guard let t = defaultPromptType else { return }
        if DefaultViewer.isDefault || DefaultViewer.isFlipic(t) { removeDefaultPrompt() }
    }

    var debugDefaultPromptVisible: Bool { defaultPromptBar.map { $0.superview != nil && !$0.isHidden } ?? false }
}

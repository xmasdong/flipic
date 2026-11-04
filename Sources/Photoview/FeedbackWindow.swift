import AppKit

/// 「反馈建议」窗口：用户写一段话（可选留邮箱），发到 pay.flipic.app/feedback 存起来。
/// 只发送用户写的内容、邮箱、App 版本和系统版本，不带照片、文件路径或任何机器标识。
/// 服务器回 ok 才算发出去；没发出去时内容留着，草稿边写边存，关掉窗口也不丢
final class FeedbackWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    static let shared = FeedbackWindowController()

    /// 测试时用环境变量 FLIPIC_FEEDBACK_URL 指向本地服务器
    var endpoint = ProcessInfo.processInfo.environment["FLIPIC_FEEDBACK_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://pay.flipic.app/feedback")!

    /// 版本来源：官网下载版 / App Store 版 / 自己从开源代码编译的
    static var variant: String {
        return "opensource"
    }

    static let minLength = 5, maxLength = 5000

    /// 草稿存在 UserDefaults；测试换一组 key，不碰用户真的草稿
    private var draftKey = "feedbackDraft"
    private var contactKey = "feedbackContact"

    private let textView = NSTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let contactField = NSTextField()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton()
    private let cancelButton = NSButton()
    private let copyButton = NSButton()
    private var sending = false
    /// 测试用：每次发送结束回调（成功与否、给用户看的说明、服务器原始回应）
    var onResultForTest: ((Bool, String, String) -> Void)?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = L10n.t("feedback.title", "反馈建议")
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        restoreDraft()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 界面

    private func build() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: L10n.t("feedback.title", "反馈建议"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let leadText = L10n.t("feedback.lead", "有什么不好用、想要的功能，直接写给我们。建议一旦被采纳，送 Flipic Pro 激活码，永久有效。")
        let noteText = L10n.t("feedback.contactNote", "想领 Pro 或需要回复，留个邮箱")
        let lead = NSTextField(wrappingLabelWithString: leadText)
        lead.font = .systemFont(ofSize: 13)
        lead.textColor = .secondaryLabelColor

        // 多行输入框：NSTextView 没有占位文字，叠一个标签，有内容时藏起来
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        placeholder.stringValue = L10n.t("feedback.placeholder", "比如：哪里不好用、希望加什么功能、遇到了什么问题")
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        // 放在输入框里面（叠在滚动视图上会被内容盖住），和第一行文字对齐
        placeholder.sizeToFit()
        placeholder.frame.origin = NSPoint(x: textView.textContainerInset.width + 3, y: textView.textContainerInset.height)
        textView.addSubview(placeholder)
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        contactField.placeholderString = L10n.t("feedback.contactPlaceholder", "邮箱（选填）")
        contactField.font = .systemFont(ofSize: 13)
        contactField.delegate = self
        let contactNote = NSTextField(wrappingLabelWithString: noteText)
        contactNote.font = .systemFont(ofSize: 12)
        contactNote.textColor = .secondaryLabelColor

        let privacy = NSTextField(wrappingLabelWithString: L10n.t("feedback.privacy", "只发送你写的内容、邮箱和 App 版本、系统版本，不含照片和文件"))
        privacy.font = .systemFont(ofSize: 11.5)
        privacy.textColor = .tertiaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true   // 藏起来才不在一行里占位
        statusLabel.font = .systemFont(ofSize: 12.5)
        statusLabel.isSelectable = true
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 6

        copyButton.title = L10n.t("feedback.copy", "复制内容")
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyDraft(_:))
        copyButton.isHidden = true
        cancelButton.title = L10n.t("alert.cancel", "取消")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        sendButton.title = L10n.t("feedback.send", "发送")
        sendButton.bezelStyle = .rounded
        // 输入框里回车是换行，⌘↩ 发送
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.target = self
        sendButton.action = #selector(send(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [copyButton, spacer, cancelButton, sendButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, lead, scroll, contactField, contactNote, privacy, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: lead)
        stack.setCustomSpacing(12, after: scroll)
        stack.setCustomSpacing(4, after: contactField)
        stack.setCustomSpacing(14, after: contactNote)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        for v in [lead, scroll, contactField, contactNote, privacy, statusRow, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        updateState()
    }

    // MARK: - 草稿与校验

    private var message: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var contact: String { contactField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func restoreDraft() {
        textView.string = UserDefaults.standard.string(forKey: draftKey) ?? ""
        contactField.stringValue = UserDefaults.standard.string(forKey: contactKey) ?? ""
        updateState()
    }

    private func saveDraft() {
        let d = UserDefaults.standard
        if textView.string.isEmpty { d.removeObject(forKey: draftKey) } else { d.set(textView.string, forKey: draftKey) }
        if contact.isEmpty { d.removeObject(forKey: contactKey) } else { d.set(contact, forKey: contactKey) }
    }

    func textDidChange(_ notification: Notification) { saveDraft(); clearStatusAfterEdit(); updateState() }
    func controlTextDidChange(_ obj: Notification) { saveDraft(); clearStatusAfterEdit(); updateState() }

    /// 发送失败后用户接着改，旧的提示就收起来；成功提示留着
    private func clearStatusAfterEdit() {
        if !copyButton.isHidden { setStatus("", error: false) }
    }

    static func isValidEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@<>"',;]+@[^\s@<>"',;]+\.[^\s@<>"',;]+$"#, options: .regularExpression) != nil
    }

    private func updateState() {
        placeholder.isHidden = !textView.string.isEmpty
        let n = message.count
        sendButton.isEnabled = !sending && n >= Self.minLength && n <= Self.maxLength
        textView.isEditable = !sending
        contactField.isEnabled = !sending
        if n > Self.maxLength, !sending {
            setStatus(L10n.t("feedback.tooLong", "内容太长了，请控制在 5000 字以内"), error: true, offerCopy: false)
        }
    }

    private func setStatus(_ text: String, error: Bool, offerCopy: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemOrange : .secondaryLabelColor
        copyButton.isHidden = !offerCopy
    }

    // MARK: - 发送

    @objc private func cancel(_ sender: Any?) { window?.performClose(nil) }

    @objc private func copyDraft(_ sender: Any?) {
        var text = message
        if !contact.isEmpty { text += "\n\n" + contact }
        text += "\n\n" + Self.versionLine
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.title = L10n.t("feedback.copied", "已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = L10n.t("feedback.copy", "复制内容")
        }
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var versionLine: String { "\(AppInfo.name) \(appVersion) (\(appBuild)) · macOS \(osVersion)" }

    @objc private func send(_ sender: Any?) {
        guard !sending, sendButton.isEnabled else { return }
        if !contact.isEmpty, !Self.isValidEmail(contact) {
            setStatus(L10n.t("feedback.badEmail", "邮箱格式不对，检查一下，或者留空"), error: true)
            window?.makeFirstResponder(contactField)
            return
        }
        let body: [String: String] = [
            "message": message,
            "contact": contact,
            "app": Self.appVersion,
            "build": Self.appBuild,
            "os": Self.osVersion,
            "lang": Bundle.main.preferredLocalizations.first ?? "",
            "variant": Self.variant,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Flipic/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral   // 不存 cookie、不留缓存
        config.timeoutIntervalForRequest = 20

        sending = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        setStatus(L10n.t("feedback.sending", "正在发送…"), error: false)
        updateState()
        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let raw = "HTTP \(http?.statusCode ?? 0) " + (data.flatMap { String(data: $0, encoding: .utf8) } ?? (error.map { "\($0)" } ?? ""))
            // 只有服务器明确回了 ok:true 和编号才算发出去
            let ok = error == nil && http?.statusCode == 200 && json?["ok"] as? Bool == true && json?["id"] != nil
            DispatchQueue.main.async { self.finish(ok: ok, http: http, json: json, error: error, raw: raw) }
        }.resume()
    }

    private func finish(ok: Bool, http: HTTPURLResponse?, json: [String: Any]?, error: Error?, raw: String) {
        sending = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        let text: String
        if ok {
            text = L10n.t("feedback.sent", "已收到，谢谢")
            textView.string = ""
            saveDraft()
            setStatus(text, error: false)
        } else {
            text = Self.failureReason(http: http, code: json?["error"] as? String, error: error)
                + "\n" + L10n.t("feedback.keep", "写的内容还在，可以稍后再发，或者先复制下来。")
            setStatus(text, error: true, offerCopy: true)
        }
        updateState()
        onResultForTest?(ok, text, raw)
    }

    /// 没发出去的原因，用用户看得懂的话说
    static func failureReason(http: HTTPURLResponse?, code: String?, error: Error?) -> String {
        if let error {
            let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                            .cannotConnectToHost, .timedOut, .dnsLookupFailed, .dataNotAllowed]
            if let e = error as? URLError, offline.contains(e.code) {
                return L10n.t("feedback.errOffline", "连不上服务器，检查一下网络后再试")
            }
            return L10n.f("feedback.errOther", "没有发出去（%@）", error.localizedDescription)
        }
        let status = http?.statusCode ?? 0
        switch (status, code) {
        case (429, _): return L10n.t("feedback.errRate", "发得太频繁了，过十分钟再试")
        case (_, "message_too_short"): return L10n.t("feedback.errShort", "内容太短了，至少写 5 个字")
        case (_, "message_too_long"): return L10n.t("feedback.tooLong", "内容太长了，请控制在 5000 字以内")
        case (_, "bad_contact"): return L10n.t("feedback.badEmail", "邮箱格式不对，检查一下，或者留空")
        case (500..., _): return L10n.f("feedback.errServer", "服务器暂时出了问题（%@），稍后再试", "HTTP \(status)")
        default: return L10n.f("feedback.errOther", "没有发出去（%@）", "HTTP \(status)")
        }
    }

    // MARK: - 测试

    /// --feedbacktest <截图文件夹>：截空窗口、填好的窗口，向 FLIPIC_FEEDBACK_URL 发一条，
    /// 再向连不上的地址发一条看失败提示。草稿用单独的 key，不动用户自己的
    func runTest(outDir: String, then done: @escaping () -> Void) {
        // 没指定测试服务器就不跑，免得测试消息发进正式后台
        guard ProcessInfo.processInfo.environment["FLIPIC_FEEDBACK_URL"] != nil else {
            NSLog("FEEDBACK refused: set FLIPIC_FEEDBACK_URL to a test server")
            done()
            return
        }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        draftKey = "feedbackDraft.test"
        contactKey = "feedbackContact.test"
        UserDefaults.standard.removeObject(forKey: draftKey)
        UserDefaults.standard.removeObject(forKey: contactKey)
        restoreDraft()
        setStatus("", error: false)
        show()
        func shot(_ name: String) {
            guard let w = window, let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], CGWindowID(w.windowNumber),
                                                                 [.bestResolution, .boundsIgnoreFraming]),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL,
                                                             "public.png" as CFString, 1, nil) else { NSLog("FEEDBACK shot %@ failed", name); return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        func fill() {
            textView.string = "缩略图条能不能调高一点？现在照片多的时候看不清。\n另外希望能按拍摄时间分组。"
            contactField.stringValue = "tester@example.com"
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
        let good = endpoint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            NSLog("FEEDBACK empty sendEnabled=%d variant=%@ endpoint=%@", sendButton.isEnabled ? 1 : 0, Self.variant, good.absoluteString)
            shot("1-empty")
            textView.string = "好用"
            textDidChange(Notification(name: NSText.didChangeNotification))
            NSLog("FEEDBACK 2 chars sendEnabled=%d", sendButton.isEnabled ? 1 : 0)
            fill()
            NSLog("FEEDBACK filled sendEnabled=%d draftSaved=%d", sendButton.isEnabled ? 1 : 0,
                  UserDefaults.standard.string(forKey: draftKey) == textView.string ? 1 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                shot("2-filled")
                onResultForTest = { [self] ok, text, raw in
                    NSLog("FEEDBACK submit ok=%d shown=%@ server=%@ draftCleared=%d", ok ? 1 : 0, text, raw,
                          UserDefaults.standard.string(forKey: draftKey) == nil ? 1 : 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                        shot("3-success")
                        // 失败：端口 9 上没有服务，连接会被拒绝
                        endpoint = URL(string: "http://127.0.0.1:9/feedback")!
                        fill()
                        onResultForTest = { [self] ok, text, raw in
                            NSLog("FEEDBACK unreachable ok=%d shown=%@ server=%@ textKept=%d copyVisible=%d", ok ? 1 : 0,
                                  text.replacingOccurrences(of: "\n", with: " / "), raw, message.isEmpty ? 0 : 1, copyButton.isHidden ? 0 : 1)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                                shot("4-error")
                                onResultForTest = nil
                                endpoint = good
                                UserDefaults.standard.removeObject(forKey: draftKey)
                                UserDefaults.standard.removeObject(forKey: contactKey)
                                done()
                            }
                        }
                        send(nil)
                    }
                }
                send(nil)
            }
        }
    }
}

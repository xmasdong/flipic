import AppKit
import Security

/// 点「立即更新」后在 App 里完成更新：下载安装包 → 校验签名与公证 → 替换自己 → 重新打开。
/// 新包必须和正在运行的 Flipic 是同一个开发者团队签的名、并且通过 Apple 公证，任何一步不对就停下，
/// 退回到打开浏览器下载。团队 ID 运行时从自己的签名里读，不写进源码
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    enum Failure: Error {
        case notSigned, translocated, notWritable(String), download(String), mount, signature, notNewer, install(String)

        var message: String {
            switch self {
            case .notSigned: return L10n.t("update.errNotSigned", "这份 Flipic 不是官方签名的安装包，无法自动更新。")
            case .translocated: return L10n.t("update.errTranslocated", "Flipic 现在是从「下载」等临时位置运行的。先把它拖进「应用程序」，再检查更新。")
            case .notWritable(let dir): return L10n.f("update.errWrite", "没有权限写入「%@」。", dir)
            case .download(let why): return L10n.f("update.errDownload", "下载没有完成：%@", why)
            case .mount: return L10n.t("update.errMount", "打不开下载的安装包。")
            case .signature: return L10n.t("update.errSignature", "下载的安装包签名或公证校验没有通过，已经停止安装。")
            case .notNewer: return L10n.t("update.errNotNewer", "下载的安装包不比现在的版本新。")
            case .install(let why): return L10n.f("update.errInstall", "替换旧版本时出错：%@", why)
            }
        }
    }

    private var release: UpdateChecker.Release?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var window: UpdateProgressWindow?
    private var workDir: URL?

    /// 测试用：跳过公证检查之外的部分不变，只把「重新打开」换成回调
    var onFinishedForTest: ((Result<URL, Failure>) -> Void)?

    // MARK: - 入口

    func install(_ release: UpdateChecker.Release) {
        guard self.release == nil else { window?.makeKeyAndOrderFront(nil); return }
        do {
            try preflight()
        } catch let f as Failure {
            fail(f, release: release)
            return
        } catch {}
        self.release = release
        let w = UpdateProgressWindow(version: release.version) { [weak self] in self?.cancel() }
        window = w
        if onFinishedForTest == nil { w.show() }
        startDownload(release.download)
    }

    /// 动手前先确认：自己是官方签名的、不在临时位置运行、所在文件夹能写
    private func preflight() throws {
        guard Self.teamID(of: Bundle.main.bundleURL) != nil else { throw Failure.notSigned }
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") { throw Failure.translocated }
        let dir = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dir.path),
              FileManager.default.isWritableFile(atPath: app.path) else { throw Failure.notWritable(dir.path) }
    }

    // MARK: - 下载

    private func startDownload(_ url: URL) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flipic/Update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.downloadTask(with: url)
        task?.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        window?.progress(done: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dir = workDir else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(.download("HTTP \(http.statusCode)"))
            return
        }
        let dmg = dir.appendingPathComponent("Flipic.dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dmg)
        } catch {
            fail(.download(error.localizedDescription))
            return
        }
        window?.status(L10n.t("update.verifying", "正在校验签名和公证…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.verifyAndInstall(dmg: dmg, in: dir) ?? .failure(.install("-"))
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        fail(.download(error.localizedDescription))
    }

    private func cancel() {
        task?.cancel()
        cleanup()
    }

    // MARK: - 校验与安装（后台线程）

    /// 新版本的 bundle id 和现在一样，或者换成了 app.flipic. 开头的新名字（App 的身份名要从旧的换成新主体的命名）。
    /// 后面照样要求同一个开发团队签名、通过公证，所以别人的包换个名字也装不进来
    static func acceptsIdentity(_ newID: String, current: String) -> Bool {
        newID == current || newID.hasPrefix("app.flipic.")
    }

    private func verifyAndInstall(dmg: URL, in dir: URL) -> Result<URL, Failure> {
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) == 0 else {
            return .failure(.mount)
        }
        defer { _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let found = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else { return .failure(.mount) }
        // 先拷到本机，校验的是将要装上去的那一份
        let staged = dir.appendingPathComponent("Flipic.app")
        try? FileManager.default.removeItem(at: staged)
        guard Self.run("/usr/bin/ditto", [found.path, staged.path]) == 0 else { return .failure(.install("ditto")) }

        guard let newBundle = Bundle(url: staged), let newID = newBundle.bundleIdentifier,
              Self.acceptsIdentity(newID, current: Bundle.main.bundleIdentifier ?? "") else { return .failure(.signature) }
        let newVersion = newBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard UpdateChecker.isNewer(newVersion, than: UpdateChecker.currentVersion) else { return .failure(.notNewer) }
        guard let team = Self.teamID(of: Bundle.main.bundleURL),
              Self.validate(staged, bundleID: newBundle.bundleIdentifier ?? "", team: team),
              Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path]) == 0 else { return .failure(.signature) }

        DispatchQueue.main.async { [weak self] in self?.window?.status(L10n.t("update.installing", "正在安装…")) }
        // 替换：旧版本挪到缓存目录，新版本放到原来的位置。原来叫 Flipic.app 或 Flipic Lens.app 就保持原名，
        // 不顺手改名：改了名 Dock 里固定的图标会跟着旧文件走，点开的还是旧版本；别的名字（Flipic 2.app 之类）统一成 Flipic Lens.app
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        let keepName = ["Flipic.app", "Flipic Lens.app"].contains(current.lastPathComponent)
        let target = parent.appendingPathComponent(keepName ? current.lastPathComponent : "Flipic Lens.app")
        let backup = dir.appendingPathComponent("Previous.app")
        do {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: current, to: backup)
            if target != current, FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
            do {
                try FileManager.default.moveItem(at: staged, to: target)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: current)   // 放回旧版本
                throw error
            }
        } catch {
            return .failure(.install(error.localizedDescription))
        }
        return .success(target)
    }

    private func finish(_ result: Result<URL, Failure>) {
        if let hook = onFinishedForTest {
            hook(result)
            cleanup(keepFiles: true)
            return
        }
        switch result {
        case .failure(let f):
            fail(f)
        case .success(let app):
            window?.status(L10n.t("update.relaunching", "安装完成，正在重新打开…"))
            relaunch(app)
        }
    }

    /// 等自己退出后再打开新版本，并清掉下载的安装包和挪走的旧版本
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"; /bin/rm -rf \"$2\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", app.path, workDir?.path ?? "/nonexistent-flipic-update"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    private func fail(_ f: Failure, release: UpdateChecker.Release? = nil) {
        let rel = release ?? self.release
        if let hook = onFinishedForTest { hook(.failure(f)); cleanup(); return }
        cleanup()
        let alert = NSAlert()
        alert.messageText = L10n.t("update.failedTitle", "没能自动更新")
        alert.informativeText = f.message
        alert.addButton(withTitle: L10n.t("update.useBrowser", "用浏览器下载"))
        alert.addButton(withTitle: L10n.t("update.later", "以后再说"))
        if alert.runModal() == .alertFirstButtonReturn, let url = rel?.download ?? Optional(UpdateChecker.fallbackDownload) {
            NSWorkspace.shared.open(url)
        }
    }

    private func cleanup(keepFiles: Bool = false) {
        session?.invalidateAndCancel()
        session = nil
        task = nil
        window?.close()
        window = nil
        release = nil
        if !keepFiles, let dir = workDir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - 签名

    /// App 签名里的开发者团队 ID；本机临时签名（开发版、自己编译的）没有
    static func teamID(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 签名完整、由 Apple 签发的开发者证书、团队和 bundle id 都对得上
    static func validate(_ app: URL, bundleID: String, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// 更新进度：和看图窗口一样的深色小窗，显示进度条、当前步骤和取消按钮
final class UpdateProgressWindow: NSWindow {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let onCancel: () -> Void

    init(version: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 132), styleMask: [.titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = Theme.gray(dark: 0.11, light: 0.95)
        isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: L10n.f("update.title", "正在更新到 Flipic %@", version))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.stringValue = L10n.t("update.starting", "正在连接…")
        let cancel = NSButton(title: L10n.t("update.cancel", "取消"), target: nil, action: nil)
        cancel.bezelStyle = .rounded
        let row = NSStackView(views: [label, cancel])
        row.distribution = .fill
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, bar, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView = NSView()
        contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            row.widthAnchor.constraint(equalTo: bar.widthAnchor),
        ])
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        center()
    }

    func show() { makeKeyAndOrderFront(nil) }

    @objc private func cancelClicked() { onCancel() }

    func progress(done: Int64, total: Int64) {
        guard total > 0 else { return }
        bar.isIndeterminate = false
        bar.doubleValue = Double(done) / Double(total)
        let f = ByteCountFormatter()
        f.countStyle = .file
        label.stringValue = L10n.f("update.downloading", "正在下载 %@ / %@", f.string(fromByteCount: done), f.string(fromByteCount: total))
    }

    func status(_ text: String) {
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        label.stringValue = text
    }
}

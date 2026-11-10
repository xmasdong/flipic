import AppKit
import AVFoundation

/// 文件夹里的视频：只认系统自己能播的 MP4 / MOV / M4V，用 AVFoundation 播放，不带任何解码库。
/// 实况照片配套的同名 MOV 不单独显示
enum Video {
    static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isVideo(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func isVideoName(_ name: String) -> Bool { extensions.contains((name as NSString).pathExtension.lowercased()) }

    /// 设置里「在文件夹里显示视频」，默认开
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showVideos") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showVideos") }
    }

    struct Meta {
        let size: CGSize
        let duration: Double
        let playable: Bool
    }

    private static var metas: [URL: Meta] = [:]
    private static let lock = NSLock()

    static func cachedMeta(_ url: URL) -> Meta? {
        lock.lock(); defer { lock.unlock() }
        return metas[url]
    }

    static func forget(_ url: URL) {
        lock.lock(); metas[url] = nil; lock.unlock()
    }

    /// 画面尺寸（按拍摄方向转正）、时长、这台 Mac 能不能播。会读文件头，别在主线程调
    static func meta(_ url: URL) -> Meta? {
        if let hit = cachedMeta(url) { return hit }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let r = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let m = Meta(size: CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded()),
                     duration: asset.duration.seconds.isFinite ? asset.duration.seconds : 0,
                     playable: asset.isPlayable && track.isPlayable)
        lock.lock(); metas[url] = m; lock.unlock()
        return m
    }

    /// 第一帧（按拍摄方向转正）；maxPixel 为 nil 时原尺寸。会解码，别在主线程调
    static func poster(_ url: URL, maxPixel: CGFloat?) -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        if let maxPixel { gen.maximumSize = CGSize(width: maxPixel, height: maxPixel) }
        // 第一帧常是全黑，往后取一点；短视频取不到就回到开头
        for t in [0.1, 0] {
            if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) { return img }
        }
        return nil
    }

    /// 文件名列表里去掉实况照片配套的 MOV（同名的 HEIC / JPG 在，这个 MOV 就跟着照片走）
    static func dropLiveCompanions(_ urls: [URL]) -> [URL] {
        let stills = Set(urls.filter { ["heic", "heif", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().path.lowercased() })
        return urls.filter { !($0.pathExtension.lowercased() == "mov" && stills.contains($0.deletingPathExtension().path.lowercased())) }
    }

    static func timeText(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// 看视频时屏幕底部的细控制条：播放 / 暂停、进度（可拖）、时间、静音。画面放在照片图层里，缩放和平移跟照片一样
final class VideoBar: NSVisualEffectView {
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onMute: (() -> Void)?

    private let playButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let muteButton = NSButton()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        for b in [playButton, muteButton] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.contentTintColor = .labelColor
            b.target = self
            b.refusesFirstResponder = true
        }
        playButton.action = #selector(togglePressed)
        muteButton.action = #selector(mutePressed)
        playButton.toolTip = L10n.t("video.playTip", "播放 / 暂停（回车）")
        muteButton.toolTip = L10n.t("video.muteTip", "静音")
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [playButton, slider, timeLabel, muteButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(equalToConstant: 420),
            playButton.widthAnchor.constraint(equalToConstant: 22),
            muteButton.widthAnchor.constraint(equalToConstant: 22),
        ])
        update(time: 0, duration: 0, playing: false, muted: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var dragging = false

    func update(time: Double, duration: Double, playing: Bool, muted: Bool) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        muteButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
        if !dragging { slider.doubleValue = duration > 0 ? time / duration : 0 }
        timeLabel.stringValue = Video.timeText(time) + " / " + Video.timeText(duration)
    }

    @objc private func togglePressed() { onToggle?() }
    @objc private func mutePressed() { onMute?() }

    @objc private func sliderMoved() {
        let type = NSApp.currentEvent?.type
        dragging = type == .leftMouseDragged || type == .leftMouseDown
        onSeek?(slider.doubleValue)
        if type == .leftMouseUp { dragging = false }
    }
}

/// 看图窗口里当前这段视频：翻到视频时先挂上暂停的播放器（画面是第一帧，不自动播），回车播放 / 暂停。
/// 画面图层放进照片图层里，缩放、平移和照片一样；翻走、进对比或清理时拆掉
final class VideoPlayback {
    private weak var imageView: ZoomableImageView?
    let bar = VideoBar()
    private(set) var url: URL?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var atEnd = false
    /// 这台 Mac 播放不了：提示一次，回车也只是再提示
    private(set) var unplayable = false
    var onMessage: ((String) -> Void)?
    /// 挂上或拆掉播放器、开始或停止播放：看图界面据此换工具栏、收放缩略图栏
    var onActiveChange: (() -> Void)?

    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "videoMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "videoMuted") }
    }

    init(imageView: ZoomableImageView) {
        self.imageView = imageView
        bar.isHidden = true
        bar.onToggle = { [weak self] in self?.toggle() }
        bar.onSeek = { [weak self] f in self?.seek(fraction: f) }
        bar.onMute = { [weak self] in self?.toggleMute() }
    }

    var isActive: Bool { player != nil }
    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    /// 换到 url：是视频就挂上播放器，不是就拆掉
    func show(_ url: URL?) {
        guard url != self.url else { return }
        // 视频翻到视频：中间不通知，缩略图栏和工具栏不来回闪
        let next = url.flatMap { Video.isVideo($0) ? $0 : nil }
        clear(notify: next == nil)
        guard let url = next else { return }
        self.url = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let meta = Video.meta(url)
            DispatchQueue.main.async { self?.attach(url, meta: meta) }
        }
    }

    private func attach(_ url: URL, meta: Video.Meta?) {
        guard self.url == url, player == nil else { return }
        guard let meta, meta.playable else {
            unplayable = true
            onActiveChange?()
            onMessage?(L10n.t("video.unplayable", "这台 Mac 播放不了这个视频，可以在访达里用别的软件打开"))
            return
        }
        let p = AVPlayer(url: url)
        p.isMuted = Self.muted
        p.actionAtItemEnd = .pause
        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspect
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull()]
        imageView?.setOverlayLayer(layer)
        player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.refresh()
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            self?.atEnd = true
            self?.refresh()
            self?.onActiveChange?()
        }
        onActiveChange?()
        refresh()
    }

    func clear(notify: Bool = true) {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        url = nil
        atEnd = false
        unplayable = false
        imageView?.setOverlayLayer(nil)
        bar.isHidden = true
        if notify { onActiveChange?() }
    }

    func toggle() {
        guard let p = player else {
            if unplayable { onMessage?(L10n.t("video.unplayable", "这台 Mac 播放不了这个视频，可以在访达里用别的软件打开")) }
            return
        }
        if isPlaying {
            p.pause()
        } else {
            if atEnd { p.seek(to: .zero) }
            atEnd = false
            p.play()
        }
        refresh()
        onActiveChange?()
    }

    func pause() { player?.pause(); refresh(); onActiveChange?() }

    func seek(by seconds: Double) {
        guard let p = player else { return }
        let d = p.currentItem?.duration.seconds ?? 0
        var t = p.currentTime().seconds + seconds
        if d.isFinite, d > 0 { t = min(t, d) }
        atEnd = false
        p.seek(to: CMTime(seconds: max(t, 0), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        refresh()
    }

    private func seek(fraction: Double) {
        guard let p = player, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        atEnd = false
        p.seek(to: CMTime(seconds: d * fraction, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        refresh()
    }

    private func toggleMute() {
        Self.muted.toggle()
        player?.isMuted = Self.muted
        refresh()
    }

    private func refresh() {
        guard let p = player else { return }
        let d = p.currentItem?.duration.seconds ?? 0
        bar.update(time: p.currentTime().seconds, duration: d.isFinite ? d : 0, playing: isPlaying, muted: p.isMuted)
    }

    /// 测试用：当前播放位置（秒）
    var debugTime: Double { player?.currentTime().seconds ?? -1 }
}

/// 信息面板（I）里的视频信息：从文件头读，不解码画面。别在主线程调
enum VideoInfo {
    static func read(url: URL) -> [ExifEntry] {
        let asset = AVURLAsset(url: url)
        var out: [ExifEntry] = []
        func add(_ key: String, _ zh: String, _ v: String?) {
            if let v, !v.isEmpty { out.append(ExifEntry(label: L10n.t(key, zh), value: v)) }
        }
        let meta = asset.commonMetadata + asset.metadata
        func string(_ ids: [String]) -> String? {
            for id in ids {
                if let item = meta.first(where: { $0.identifier?.rawValue == id || ($0.key as? String) == id }),
                   let s = item.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
            }
            return nil
        }

        // 设备：手机和不少相机写 QuickTime 的 make / model
        let make = string(["mdta/com.apple.quicktime.make", "com.apple.quicktime.make"])
        let model = string(["mdta/com.apple.quicktime.model", "com.apple.quicktime.model"])
        if let model {
            add("exif.camera", "相机", (make.map { model.hasPrefix($0) } ?? false) ? model : [make, model].compactMap { $0 }.joined(separator: " "))
        }
        if let date = asset.creationDate?.dateValue {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            add("exif.date", "拍摄时间", f.string(from: date))
        }
        let d = asset.duration.seconds
        if d.isFinite, d > 0 { add("video.duration", "时长", Video.timeText(d)) }

        if let v = asset.tracks(withMediaType: .video).first {
            let r = CGRect(origin: .zero, size: v.naturalSize).applying(v.preferredTransform)
            let w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
            var res = "\(w) × \(h)"
            if let label = resolutionLabel(w, h) { res += " · " + label }
            add("exif.size", "尺寸", res)
            if v.nominalFrameRate > 0 { add("video.fps", "帧率", fpsText(Double(v.nominalFrameRate))) }
            if let fd = (v.formatDescriptions as? [CMFormatDescription])?.first {
                var parts = [codecName(CMFormatDescriptionGetMediaSubType(fd))]
                let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
                if let bits = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int, bits > 8 { parts.append(L10n.f("exif.bits", "%d 位", bits)) }
                let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { parts.append("HDR (PQ)") }
                else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { parts.append("HDR (HLG)") }
                add("video.codec", "视频编码", parts.joined(separator: " · "))
            }
            if v.estimatedDataRate > 0 { add("video.bitrate", "码率", String(format: "%.1f Mbps", Double(v.estimatedDataRate) / 1_000_000)) }
        }
        if let a = asset.tracks(withMediaType: .audio).first,
           let fd = (a.formatDescriptions as? [CMFormatDescription])?.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            var parts = [codecName(CMFormatDescriptionGetMediaSubType(fd))]
            if asbd.mSampleRate > 0 { parts.append(String(format: "%.1f kHz", asbd.mSampleRate / 1000)) }
            if asbd.mChannelsPerFrame == 1 { parts.append(L10n.t("video.mono", "单声道")) }
            else if asbd.mChannelsPerFrame == 2 { parts.append(L10n.t("video.stereo", "立体声")) }
            else if asbd.mChannelsPerFrame > 2 { parts.append(L10n.f("video.channels", "%d 声道", Int(asbd.mChannelsPerFrame))) }
            add("video.audio", "音频", parts.joined(separator: " · "))
        } else {
            add("video.audio", "音频", L10n.t("video.noAudio", "无"))
        }
        if let iso = string(["mdta/com.apple.quicktime.location.ISO6709", "com.apple.quicktime.location.ISO6709"]),
           let entry = location(iso) { out.append(entry) }
        if let sw = string(["mdta/com.apple.quicktime.software", "com.apple.quicktime.software"]) { add("exif.software", "软件", sw) }
        if let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
            out.append(ExifEntry(label: L10n.t("exif.file", "文件"),
                                 value: url.lastPathComponent + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        return out
    }

    private static func resolutionLabel(_ w: Int, _ h: Int) -> String? {
        let short = min(w, h), long = max(w, h)
        if long >= 7600 { return "8K" }
        if long >= 3800 || short >= 2100 { return "4K" }
        if short >= 1440 { return "1440p" }
        if short >= 1080 { return "1080p" }
        if short >= 720 { return "720p" }
        return nil
    }

    private static func fpsText(_ f: Double) -> String {
        // 29.97、59.94 这类按两位小数，整数帧率不带小数
        abs(f - f.rounded()) < 0.01 ? String(format: "%.0f fps", f) : String(format: "%.2f fps", f)
    }

    private static func codecName(_ t: FourCharCode) -> String {
        let s = String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        switch s {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC (H.265)"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes 422 Proxy"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        case "mp4v": return "MPEG-4"
        case "jpeg": return "Motion JPEG"
        case "aac ": return "AAC"
        case "lpcm", "sowt", "twos", "in24", "in32": return "PCM"
        case "alac": return "ALAC"
        case "ac-3": return "AC-3"
        case ".mp3": return "MP3"
        default: return s.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    /// ISO 6709：+24.4797+118.0819+012.000/
    private static func location(_ iso: String) -> ExifEntry? {
        // 按正负号切开：每段是一个数
        var nums: [Double] = []
        var cur = ""
        for ch in iso {
            if ch == "+" || ch == "-" || ch == "/" {
                if let v = Double(cur) { nums.append(v) }
                cur = ch == "/" ? "" : String(ch)
            } else { cur.append(ch) }
        }
        if let v = Double(cur) { nums.append(v) }
        guard nums.count >= 2, abs(nums[0]) <= 90, abs(nums[1]) <= 180, !(nums[0] == 0 && nums[1] == 0) else { return nil }
        let lat = nums[0], lon = nums[1]
        var text = String(format: "%.5f° %@, %.5f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
        if nums.count >= 3 { text += String(format: " · %.0f m", nums[2]) }
        let link = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=%.6f,%.6f", lat, lon, lat, lon))
        return ExifEntry(label: L10n.t("exif.location", "拍摄地点"), value: text, link: link)
    }
}

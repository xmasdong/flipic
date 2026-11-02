import AppKit
import AVFoundation
import PhotosUI

/// 实况照片在硬盘上是一对文件：一张 HEIC / JPG，加一个同名的 .MOV（iPhone 隔空投送、「图像捕捉」导入、
/// 「照片」导出未修改的原件都是这样）。MOV 里带 Apple 的 content identifier 才算实况，避免把恰好同名的普通视频当成实况
enum LivePhoto {
    private static let stillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
    private static var verified: [URL: Bool] = [:]

    /// 同名的 .mov（不管验证没验证）；复制、移动、删除、重命名时跟照片一起走，不让一对实况被拆开
    static func movie(for photo: URL) -> URL? {
        guard stillExtensions.contains(photo.pathExtension.lowercased()) else { return nil }
        let base = photo.deletingPathExtension()
        for ext in ["MOV", "mov"] {
            let u = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: u.path) {
                // 大小写不敏感的磁盘上两种写法都「存在」，用真实文件名
                let name = (try? u.resourceValues(forKeys: [.nameKey]))?.name ?? u.lastPathComponent
                return base.deletingLastPathComponent().appendingPathComponent(name)
            }
        }
        return nil
    }

    /// 同名 .mov 带实况标记时回调它，否则回调 nil；结果按文件缓存，回调在主线程
    static func check(_ photo: URL, done: @escaping (URL?) -> Void) {
        guard let mov = movie(for: photo) else { done(nil); return }
        if let known = verified[mov] { done(known ? mov : nil); return }
        Task {
            let items = (try? await AVURLAsset(url: mov).load(.metadata)) ?? []
            let live = items.contains { ($0.identifier?.rawValue ?? "").hasSuffix("content.identifier") }
            await MainActor.run {
                verified[mov] = live
                done(live ? mov : nil)
            }
        }
    }

    /// 读成系统的实况照片对象；会先给一个低清的再给完整的，只回调完整的，失败回调 nil
    static func load(photo: URL, movie: URL, targetSize: CGSize, done: @escaping (PHLivePhoto?) -> Void) {
        PHLivePhoto.request(withResourceFileURLs: [photo, movie], placeholderImage: nil,
                            targetSize: targetSize, contentMode: .aspectFit) { live, info in
            if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
            DispatchQueue.main.async { done(info[PHLivePhotoInfoErrorKey] == nil ? live : nil) }
        }
    }
}

/// 左上角文件名下面的「实况」标签：鼠标移上去播放、移开停，点一下也播放，和「照片」App 一样
final class LiveBadge: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "livephoto", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: L10n.t("live.badge", "实况"))
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        toolTip = L10n.t("tip.live", "实况照片：鼠标移上来播放")
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

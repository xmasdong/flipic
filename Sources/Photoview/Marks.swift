import Foundation

/// 挑片标记：「这张我要」。存成访达标签「Flipic」（跟随软件名，绿色），不改照片文件本身，
/// RAW、PSD 等任何格式都能标；在访达侧边栏点这个标签就能看到所有标记过的照片，换软件也不丢
enum Marks {
    /// 改名为 Flipic Lens 后标签名仍是「Flipic」，老用户打过的标记照样认得；App Store 版用自己的名字
    static let tagName = AppInfo.name.hasPrefix(AppInfo.defaultName) ? AppInfo.defaultName : AppInfo.name
    /// 访达标签颜色序号：1 灰 2 绿 3 紫 4 蓝 5 黄 6 红 7 橙
    private static let colorIndex = 2
    private static let attr = "com.apple.metadata:_kMDItemUserTags"

    /// 列目录时顺带取回的标签名里有没有它
    static func isMarked(tagNames: [String]?) -> Bool {
        tagNames?.contains(tagName) ?? false
    }

    /// 单个文件有没有标记：访达标签，或者（在存储卡上时）这台电脑记着的标记
    static func isMarked(_ url: URL) -> Bool {
        isMarked(tagNames: (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames) || CardMarks.isStoreMarked(url)
    }

    enum Result { case ok, readOnly, failed }

    /// 加上或去掉标记；成功返回 true
    @discardableResult
    static func set(_ on: Bool, for url: URL) -> Bool { setResult(on, for: url) == .ok }

    /// 同 set，失败时说明是不是因为卷只读。
    /// 存储卡（Volumes.keepsMarksOffVolume）上标记记在这台电脑里，不往卡里写；卡上老版本打的访达标签照样认，
    /// 取消这种标记要改卡上的文件：可写就去掉标签，只读就做不到
    static func setResult(_ on: Bool, for url: URL) -> Result {
        guard let vol = CardMarks.appSideVolume(for: url) else { return setTag(on, for: url) ? .ok : .failed }
        CardMarks.set(on, for: url)
        if !on, isMarked(tagNames: (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames) {
            if vol.readOnly { return .readOnly }
            return setTag(false, for: url) ? .ok : .failed
        }
        return .ok
    }

    /// 加上或去掉访达标签，保留文件原有的其他标签；成功返回 true
    private static func setTag(_ on: Bool, for url: URL) -> Bool {
        var tags = readTags(url)
        // 标签存成「名称\n颜色序号」，没有颜色时只有名称
        tags.removeAll { $0 == tagName || $0.hasPrefix(tagName + "\n") }
        if on { tags.append("\(tagName)\n\(colorIndex)") }
        guard writeTags(tags, to: url) else { return false }
        return isMarked(fresh(url)) == on
    }

    /// resourceValues 会缓存，写完要用新的 URL 对象读回来确认
    private static func fresh(_ url: URL) -> URL { URL(fileURLWithPath: url.path) }

    /// 颜色标签（Tags.swift）读写同一个属性，所以不是 private
    static func readTags(_ url: URL) -> [String] {
        let size = getxattr(url.path, attr, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let n = data.withUnsafeMutableBytes { getxattr(url.path, attr, $0.baseAddress, size, 0, 0) }
        guard n == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list
    }

    static func writeTags(_ tags: [String], to url: URL) -> Bool {
        if tags.isEmpty {
            let r = removexattr(url.path, attr, 0)
            return r == 0 || errno == ENOATTR
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) else { return false }
        return data.withUnsafeBytes { setxattr(url.path, attr, $0.baseAddress, data.count, 0, 0) } == 0
    }
}

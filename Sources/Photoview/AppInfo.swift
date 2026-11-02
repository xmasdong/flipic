import Foundation

/// 软件名，由 Info.plist 的 CFBundleName 决定
enum AppInfo {
    static let defaultName = "Flipic"
    static let name: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? defaultName

    /// 文案里写的都是 Flipic，打包时改了名字就在显示时换掉
    static func branded(_ text: String) -> String {
        name == defaultName ? text : text.replacingOccurrences(of: defaultName, with: name)
    }
}

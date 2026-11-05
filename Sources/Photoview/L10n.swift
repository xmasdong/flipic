import Foundation

/// 轻量本地化：key 是稳定标识，fallback 是简体中文；
/// Resources/<lang>.lproj/Localizable.strings 由 build.sh 拷进 App Bundle
enum L10n {
    static func t(_ key: String, _ fallback: String) -> String {
        AppInfo.branded(NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: ""))
    }

    /// 只有部分语言才有的文字（比如中文界面的微信号）；没翻译时系统会返回 key 本身，这里换成 nil
    static func optional(_ key: String) -> String? {
        let s = NSLocalizedString(key, tableName: nil, bundle: .main, value: "", comment: "")
        return s.isEmpty || s == key ? nil : s
    }

    static func f(_ key: String, _ fallback: String, _ args: CVarArg...) -> String {
        String(format: t(key, fallback), arguments: args)
    }
}

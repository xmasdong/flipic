import Foundation

/// 轻量本地化：key 是稳定标识，fallback 是简体中文；
/// Resources/<lang>.lproj/Localizable.strings 由 build.sh 拷进 App Bundle
enum L10n {
    static func t(_ key: String, _ fallback: String) -> String {
        AppInfo.branded(NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: ""))
    }

    static func f(_ key: String, _ fallback: String, _ args: CVarArg...) -> String {
        String(format: t(key, fallback), arguments: args)
    }
}

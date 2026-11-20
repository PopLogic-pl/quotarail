import Foundation

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let value = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? value : String(format: value, locale: appLocale, arguments: arguments)
}

let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
}

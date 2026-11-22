import Foundation

/// UI language. English is the default; Simplified Chinese is used when the system prefers Chinese.
/// Override with `--lang en|zh` on the command line or `defaults write <bundle id> lang zh`.
enum Lang: String {
    case en, zh

    static var current: Lang = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--lang"), i + 1 < args.count, let l = Lang(rawValue: args[i + 1]) { return l }
        if let s = UserDefaults.standard.string(forKey: "lang"), let l = Lang(rawValue: s) { return l }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
    }()
}

/// Picks the string for the current UI language. Both variants live at the call site so they stay in sync.
func L(_ zh: @autoclosure () -> String, _ en: @autoclosure () -> String) -> String {
    Lang.current == .zh ? zh() : en()
}

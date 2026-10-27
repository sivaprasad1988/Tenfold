import AppKit

// MARK: - App language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en, fr, de, es
    case ptBR = "pt-BR"
    case it, ja, nl, ko, pl
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    /// Shown in its own language (never translated).
    var nativeName: String {
        switch self {
        case .system: return L("System")
        case .en: return "English"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .nl: return "Nederlands"
        case .ko: return "한국어"
        case .pl: return "Polski"
        case .zhHans: return "简体中文"
        }
    }
}

enum Localization {
    static let languageKey = "app.language"
    static let promptedKey = "app.languagePrompted"

    /// The user's choice (takes effect after relaunch).
    static var selected: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            applyAppleLanguages(newValue)
        }
    }

    /// Language code used by this run of the app (fixed at launch).
    static let current: String = resolve()

    /// Call once at launch, before any UI: makes system parts (permission dialogs, formatters) follow the choice.
    static func applyAtLaunch() {
        applyAppleLanguages(selected)
    }

    private static func applyAppleLanguages(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    private static func resolve() -> String { resolvedCode(for: selected) }

    /// Language code a choice resolves to (System → first supported preferred language).
    static func resolvedCode(for choice: AppLanguage) -> String {
        if choice != .system { return choice.rawValue }
        // System: first preferred language we support. Read the global list so an old app-level
        // AppleLanguages override cannot win.
        let global = UserDefaults(suiteName: UserDefaults.globalDomain)?.stringArray(forKey: "AppleLanguages")
        for code in global ?? Locale.preferredLanguages {
            let lower = code.lowercased()
            if lower.hasPrefix("pt") { return "pt-BR" }
            if lower.hasPrefix("zh") { return "zh-Hans" }
            let base = String(lower.prefix(2))
            if let match = AppLanguage(rawValue: base), match != .system { return match.rawValue }
        }
        return "en"
    }

    /// Quits and starts Tenfold again (new language applies on launch).
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Localized string for an English key (falls back to English).
func L(_ key: String) -> String {
    guard Localization.current != "en",
          let index = Translations.columns.firstIndex(of: Localization.current),
          let row = Translations.table[key], index < row.count else { return key }
    return row[index]
}

/// Localized format string with arguments, e.g. LF("Updated %@", time).
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

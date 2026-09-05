import Foundation

public enum AppLanguage: String, CaseIterable {
    case system = "system"
    case english = "en"
    case chinese = "zh-Hans"
}

public final class LanguagePreferences {
    private let defaults: UserDefaults
    private let key = "appLanguage"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var selection: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: key) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    public func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        selection == .system ? Self.resolveSystemLanguage(preferredLanguages) : selection
    }

    static func resolveSystemLanguage(_ preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            case "zh": return .chinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
}

public enum L10n {
    // Packaged apps must use their own resources after being moved to another Mac.
    // The SwiftPM bundle accessor is a fallback for development and test executables.
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ZebTrace_ZebTraceCore.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    /// Resolve the preference for each lookup so a menu selection takes effect immediately.
    public static func string(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, language: LanguagePreferences().resolvedLanguage(), arguments: arguments)
    }

    /// Explicit language selection is useful for isolated tests and non-UI consumers.
    public static func string(_ key: String, language: AppLanguage, arguments: [CVarArg] = []) -> String {
        let resolved = language == .system
            ? LanguagePreferences.resolveSystemLanguage(Locale.preferredLanguages) : language
        let localized = localizedBundle(for: resolved)
        let format = localized.localizedString(forKey: key, value: nil, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: resolved.rawValue), arguments: arguments)
    }

    static func localizedBundle(for language: AppLanguage) -> Bundle {
        // SwiftPM can normalize locale directory names (zh-Hans -> zh-hans).
        // Try both spellings so packaged resources also work on case-sensitive volumes.
        for identifier in [language.rawValue, language.rawValue.lowercased()] {
            if let url = resourceBundle.url(forResource: identifier, withExtension: "lproj"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        if let url = resourceBundle.url(forResource: AppLanguage.english.rawValue, withExtension: "lproj"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return resourceBundle
    }
}

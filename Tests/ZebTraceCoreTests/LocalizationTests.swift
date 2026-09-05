import Foundation
import XCTest
@testable import ZebTraceCore

final class LocalizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        defaultsSuite = "org.zebtrace.tests.localization.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    override func tearDownWithError() throws {
        if let defaultsSuite { defaults?.removePersistentDomain(forName: defaultsSuite) }
        defaults = nil
        defaultsSuite = nil
    }

    func testDefaultAndUnrecognizedSelectionsFollowSystem() {
        let preferences = LanguagePreferences(defaults: defaults)
        XCTAssertEqual(preferences.selection, .system)
        defaults.set("unsupported-language", forKey: "appLanguage")
        XCTAssertEqual(preferences.selection, .system)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-CN"]), .chinese)
    }

    func testFirstSupportedSystemLanguageWins() {
        let preferences = LanguagePreferences(defaults: defaults)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["fr-FR", "zh-CN", "en-US"]), .chinese)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["ja-JP", "en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["en-US", "zh-CN"]), .english)
    }

    func testChineseRegionalAndScriptVariantsResolveToChinese() {
        let preferences = LanguagePreferences(defaults: defaults)
        for identifier in ["zh", "zh-CN", "zh-SG", "zh-TW", "zh-HK", "zh-Hans", "zh-Hant-HK", "ZH_tw"] {
            XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: [identifier]), .chinese, identifier)
        }
    }

    func testUnsupportedSystemLanguagesFallBackToEnglish() {
        let preferences = LanguagePreferences(defaults: defaults)
        for identifiers in [[], ["fr-FR", "ja-JP"], ["zhfoo", "english", ""]] {
            XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: identifiers), .english)
        }
    }

    func testExplicitSelectionOverridesSystemLanguages() {
        let preferences = LanguagePreferences(defaults: defaults)
        preferences.selection = .english
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["zh-CN"]), .english)
        preferences.selection = .chinese
        XCTAssertEqual(preferences.resolvedLanguage(preferredLanguages: ["en-US"]), .chinese)
    }

    func testEverySelectionPersistsAndExistingInstancesSeeChanges() throws {
        let preferences = LanguagePreferences(defaults: defaults)
        for language in AppLanguage.allCases {
            preferences.selection = language
            let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
            let reloaded = LanguagePreferences(defaults: reloadedDefaults)
            XCTAssertEqual(reloaded.selection, language)
        }
        let other = LanguagePreferences(defaults: defaults)
        other.selection = .english
        XCTAssertEqual(preferences.selection, .english)
        other.selection = .chinese
        XCTAssertEqual(preferences.selection, .chinese)
    }

    func testExplicitLookupsCanSwitchLanguagesWithoutCachedText() {
        XCTAssertEqual(L10n.string("menu.start", language: .english), "Start Recording")
        XCTAssertEqual(L10n.string("menu.start", language: .chinese), "开始记录")
        XCTAssertEqual(L10n.string("menu.start", language: .english), "Start Recording")
        XCTAssertEqual(L10n.string("a.missing.localization.key", language: .english), "a.missing.localization.key")
    }

    func testFormattedValuesAndMinutePluralization() {
        XCTAssertEqual(L10n.string("duration.minute", language: .english, arguments: [1]), "1 minute")
        XCTAssertEqual(L10n.string("duration.minutes", language: .english, arguments: [10]), "10 minutes")
        XCTAssertEqual(L10n.string("duration.minute", language: .chinese, arguments: [1]), "1 分钟")
        XCTAssertEqual(L10n.string("duration.minutes", language: .chinese, arguments: [10]), "10 分钟")
        XCTAssertEqual(L10n.string("status.recording", language: .english, arguments: ["01:02:03"]),
                       "ZebTrace · Recording 01:02:03")
        XCTAssertEqual(L10n.string("menu.location", language: .chinese, arguments: ["/tmp/100% meeting"]),
                       "保存位置：/tmp/100% meeting")
        XCTAssertEqual(L10n.string("capture.error.operationFailed", language: .english,
                                   arguments: ["Read audio device", Int32(-50)]),
                       "Read audio device failed (Core Audio status -50).")
    }

    func testBothLanguagesContainMatchingNonemptyKeysAndFormatSpecifiers() throws {
        let english = try translations(for: .english)
        let chinese = try translations(for: .chinese)
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, englishValue) in english {
            let chineseValue = try XCTUnwrap(chinese[key], "Missing Chinese translation: \(key)")
            XCTAssertFalse(englishValue.isEmpty, key)
            XCTAssertFalse(chineseValue.isEmpty, key)
            XCTAssertEqual(try formatSpecifiers(in: englishValue), try formatSpecifiers(in: chineseValue), key)
        }
    }

    private func translations(for language: AppLanguage) throws -> [String: String] {
        let bundle = L10n.localizedBundle(for: language)
        XCTAssertEqual(bundle.bundleURL.lastPathComponent.lowercased(), "\(language.rawValue.lowercased()).lproj")
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                                                                    options: [], format: nil) as? [String: String])
    }

    private func formatSpecifiers(in value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hlLqztj])?[@diuoxXfFeEgGaAcCsSp%]"#)
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
            .filter { $0 != "%%" }
    }
}

import Foundation
import XCTest
@testable import DevWatchCore

final class LocalizationTests: XCTestCase {
    private func bundle(_ language: String) throws -> Bundle {
        let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: language, withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(try bundle(language).url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testBothLanguagesHaveCompleteMatchingFormatArguments() throws {
        let english = try strings("en")
        let german = try strings("de")
        XCTAssertGreaterThan(english.count, 100)
        XCTAssertEqual(Set(english.keys), Set(german.keys))
        for (key, value) in english {
            XCTAssertEqual(value, key)
            let translated = try XCTUnwrap(german[key])
            XCTAssertFalse(translated.isEmpty)
            XCTAssertEqual(value.components(separatedBy: "%@").count,
                           translated.components(separatedBy: "%@").count, key)
        }
    }

    func testEnglishAndGermanLabelsAndDynamicErrors() throws {
        for (language, start, message) in [
            ("en", "Start", "The script lint no longer exists."),
            ("de", "Starten", "Das Script lint ist nicht mehr vorhanden.")
        ] {
            let selected = try bundle(language)
            XCTAssertEqual(L10n.text("Start", arguments: [], bundle: selected), start)
            XCTAssertEqual(L10n.text("The script %@ no longer exists.", arguments: ["lint"], bundle: selected), message)
            XCTAssertEqual(L10n.text("An untranslated English fallback", arguments: [], bundle: selected), "An untranslated English fallback")
            XCTAssertTrue(L10n.text("Last change: %@", arguments: ["100%/日本語.swift"], bundle: selected).hasSuffix("100%/日本語.swift"))
        }
    }

    func testBundleDeclaresEnglishFallbackAndGerman() {
        XCTAssertEqual(L10n.resourceBundle.developmentLocalization, "en")
        XCTAssertTrue(L10n.resourceBundle.localizations.contains("de"))
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "de"], forPreferences: ["de-AT"]).first, "de")
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "de"], forPreferences: ["en-GB"]).first, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "de"], forPreferences: ["fr"]).first, "en")
    }

    @MainActor
    func testWarningPresentationDoesNotDependOnTranslatedText() {
        let automation = ProjectAutomation(project: DevProject(directoryPath: "/missing")) { _ in true }
        automation.pause(reason: "An error without German keywords")
        XCTAssertTrue(automation.needsAttention)
        automation.pause()
        XCTAssertFalse(automation.needsAttention)
        XCTAssertEqual(automation.status, L10n.text("Autostart paused"))
    }
}

import Foundation
import XCTest
@testable import BalaganCore

final class ReaderAppearanceTests: XCTestCase {
    func testDefaultsWhenUnset() {
        let settings = UIAppearanceSettings()
        XCTAssertEqual(settings.effectiveReaderFontSize, UIAppearanceSettings.defaultReaderFontSize)
        XCTAssertEqual(settings.effectiveReaderTheme, .dark)
    }

    func testReaderFontSizeClamps() {
        XCTAssertEqual(UIAppearanceSettings(readerFontSize: 5).effectiveReaderFontSize, 11)
        XCTAssertEqual(UIAppearanceSettings(readerFontSize: 99).effectiveReaderFontSize, 24)
    }

    func testCodableRoundTripKeepsReaderPreferences() throws {
        let settings = UIAppearanceSettings(uiScale: 1.1, readerFontSize: 18, readerTheme: .sepia)
        let decoded = try JSONDecoder().decode(
            UIAppearanceSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.effectiveReaderTheme, .sepia)
        XCTAssertEqual(decoded.effectiveReaderFontSize, 18)
    }

    func testDecodesOlderSettingsWithoutReaderKeys() throws {
        let legacy = Data(#"{"uiScale": 1.2}"#.utf8)
        let decoded = try JSONDecoder().decode(UIAppearanceSettings.self, from: legacy)
        XCTAssertNil(decoded.readerFontSize)
        XCTAssertNil(decoded.readerTheme)
        XCTAssertEqual(decoded.effectiveReaderTheme, .dark)
    }
}

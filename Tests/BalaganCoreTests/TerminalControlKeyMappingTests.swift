import XCTest
@testable import BalaganCore

final class TerminalControlKeyMappingTests: XCTestCase {
    func testControlLettersMapToAsciiControlCharacters() {
        XCTAssertEqual(controlCharacter("a"), "\u{01}")
        XCTAssertEqual(controlCharacter("c"), "\u{03}")
        XCTAssertEqual(controlCharacter("d"), "\u{04}")
        XCTAssertEqual(controlCharacter("z"), "\u{1a}")
    }

    func testControlLettersExposeUnmodifiedTextForGhosttyKeyEncoding() {
        XCTAssertEqual(mapping("d", keyCode: 2).controlKeyText, "d")
        XCTAssertEqual(mapping("D", keyCode: 2).controlKeyText, "d")
        XCTAssertEqual(mapping("\u{04}", keyCode: 2).controlKeyText, "d")
    }

    func testShiftedControlLettersUseSameControlCharacters() {
        XCTAssertEqual(controlCharacter("C"), "\u{03}")
        XCTAssertEqual(controlCharacter("D"), "\u{04}")
    }

    func testControlLettersFallbackToVirtualKeyCodeWhenCharactersAreMissing() {
        XCTAssertEqual(mapping(nil, keyCode: 8).controlCharacter, "\u{03}")
        XCTAssertEqual(mapping(nil, keyCode: 2).controlCharacter, "\u{04}")
    }

    func testControlLettersFallbackToVirtualKeyCodeWhenCharactersAreControlScalars() {
        XCTAssertEqual(mapping("\u{03}", keyCode: 8).controlCharacter, "\u{03}")
        XCTAssertEqual(mapping("\u{04}", keyCode: 2).controlCharacter, "\u{04}")
    }

    func testCommandAndOptionChordsDoNotUseControlCharacterFallback() {
        XCTAssertNil(mapping("c", hasCommandModifier: true).controlCharacter)
        XCTAssertNil(mapping("c", hasOptionModifier: true).controlCharacter)
    }

    func testNonControlAndNonLettersDoNotMap() {
        XCTAssertNil(mapping("c", hasControlModifier: false).controlCharacter)
        XCTAssertNil(controlCharacter("1"))
        XCTAssertNil(controlCharacter("["))
        XCTAssertNil(mapping(nil, keyCode: 18).controlCharacter)
    }

    private func controlCharacter(_ charactersIgnoringModifiers: String?) -> String? {
        mapping(charactersIgnoringModifiers).controlCharacter
    }

    private func mapping(
        _ charactersIgnoringModifiers: String?,
        keyCode: UInt16 = 0,
        hasControlModifier: Bool = true,
        hasCommandModifier: Bool = false,
        hasOptionModifier: Bool = false
    ) -> TerminalControlKeyMapping {
        TerminalControlKeyMapping(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            hasControlModifier: hasControlModifier,
            hasCommandModifier: hasCommandModifier,
            hasOptionModifier: hasOptionModifier
        )
    }
}

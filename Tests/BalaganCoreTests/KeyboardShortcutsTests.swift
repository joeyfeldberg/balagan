import XCTest
@testable import BalaganCore

final class KeyboardShortcutsTests: XCTestCase {
    func testDisplayStringUsesAppleModifierOrderAndGlyphs() {
        XCTAssertEqual(KeyChord(key: "p", modifiers: [.command, .shift]).displayString, "⇧⌘P")
        XCTAssertEqual(KeyChord(key: "arrowLeft", modifiers: [.command, .option]).displayString, "⌥⌘←")
        XCTAssertEqual(KeyChord(key: "t", modifiers: [.command]).displayString, "⌘T")
        // Full order is ⌃⌥⇧⌘.
        XCTAssertEqual(
            KeyChord(key: "k", modifiers: [.control, .option, .shift, .command]).displayString,
            "⌃⌥⇧⌘K"
        )
    }

    func testValidityRequiresACommandModifier() {
        XCTAssertTrue(KeyChord(key: "t", modifiers: [.command]).isValid)
        XCTAssertTrue(KeyChord(key: "t", modifiers: [.control]).isValid)
        XCTAssertTrue(KeyChord(key: "t", modifiers: [.option]).isValid)
        XCTAssertFalse(KeyChord(key: "t", modifiers: []).isValid)
        XCTAssertFalse(KeyChord(key: "t", modifiers: [.shift]).isValid)
    }

    func testEveryActionHasAUniqueDefaultChord() {
        let chords = ShortcutAction.allCases.map(\.defaultChord)
        XCTAssertEqual(Set(chords).count, chords.count, "Default shortcuts must not collide")
        for chord in chords {
            XCTAssertTrue(chord.isValid, "Default \(chord.displayString) should be a valid binding")
        }
    }

    func testChordFallsBackToDefaultWithoutOverride() {
        let settings = KeyboardShortcutSettings()
        XCTAssertEqual(settings.chord(for: .newTab), ShortcutAction.newTab.defaultChord)
        XCTAssertFalse(settings.isCustomized(.newTab))
    }

    func testSetChordStoresOverrideAndTracksCustomization() {
        var settings = KeyboardShortcutSettings()
        let chord = KeyChord(key: "n", modifiers: [.command, .control])
        settings.setChord(chord, for: .newTab)
        XCTAssertEqual(settings.chord(for: .newTab), chord)
        XCTAssertTrue(settings.isCustomized(.newTab))
    }

    func testSettingDefaultChordClearsTheOverride() {
        var settings = KeyboardShortcutSettings()
        settings.setChord(KeyChord(key: "n", modifiers: [.command]), for: .newTab)
        XCTAssertTrue(settings.isCustomized(.newTab))
        settings.setChord(ShortcutAction.newTab.defaultChord, for: .newTab)
        XCTAssertFalse(settings.isCustomized(.newTab))
        XCTAssertTrue(settings.overrides.isEmpty)
    }

    func testResetAndResetAll() {
        var settings = KeyboardShortcutSettings()
        settings.setChord(KeyChord(key: "n", modifiers: [.command]), for: .newTab)
        settings.setChord(KeyChord(key: "m", modifiers: [.command]), for: .splitRight)
        settings.reset(.newTab)
        XCTAssertFalse(settings.isCustomized(.newTab))
        XCTAssertTrue(settings.isCustomized(.splitRight))
        settings.resetAll()
        XCTAssertTrue(settings.overrides.isEmpty)
    }

    func testConflictDetection() {
        var settings = KeyboardShortcutSettings()
        // Rebind newTab onto splitRight's default (⌘D).
        settings.setChord(ShortcutAction.splitRight.defaultChord, for: .newTab)
        let chord = settings.chord(for: .newTab)
        XCTAssertEqual(settings.action(boundTo: chord, excluding: .newTab), .splitRight)
        XCTAssertNil(settings.action(boundTo: KeyChord(key: "z", modifiers: [.command, .control])))
    }

    func testSettingsCodableRoundTrip() throws {
        var settings = KeyboardShortcutSettings()
        settings.setChord(KeyChord(key: "n", modifiers: [.command, .control]), for: .newTab)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(KeyboardShortcutSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.chord(for: .newTab), KeyChord(key: "n", modifiers: [.command, .control]))
    }

    func testPersistedUIStateDecodesWithoutShortcutsKey() throws {
        // A board saved before this feature has no keyboardShortcuts key — it must default cleanly.
        let json = #"{"terminalAppearance":{"fontSize":13}}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(PersistedUIState.self, from: json)
        XCTAssertEqual(state.keyboardShortcuts, KeyboardShortcutSettings())
    }

    func testPersistedUIStateRoundTripsShortcuts() throws {
        var shortcuts = KeyboardShortcutSettings()
        shortcuts.setChord(KeyChord(key: "j", modifiers: [.command, .option]), for: .nextTab)
        let state = PersistedUIState(keyboardShortcuts: shortcuts)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedUIState.self, from: data)
        XCTAssertEqual(decoded.keyboardShortcuts, shortcuts)
    }
}

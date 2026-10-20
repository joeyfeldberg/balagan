import XCTest
@testable import BalaganCore

final class AppThemeTests: XCTestCase {
    func testCatalogStartsWithTheDefaultAndHasUniqueIDs() {
        XCTAssertEqual(AppThemes.all.first, AppThemes.balagan)
        XCTAssertEqual(Set(AppThemes.all.map(\.id)).count, AppThemes.all.count)
        XCTAssertGreaterThanOrEqual(AppThemes.all.filter { $0.isDark == false }.count, 5, "a real choice of light themes")
    }

    func testUnknownOrMissingIDFallsBackToTheDefault() {
        XCTAssertEqual(AppThemes.named(nil), AppThemes.balagan)
        XCTAssertEqual(AppThemes.named("no-such-theme"), AppThemes.balagan)
        XCTAssertEqual(AppThemes.named("dracula").name, "Dracula")
    }

    func testTheDefaultIsTodaysLookAndKeepsTheUsersTerminalColors() {
        let palette = AppThemes.balagan.palette
        XCTAssertEqual(palette.window, ThemeColor(hex: "16171A"))
        XCTAssertEqual(palette.surfaceRaised, ThemeColor(hex: "26282E"))
        XCTAssertEqual(palette.textSecondary, ThemeColor.white.withAlpha(0.56))
        XCTAssertNil(palette.accent)
        XCTAssertNil(AppThemes.balagan.ghosttyTheme)
        XCTAssertTrue(AppThemes.balagan.isDark)
    }

    func testDerivedDarkPaletteSitsOnTheTerminalBackgroundAndStepsUp() {
        let theme = AppThemes.named("catppuccin-mocha")
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.palette.window, ThemeColor(hex: "1e1e2e"), "the window matches the terminal background")
        XCTAssertLessThan(theme.palette.window.luminance, theme.palette.surface.luminance)
        XCTAssertLessThan(theme.palette.surface.luminance, theme.palette.surfaceRaised.luminance)
        XCTAssertEqual(theme.ghosttyTheme, "Catppuccin Mocha")
    }

    func testDerivedLightPalettePutsCardsAboveColumns() {
        let theme = AppThemes.named("catppuccin-latte")
        XCTAssertFalse(theme.isDark)
        XCTAssertGreaterThan(theme.palette.surfaceRaised.luminance, theme.palette.surface.luminance)
        XCTAssertLessThan(theme.palette.surface.luminance, theme.palette.window.luminance)
        XCTAssertLessThan(theme.palette.textPrimary.luminance, 0.2, "dark text on a light theme")
    }

    func testHexParsingAndMixing() {
        XCTAssertEqual(ThemeColor(hex: "#ff0000"), ThemeColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(ThemeColor(hex: "zz"), ThemeColor(hex: "808080"))
        let mid = ThemeColor(red: 0, green: 0, blue: 0).mixed(with: .white, 0.5)
        XCTAssertEqual(mid.red, 0.5, accuracy: 0.0001)
    }
}

final class GhosttyThemeOverrideTests: XCTestCase {
    func testATerminalThemeAddsAThemeLineAfterShellIntegration() {
        XCTAssertEqual(
            GhosttyConfigOverrides.lines(userShell: "/bin/zsh", userConfigText: "", terminalTheme: "Catppuccin Mocha"),
            ["shell-integration = zsh", "theme = Catppuccin Mocha"]
        )
        XCTAssertEqual(
            GhosttyConfigOverrides.lines(userShell: "/bin/bash", userConfigText: "", terminalTheme: "Nord"),
            ["theme = Nord"],
            "the theme applies even when shell integration isn't forced"
        )
    }

    func testNoTerminalThemeLeavesTheUsersColors() {
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/bash", userConfigText: "", terminalTheme: nil), [])
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/bash", userConfigText: "", terminalTheme: "  "), [])
    }
}

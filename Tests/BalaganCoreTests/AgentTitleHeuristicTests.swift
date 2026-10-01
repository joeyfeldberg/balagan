import XCTest
@testable import BalaganCore

final class AgentTitleHeuristicTests: XCTestCase {
    func testIsWorkingDetectsALeadingBrailleSpinner() {
        // Codex (and pre-2.1.228 Claude Code) animate Braille.
        XCTAssertTrue(AgentTitleHeuristic.isWorking(title: "⠋ my-project · topic"))
        XCTAssertTrue(AgentTitleHeuristic.isWorking(title: "  ⠹ working"))
        XCTAssertFalse(AgentTitleHeuristic.isWorking(title: "my-project · topic"))
        XCTAssertFalse(AgentTitleHeuristic.isWorking(title: ""))
        XCTAssertFalse(AgentTitleHeuristic.isWorking(title: "~/repo"))
    }

    func testIsWorkingDetectsClaudeCodeHalfCircleSpinner() {
        // Claude Code ≥ 2.1.228 animates ◐◑◒◓ instead of Braille — matching Braille alone made
        // `isWorking` permanently false for current Claude, which left the whole reconciler inert.
        for glyph in ["◐", "◑", "◒", "◓"] {
            XCTAssertTrue(AgentTitleHeuristic.isWorking(title: "\(glyph) Bash command execution"),
                          "\(glyph) must read as working")
        }
        XCTAssertTrue(AgentTitleHeuristic.isWorking(title: "  ◒  Editing files"))
    }

    func testAsteriskTitleIsNotWorking() {
        // Claude's not-working title is "✳ <summary>" — same shape, no spinner.
        XCTAssertFalse(AgentTitleHeuristic.isWorking(title: "✳ Bash command execution"))
        XCTAssertFalse(AgentTitleHeuristic.isWorking(title: "  ✳ Waiting on you"))
    }

    func testStrippingSpinnerRemovesLeadingSpinnerAndSurroundingSpaces() {
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner("⠋ my-project · topic"), "my-project · topic")
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner("  ⠹  working"), "working")
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner("◐ Bash command execution"), "Bash command execution")
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner("  ◓  Editing files"), "Editing files")
    }

    func testStrippingSpinnerLeavesASpinnerlessTitleUntouched() {
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner("my-project"), "my-project")
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner(" plain"), " plain")
        // The idle marker is part of the label, not a spinner: keep it (the tab shouldn't churn).
        XCTAssertEqual(AgentTitleHeuristic.strippingSpinner("✳ Bash command execution"),
                       "✳ Bash command execution")
    }

    // MARK: - classify (the three-state read Codex's lifecycle is derived from)

    func testClassifyReadsALeadingSpinnerAsWorking() {
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "⠋ codex"), .working)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "  ⠹ Working (12s)"), .working)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "◐ Bash command execution"), .working)
    }

    func testClassifyReadsActionRequiredAsBlocked() {
        // Codex names its "waiting on you" state in the title — the only agent that does.
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "Action Required · codex"), .blocked)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "codex — Action Required"), .blocked)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "action required: approve shell command"), .blocked)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "ACTION REQUIRED"), .blocked)
    }

    func testClassifyReadsAnyOtherNonBlankTitleAsIdle() {
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "codex"), .idle)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "~/repo"), .idle)
        // Claude's settled title, and a shell prompt title.
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "✳ Bash command execution"), .idle)
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "joey@host:~/repo"), .idle)
    }

    func testClassifyReturnsNilForNoTitle() {
        // A surface that hasn't set a title yet says nothing — it must not read as idle.
        XCTAssertNil(AgentTitleHeuristic.classify(title: nil))
        XCTAssertNil(AgentTitleHeuristic.classify(title: ""))
        XCTAssertNil(AgentTitleHeuristic.classify(title: "   \n"))
    }

    func testSpinnerWinsOverALeftoverActionRequired() {
        // Precedence: an animating agent is working even if the previous prompt's text lingers.
        XCTAssertEqual(AgentTitleHeuristic.classify(title: "⠧ Action Required · codex"), .working)
    }
}

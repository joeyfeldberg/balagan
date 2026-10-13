import XCTest
@testable import BalaganCore

final class TabTitleTests: XCTestCase {
    private let task = "CQ gate: hold size rule when category detection fails (PR #4462)"

    func testATitleThatRepeatsTheTaskShowsTheAgent() {
        XCTAssertEqual(TabTitle.display(title: task, taskTitle: task, agentName: "Claude"), "Claude")
        XCTAssertEqual(TabTitle.display(title: "✳ \(task.lowercased())", taskTitle: task, agentName: "Codex"), "Codex")
        XCTAssertEqual(TabTitle.display(title: "◐ \(task)", taskTitle: task, agentName: nil), "Terminal")
    }

    func testOtherTitlesAreKept() {
        XCTAssertEqual(TabTitle.display(title: "✳ Keep size rule on timeout", taskTitle: task, agentName: "Claude"), "✳ Keep size rule on timeout")
        XCTAssertEqual(TabTitle.display(title: "zsh", taskTitle: task, agentName: nil), "zsh")
    }

    func testABlankTitleShowsTheAgentOrTerminal() {
        XCTAssertEqual(TabTitle.display(title: "  ", taskTitle: task, agentName: "pi"), "pi")
        XCTAssertEqual(TabTitle.display(title: "", taskTitle: task, agentName: nil), "Terminal")
    }

    func testAgentNameDropsCode() {
        XCTAssertEqual(TabTitle.agentName("Claude Code"), "Claude")
        XCTAssertEqual(TabTitle.agentName("OpenCode"), "OpenCode")
        XCTAssertNil(TabTitle.agentName(nil))
    }
}

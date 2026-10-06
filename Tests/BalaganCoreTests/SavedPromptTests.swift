import XCTest
@testable import BalaganCore

final class SavedPromptTests: XCTestCase {
    func testAProjectsPromptsComeFirstAndReplaceAGlobalWithTheSameTitle() {
        let global = [
            SavedPrompt(id: "g1", title: "Write tests", text: "global tests"),
            SavedPrompt(id: "g2", title: "Commit", text: "commit"),
            SavedPrompt(id: "g3", title: "", text: "half-written"),
        ]
        let project = [
            SavedPrompt(id: "p1", title: "write TESTS", text: "use pytest -x"),
            SavedPrompt(id: "p2", title: "Deploy preview", text: "make preview"),
        ]
        let merged = SavedPrompts.forTask(project: project, global: global)
        XCTAssertEqual(merged.map(\.id), ["p1", "p2", "g2"])
    }

    func testStorageRoundTripsAndNeverSavedMeansDefaults() {
        XCTAssertEqual(SavedPrompts.decode(nil), SavedPrompts.defaults)
        XCTAssertEqual(SavedPrompts.decode(SavedPrompts.encode([])), [])
        let custom = [SavedPrompt(id: "x", title: "T", text: "body")]
        XCTAssertEqual(SavedPrompts.decode(SavedPrompts.encode(custom)), custom)
    }

    func testOlderProjectsWithoutPromptsStillDecode() throws {
        let json = #"{"id":"p","name":"P","repoPath":"/r"}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.savedPrompts, [])
    }

    func testTheCLIParsesSendAndPrompt() {
        guard case .invocation(let send) = ControlCLI.parse(["send", "my-task", "run", "the", "tests"]) else { return XCTFail() }
        XCTAssertEqual(send.request.method, "task.send")
        XCTAssertEqual(send.request.params["text"], "run the tests")
        guard case .invocation(let prompt) = ControlCLI.parse(["prompt", "my-task", "Write", "tests"]) else { return XCTFail() }
        XCTAssertEqual(prompt.request.method, "task.prompt")
        XCTAssertEqual(prompt.request.params["title"], "Write tests")
        guard case .error = ControlCLI.parse(["send", "my-task"]) else { return XCTFail("text is required") }
    }
}

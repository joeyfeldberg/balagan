import XCTest
@testable import BalaganCore

final class ControlProtocolTests: XCTestCase {
    // MARK: - Socket path resolution

    func testDefaultPathFallsBackToHome() {
        let path = ControlSocket.defaultPath(environment: [:], homeDirectory: "/Users/test")
        XCTAssertEqual(path, "/Users/test/.balagan/control.sock")
    }

    func testDefaultPathHonorsEnvironmentOverride() {
        let path = ControlSocket.defaultPath(
            environment: [ControlSocket.environmentKey: "/tmp/custom.sock"],
            homeDirectory: "/Users/test"
        )
        XCTAssertEqual(path, "/tmp/custom.sock")
    }

    func testDefaultPathIgnoresBlankOverride() {
        let path = ControlSocket.defaultPath(
            environment: [ControlSocket.environmentKey: "   "],
            homeDirectory: "/Users/test"
        )
        XCTAssertEqual(path, "/Users/test/.balagan/control.sock")
    }

    // MARK: - Wire round-trip

    func testRequestEncodesAsSingleNewlineTerminatedLine() throws {
        let request = ControlRequest(method: "tasks", params: ["project": "acme"])
        let data = try ControlWire.encodeRequestLine(request)
        XCTAssertEqual(data.last, 0x0a)
        let withoutNewline = String(decoding: data.dropLast(), as: UTF8.self)
        XCTAssertFalse(withoutNewline.contains("\n"))
        let decoded = ControlWire.decodeRequestLine(withoutNewline)
        XCTAssertEqual(decoded, request)
    }

    func testDecodeMalformedLineReturnsNil() {
        XCTAssertNil(ControlWire.decodeRequestLine("not json"))
        XCTAssertNil(ControlWire.decodeRequestLine(""))
    }

    // MARK: - CLI parsing

    private func invocation(_ args: [String]) -> ControlInvocation? {
        if case let .invocation(value) = ControlCLI.parse(args) { return value }
        return nil
    }

    private func errorMessage(_ args: [String]) -> String? {
        if case let .error(message) = ControlCLI.parse(args) { return message }
        return nil
    }

    func testParseSimpleCommands() {
        XCTAssertEqual(invocation(["ping"])?.request, ControlRequest(method: "ping"))
        XCTAssertEqual(invocation(["status"])?.request, ControlRequest(method: "status"))
        XCTAssertEqual(invocation(["projects"])?.request, ControlRequest(method: "projects"))
    }

    func testParseTasksWithProjectFilter() {
        XCTAssertEqual(invocation(["tasks"])?.request, ControlRequest(method: "tasks"))
        XCTAssertEqual(
            invocation(["tasks", "--project", "acme"])?.request,
            ControlRequest(method: "tasks", params: ["project": "acme"])
        )
    }

    func testParseCreateMapsFlags() {
        let request = invocation([
            "create", "--project", "acme", "--title", "Fix bug",
            "--branch", "fix/bug", "--notes", "details", "--status", "doing", "--priority", "high",
        ])?.request
        XCTAssertEqual(request?.method, "task.create")
        XCTAssertEqual(request?.params["project"], "acme")
        XCTAssertEqual(request?.params["title"], "Fix bug")
        XCTAssertEqual(request?.params["branch"], "fix/bug")
        XCTAssertEqual(request?.params["notes"], "details")
        XCTAssertEqual(request?.params["status"], "doing")
        XCTAssertEqual(request?.params["priority"], "high")
    }

    func testParseCreateRequiresProjectAndTitle() {
        XCTAssertNotNil(errorMessage(["create", "--title", "x"]))
        XCTAssertNotNil(errorMessage(["create", "--project", "acme"]))
    }

    func testParseOpenAcceptsPositionalOrFlag() {
        XCTAssertEqual(
            invocation(["open", "my-task"])?.request,
            ControlRequest(method: "task.open", params: ["id": "my-task"])
        )
        XCTAssertEqual(
            invocation(["open", "--id", "my-task"])?.request,
            ControlRequest(method: "task.open", params: ["id": "my-task"])
        )
        XCTAssertNotNil(errorMessage(["open"]))
    }

    func testParseState() {
        XCTAssertEqual(
            invocation(["state", "my-task"])?.request,
            ControlRequest(method: "task.state", params: ["id": "my-task"])
        )
        XCTAssertNotNil(errorMessage(["state"]))
    }

    func testParseWait() {
        XCTAssertEqual(
            invocation(["wait", "my-task"])?.request,
            ControlRequest(method: "task.wait", params: ["id": "my-task"])
        )
        XCTAssertEqual(
            invocation(["wait", "my-task", "--until", "idle,running", "--timeout", "5000"])?.request,
            ControlRequest(method: "task.wait", params: ["id": "my-task", "until": "idle,running", "timeout": "5000"])
        )
        XCTAssertNotNil(errorMessage(["wait"]))
    }

    func testParseRestart() {
        XCTAssertEqual(
            invocation(["restart", "my-task"])?.request,
            ControlRequest(method: "task.restart", params: ["id": "my-task"])
        )
        XCTAssertNotNil(errorMessage(["restart"]))
    }

    func testParseReaderToggle() {
        XCTAssertEqual(invocation(["reader"])?.request, ControlRequest(method: "reader.toggle"))
        XCTAssertEqual(invocation(["autosleep"])?.request, ControlRequest(method: "autosleep"))
        XCTAssertEqual(invocation(["autosleep", "--now"])?.request, ControlRequest(method: "autosleep", params: ["now": "1"]))
    }

    func testParseSpeakVariants() {
        XCTAssertEqual(invocation(["speak"])?.request, ControlRequest(method: "task.speak"))
        XCTAssertEqual(
            invocation(["speak", "my-task"])?.request,
            ControlRequest(method: "task.speak", params: ["id": "my-task"])
        )
        XCTAssertEqual(
            invocation(["speak", "--dry-run"])?.request,
            ControlRequest(method: "task.speak", params: ["dry-run": "1"])
        )
        XCTAssertEqual(
            invocation(["speak", "my-task", "--dry-run"])?.request,
            ControlRequest(method: "task.speak", params: ["id": "my-task", "dry-run": "1"])
        )
    }

    func testGlobalFlagsAreExtracted() {
        let parsed = invocation(["tasks", "--json", "--socket", "/tmp/x.sock", "--project", "acme"])
        XCTAssertEqual(parsed?.rawJSON, true)
        XCTAssertEqual(parsed?.socketPath, "/tmp/x.sock")
        XCTAssertEqual(parsed?.request, ControlRequest(method: "tasks", params: ["project": "acme"]))
    }

    func testHelpAndUnknown() {
        XCTAssertEqual(ControlCLI.parse([]), .help)
        XCTAssertEqual(ControlCLI.parse(["--help"]), .help)
        XCTAssertEqual(ControlCLI.parse(["help"]), .help)
        XCTAssertNotNil(errorMessage(["frobnicate"]))
    }

    func testDottedMethodPassthrough() {
        let request = invocation(["surface.list", "--task", "t1"])?.request
        XCTAssertEqual(request?.method, "surface.list")
        XCTAssertEqual(request?.params["task"], "t1")
    }

    func testMissingFlagValueIsAnError() {
        XCTAssertNotNil(errorMessage(["tasks", "--project"]))
        XCTAssertNotNil(errorMessage(["--socket"]))
    }
}

import XCTest
@testable import BalaganCore

final class DevServerPortsTests: XCTestCase {
    private func process(_ name: String, cwd: String?, ports: [Int]) -> ListeningProcess {
        ListeningProcess(pid: 1, parentPID: 0, name: name, workingDirectory: cwd, ports: ports)
    }

    func testAServerBelongsToTheTaskWhoseFolderContainsIt() {
        let ports = DevServerPorts.assign(
            processes: [process("node", cwd: "/work/api-worktrees/passkeys/web", ports: [3000, 5173])],
            taskDirectories: ["passkeys": ["/work/api-worktrees/passkeys"], "main": ["/work/api"]]
        )
        XCTAssertEqual(ports["passkeys"]?.map(\.port), [3000, 5173])
        XCTAssertNil(ports["main"])
    }

    func testTheMostSpecificFolderWins() {
        let ports = DevServerPorts.assign(
            processes: [process("ruby", cwd: "/work/app/engines/billing", ports: [3001])],
            taskDirectories: ["root": ["/work/app"], "billing": ["/work/app/engines/billing"]]
        )
        XCTAssertEqual(Set(ports.keys), ["billing"])
    }

    func testTasksSharingACheckoutBothShowItsServer() {
        let ports = DevServerPorts.assign(
            processes: [process("Python", cwd: "/work/site", ports: [8000])],
            taskDirectories: ["a": ["/work/site"], "b": ["/work/site/"]]
        )
        XCTAssertEqual(ports["a"]?.first?.port, 8000)
        XCTAssertEqual(ports["b"]?.first?.port, 8000)
    }

    func testAgentsEphemeralPortsAndUnrelatedFoldersAreIgnored() {
        let ports = DevServerPorts.assign(
            processes: [
                process("claude", cwd: "/work/site", ports: [4000]),
                process("node", cwd: "/work/site", ports: [61_234]),
                process("node", cwd: "/elsewhere", ports: [3000]),
                process("node", cwd: "/work/site-old", ports: [3002]),
            ],
            taskDirectories: ["t": ["/work/site"]]
        )
        XCTAssertTrue(ports.isEmpty, "\(ports)")
    }

    func testFindsEveryDescendantOfTheApp() {
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11, 13: 1, 20: 99]
        XCTAssertEqual(DevServerPorts.descendants(of: 10, parents: parents), [11, 12])
        XCTAssertEqual(DevServerPorts.descendants(of: 1, parents: parents), [10, 11, 12, 13])
    }
}

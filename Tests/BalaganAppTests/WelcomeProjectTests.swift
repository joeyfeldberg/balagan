import XCTest
@testable import BalaganApp
@testable import BalaganCore

final class WelcomeProjectTests: XCTestCase {
    func testAProjectFromAFolderIsNamedAfterItAndSelected() {
        let vm = BoardViewModel(projects: [], tasks: [], selectedTaskID: nil)
        let project = vm.createProject(fromFolder: URL(fileURLWithPath: "/Users/me/repos/my-service"))
        XCTAssertEqual(project.name, "my-service")
        XCTAssertEqual(project.repoPath, "/Users/me/repos/my-service")
        XCTAssertEqual(project.defaultAgentCommand, AppPreferences.defaultAgent.command)
        XCTAssertEqual(vm.selectedProjectID, project.id)
        XCTAssertEqual(vm.projects.count, 1)
    }
}

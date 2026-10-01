import XCTest
@testable import BalaganCore

final class ControlCLIInstallerTests: XCTestCase {
    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-cli-installer-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? fileManager.removeItem(at: tempDirectory) }
    }

    /// A directory we can drop a symlink in, plus a fake CLI path to point it at.
    private func makeBinDir(_ name: String = "bin") throws -> String {
        let dir = tempDirectory.appendingPathComponent(name).path
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private var cliPath: String { tempDirectory.appendingPathComponent("App.app/Contents/MacOS/balagan").path }

    func testInstallsIntoEmptyDirectory() throws {
        let dir = try makeBinDir()
        let outcome = ControlCLIInstaller.installLink(cliPath: cliPath, directory: dir)
        XCTAssertEqual(outcome, .installed)
        let linkPath = dir + "/balagan"
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linkPath), cliPath)
    }

    func testSecondInstallIsAlreadyCurrent() throws {
        let dir = try makeBinDir()
        XCTAssertEqual(ControlCLIInstaller.installLink(cliPath: cliPath, directory: dir), .installed)
        XCTAssertEqual(ControlCLIInstaller.installLink(cliPath: cliPath, directory: dir), .alreadyCurrent)
    }

    func testReplacesStaleSymlink() throws {
        let dir = try makeBinDir()
        let linkPath = dir + "/balagan"
        try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: "/some/old/location/balagan")

        let outcome = ControlCLIInstaller.installLink(cliPath: cliPath, directory: dir)
        XCTAssertEqual(outcome, .installed)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: linkPath), cliPath)
    }

    func testNeverClobbersRealFile() throws {
        let dir = try makeBinDir()
        let linkPath = dir + "/balagan"
        let sentinel = "do not delete me"
        try sentinel.write(toFile: linkPath, atomically: true, encoding: .utf8)

        let outcome = ControlCLIInstaller.installLink(cliPath: cliPath, directory: dir)
        XCTAssertEqual(outcome, .realFilePresent)
        // The real file is untouched.
        XCTAssertEqual(try String(contentsOfFile: linkPath, encoding: .utf8), sentinel)
    }

    func testMissingDirectory() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist").path
        XCTAssertEqual(ControlCLIInstaller.installLink(cliPath: cliPath, directory: missing), .directoryMissing)
    }

    func testNonWritableDirectory() throws {
        let dir = try makeBinDir("readonly")
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir) // r-xr-xr-x: no write
        XCTAssertEqual(ControlCLIInstaller.installLink(cliPath: cliPath, directory: dir), .notWritable)
    }
}

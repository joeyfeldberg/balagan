import XCTest
@testable import BalaganCore

final class LegacyTaskBoardMigrationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var support: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        suiteName = "balagan-migration-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func migrate(legacyDomains: [String] = []) -> LegacyTaskBoardMigration.Report {
        LegacyTaskBoardMigration.run(home: home, applicationSupport: support, defaults: defaults, legacyDefaultsDomains: legacyDomains)
    }

    func testCopiesTheDatabaseWithItsWalAndLeavesTheOriginal() throws {
        let old = support.appendingPathComponent("TaskBoard/TaskBoard.sqlite")
        try write("db", to: old)
        try write("wal", to: URL(fileURLWithPath: old.path + "-wal"))

        XCTAssertTrue(migrate().copiedDatabase)
        let new = support.appendingPathComponent("Balagan/Balagan.sqlite")
        XCTAssertEqual(read(new), "db")
        XCTAssertEqual(read(URL(fileURLWithPath: new.path + "-wal")), "wal")
        XCTAssertEqual(read(old), "db")
    }

    func testNeverOverwritesAnExistingBalaganDatabase() throws {
        try write("old", to: support.appendingPathComponent("TaskBoard/TaskBoard.sqlite"))
        let new = support.appendingPathComponent("Balagan/Balagan.sqlite")
        try write("current", to: new)

        XCTAssertFalse(migrate().copiedDatabase)
        XCTAssertEqual(read(new), "current")
    }

    func testCopiesCustomAgentProfilesOnce() throws {
        try write("{\"id\":\"goose\"}", to: home.appendingPathComponent(".taskboard/agents/goose.json"))

        XCTAssertTrue(migrate().copiedAgentProfiles)
        XCTAssertEqual(read(home.appendingPathComponent(".balagan/agents/goose.json")), "{\"id\":\"goose\"}")
        XCTAssertFalse(migrate().copiedAgentProfiles)
    }

    func testNothingToMigrateIsANoOp() {
        XCTAssertEqual(migrate(), LegacyTaskBoardMigration.Report())
    }

    func testCarriesOverPreferencesWithoutClobberingNewOnes() {
        let legacyDomain = "balagan-migration-legacy-\(UUID().uuidString)"
        defaults.setPersistentDomain(["autoSleepIdleMinutes": 45, "speechRateMultiplier": 1.25], forName: legacyDomain)
        defer { defaults.removePersistentDomain(forName: legacyDomain) }
        defaults.set(1.5, forKey: "speechRateMultiplier")

        XCTAssertEqual(migrate(legacyDomains: [legacyDomain]).copiedDefaultsKeys, 1)
        XCTAssertEqual(defaults.integer(forKey: "autoSleepIdleMinutes"), 45)
        XCTAssertEqual(defaults.double(forKey: "speechRateMultiplier"), 1.5)

        // Only ever once: a preference cleared later isn't resurrected from the old domain.
        defaults.removeObject(forKey: "autoSleepIdleMinutes")
        XCTAssertEqual(migrate(legacyDomains: [legacyDomain]).copiedDefaultsKeys, 0)
        XCTAssertNil(defaults.object(forKey: "autoSleepIdleMinutes"))
    }

    // MARK: - Board contents

    private func rewritten(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.jsonObject(with: LegacyTaskBoardMigration.rewriteBoardJSON(data)) as! [String: Any]
    }

    func testRewritesWrapperCommandsPathsAndEnvironmentNames() throws {
        let board: [String: Any] = [
            "defaultAgentCommand": "taskboard-agent claude",
            "startupCommand": "'/Applications/TaskBoard.app/Contents/MacOS/taskboard-agent' codex",
            "setupCommands": ["cp \"$TASKBOARD_REPO_PATH\"/.env ."],
            "environment": ["TASKBOARD_REPO_PATH": "/r", "HOME": "/h"],
            "sanitizedEnvironment": ["PATH": "/Users/me/.taskboard/shims:/Applications/TaskBoard.app/Contents/MacOS:/usr/bin"],
        ]
        let out = try rewritten(board)
        XCTAssertEqual(out["defaultAgentCommand"] as? String, "balagan-agent claude")
        XCTAssertEqual(out["startupCommand"] as? String, "'/Applications/Balagan.app/Contents/MacOS/balagan-agent' codex")
        XCTAssertEqual(out["setupCommands"] as? [String], ["cp \"$BALAGAN_REPO_PATH\"/.env ."])
        XCTAssertEqual(out["environment"] as? [String: String], ["BALAGAN_REPO_PATH": "/r", "HOME": "/h"])
        XCTAssertEqual((out["sanitizedEnvironment"] as? [String: String])?["PATH"],
                       "/Users/me/.balagan/shims:/Applications/Balagan.app/Contents/MacOS:/usr/bin")
    }

    func testLeavesProseAlone() throws {
        let prose = "zsh: command not found: taskboard-agent"
        let out = try rewritten(["scrollbackSnapshot": prose, "notes": prose, "title": prose, "startupCommand": "taskboard-agent pi"])
        XCTAssertEqual(out["scrollbackSnapshot"] as? String, prose)
        XCTAssertEqual(out["notes"] as? String, prose)
        XCTAssertEqual(out["title"] as? String, prose)
        XCTAssertEqual(out["startupCommand"] as? String, "balagan-agent pi")
    }

    func testABoardWithNothingToRewriteIsReturnedByteForByte() {
        let clean = Data(#"{"startupCommand":"balagan-agent claude"}"#.utf8)
        XCTAssertEqual(LegacyTaskBoardMigration.rewriteBoardJSON(clean), clean)
    }

    func testAnEnvironmentWithBothSpellingsKeepsTheNewValue() throws {
        let out = try rewritten(["environment": ["TASKBOARD_AGENT_NAME": "old", "BALAGAN_AGENT_NAME": "new"]])
        XCTAssertEqual(out["environment"] as? [String: String], ["BALAGAN_AGENT_NAME": "new"])
    }
}

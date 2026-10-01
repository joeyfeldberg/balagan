import XCTest
@testable import BalaganCore

final class GitDiffParserTests: XCTestCase {
    func testParsesAModifiedFileWithLineNumbers() {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,5 @@ struct App {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             let d = 5
        """
        let files = GitDiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.path, "Sources/App.swift")
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.fileName, "App.swift")
        XCTAssertEqual(file.directory, "Sources/")

        let lines = file.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(lines[0].oldNumber, 10)
        XCTAssertEqual(lines[0].newNumber, 10)
        XCTAssertEqual(lines[1].oldNumber, 11)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[3].newNumber, 12)
        XCTAssertEqual(lines[4].oldNumber, 12)
        XCTAssertEqual(lines[4].newNumber, 13)
        XCTAssertEqual(lines[2].text, "    let b = 3")
    }

    func testParsesAddedDeletedRenamedAndBinaryFiles() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old name.md b/new name.md
        similarity index 90%
        rename from old name.md
        rename to new name.md
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let files = GitDiffParser.parse(diff)
        XCTAssertEqual(files.map(\.status), [.added, .deleted, .renamed, .modified])
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[1].path, "gone.txt")
        XCTAssertEqual(files[1].deletions, 1)
        XCTAssertEqual(files[2].path, "new name.md")
        XCTAssertEqual(files[2].oldPath, "old name.md")
        XCTAssertTrue(files[2].hunks.isEmpty)
        XCTAssertTrue(files[3].isBinary)
    }

    func testContentThatLooksLikeHeadersInsideAHunkIsContent() {
        // Built line by line: the single-space context line must survive (editors strip it).
        let diff = [
            "diff --git a/notes.md b/notes.md",
            "--- a/notes.md",
            "+++ b/notes.md",
            "@@ -1,2 +1,2 @@",
            "--- a removed line starting with dashes",
            "+++ an added line starting with pluses",
            " ",
            "\\ No newline at end of file",
        ].joined(separator: "\n")
        let lines = GitDiffParser.parse(diff)[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.removed, .added, .context])
        XCTAssertEqual(lines[0].text, "-- a removed line starting with dashes")
        XCTAssertEqual(lines[2].text, "")
        XCTAssertTrue(lines[2].missingNewline)
    }

    func testUntrackedFileIsAllAdded() {
        let file = GitDiffParser.untrackedFile(path: "a/b.txt", contents: "one\ntwo\n")
        XCTAssertEqual(file.status, .untracked)
        XCTAssertTrue(file.isUncommitted)
        XCTAssertEqual(file.hunks[0].lines.map(\.text), ["one", "two"])
        XCTAssertEqual(file.hunks[0].lines.map(\.newNumber), [1, 2])

        XCTAssertTrue(GitDiffParser.untrackedFile(path: "x.bin", contents: nil).isBinary)
        XCTAssertTrue(GitDiffParser.untrackedFile(path: "empty", contents: "").hunks.isEmpty)
        XCTAssertTrue(GitDiffParser.untrackedFile(path: "n", contents: "last").hunks[0].lines[0].missingNewline)
    }

    func testEmptyOutputIsNoFiles() {
        XCTAssertEqual(GitDiffParser.parse(""), [])
    }
}

final class TaskChangesLoaderTests: XCTestCase {
    private var repo: String!

    override func setUpWithError() throws {
        repo = NSTemporaryDirectory() + "task-changes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "T")
        try write("keep.txt", "one\ntwo\n")
        try write("drop.txt", "bye\n")
        try git("add", ".")
        try git("commit", "-q", "-m", "base")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(toFile: repo + "/" + path, atomically: true, encoding: .utf8)
    }

    func testBranchShowsCommittedUncommittedAndUntrackedWork() throws {
        try git("checkout", "-q", "-b", "task")
        try write("keep.txt", "one\nTWO\n")
        try git("rm", "-q", "drop.txt")
        try git("commit", "-q", "-am", "work")
        try write("keep.txt", "one\nTWO\nthree\n")      // uncommitted on top
        try write("fresh.md", "# new\n")                 // untracked

        let changes = try TaskChangesLoader.load(worktree: repo, baseBranch: "main").get()
        XCTAssertEqual(changes.baseName, "main")
        XCTAssertEqual(changes.commitsAhead, 1)
        XCTAssertEqual(changes.files.map(\.path), ["drop.txt", "fresh.md", "keep.txt"])
        XCTAssertEqual(changes.files.map(\.status), [.deleted, .untracked, .modified])

        let keep = changes.files[2]
        XCTAssertTrue(keep.isUncommitted)
        XCTAssertEqual(keep.additions, 2)   // TWO, three
        XCTAssertEqual(keep.deletions, 1)   // two
        XCTAssertFalse(changes.files[0].isUncommitted, "the deletion is committed")
        XCTAssertEqual(changes.uncommittedCount, 2)
        XCTAssertFalse(changes.isTruncated)
    }

    func testOnTheBaseBranchOnlyUncommittedChangesShow() throws {
        try write("keep.txt", "one\n")
        let changes = try TaskChangesLoader.load(worktree: repo, baseBranch: "main").get()
        XCTAssertNil(changes.baseName)
        XCTAssertEqual(changes.commitsAhead, 0)
        XCTAssertEqual(changes.files.map(\.path), ["keep.txt"])
        XCTAssertEqual(changes.files[0].deletions, 1)
    }

    func testCleanBranchHasNoChanges() throws {
        try git("checkout", "-q", "-b", "task")
        let changes = try TaskChangesLoader.load(worktree: repo, baseBranch: "main").get()
        XCTAssertEqual(changes.files, [])
        XCTAssertEqual(changes.baseName, "main")
    }

    func testNotARepository() {
        let plain = NSTemporaryDirectory() + "not-a-repo-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        XCTAssertEqual(TaskChangesLoader.load(worktree: plain, baseBranch: "main"), .failure(.notARepository))
    }
}

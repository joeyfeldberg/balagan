import XCTest
@testable import BalaganCore

final class FileTailTests: XCTestCase {
    private func file(_ text: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testSmallFileIsReadWhole() throws {
        let tail = try XCTUnwrap(FileTail.read(atPath: file("one\ntwo\n"), maxBytes: 100))
        XCTAssertEqual(tail, FileTail.Tail(text: "one\ntwo\n", isWholeFile: true))
    }

    func testMidFileTailDropsThePartialFirstLine() throws {
        let tail = try XCTUnwrap(FileTail.read(atPath: file("first line\nsecond\nthird\n"), maxBytes: 12))
        XCTAssertEqual(tail, FileTail.Tail(text: "third\n", isWholeFile: false))
    }

    func testCutInsideAMultibyteCharacter() throws {
        // "é" is two bytes; a 9-byte tail starts on its second byte.
        let tail = try XCTUnwrap(FileTail.read(atPath: file("café\nok\n"), maxBytes: 8))
        XCTAssertEqual(tail.text, "ok\n")
    }

    func testMissingFile() {
        XCTAssertNil(FileTail.read(atPath: "/no/such/file-\(UUID().uuidString)", maxBytes: 10))
    }
}

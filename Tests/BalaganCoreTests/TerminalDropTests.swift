import XCTest
@testable import BalaganCore

final class TerminalDropTests: XCTestCase {
    func testPathsAreShellEscapedAndSpaceSeparated() {
        XCTAssertEqual(
            TerminalDrop.pasteText(forPaths: ["/Users/me/Screen Shot (2).png", "/tmp/a&b.txt"]),
            #"/Users/me/Screen\ Shot\ \(2\).png /tmp/a\&b.txt "#
        )
        XCTAssertEqual(TerminalDrop.escapedPath("/tmp/it's $HOME"), #"/tmp/it\'s\ \$HOME"#)
        XCTAssertEqual(TerminalDrop.pasteText(forPaths: []), "")
    }

    func testDroppedImageDataGetsAFileUnderDrops() {
        let path = TerminalDrop.dropFile(root: "/r", extension: "png", at: Date(timeIntervalSince1970: 1.5))
        XCTAssertEqual(path, "/r/drops/drop-1500.png")
    }
}

import Darwin
import XCTest
@testable import BalaganCore

final class UnixSocketListenerTests: XCTestCase {
    private func socketPath() -> String {
        // AF_UNIX paths are short (~104 bytes), so stay out of the long temporary directory.
        let path = "/tmp/bq-listener-\(UUID().uuidString.prefix(8)).sock"
        addTeardownBlock { unlink(path) }
        return path
    }

    func testHandsEachConnectionToTheHandler() throws {
        let path = socketPath()
        let received = expectation(description: "connection read")
        let queue = DispatchQueue(label: "listener-test")
        let listener = try UnixSocketListener(path: path, queue: queue) { fd in
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = read(fd, &buffer, buffer.count)
            close(fd)
            if String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "hello" { received.fulfill() }
        }
        try queue.sync { try listener.start() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertEqual(UnixSocketHelpers.connect(client, to: UnixSocketHelpers.makeAddress(path: path)), 0)
        _ = "hello".withCString { write(client, $0, 5) }
        close(client)

        wait(for: [received], timeout: 5)
    }

    func testRejectsAPathTooLongForSockaddr() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertThrowsError(try UnixSocketListener(path: path, queue: .main) { _ in }) { error in
            XCTAssertEqual(error as? UnixSocketListener.Failure, .pathTooLong(path))
        }
    }
}

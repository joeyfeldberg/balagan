import AppKit
import Darwin
import Foundation
import BalaganCore

/// A local **request/response** control socket. The `balagan` CLI connects, writes one JSON request
/// line, and reads back one JSON response line — letting the CLI drive the running app (list / create /
/// open tasks, query state).
///
/// Unlike `SessionReportServer`, it's bidirectional (writes a response) and runs accept + socket I/O on
/// its **own background queue**, so a slow read can never stall the main thread. Each request's handler
/// runs on the main actor (where `BoardViewModel` lives) via `DispatchQueue.main.async`, which also
/// writes the reply and closes the connection.
final class ControlSocketServer: @unchecked Sendable {
    /// Handles one request on the **main actor** and returns the JSON-serialized response
    /// (a single object like `{"ok":true,"result":…}`, **without** a trailing newline — the server
    /// appends it). `@MainActor` so the handler can touch the view model / window; returns `Data`
    /// (rather than a dictionary) so the result is `Sendable`.
    typealias Handler = @MainActor @Sendable (_ method: String, _ params: [String: String]) -> Data

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.joeyfeldberg.balagan.control")
    private var listener: UnixSocketListener!

    init(socketPath: String, handler: @escaping Handler) throws {
        self.handler = handler
        listener = try UnixSocketListener(
            path: socketPath,
            queue: queue,
            onAcceptError: { NSLog("Balagan control accept failed: errno \($0)") },
            onConnection: { [weak self] fd in self?.handle(clientFD: fd) }
        )
    }

    /// Binds and listens on the server's own queue. There is no stop (see `UnixSocketListener`).
    func start() {
        queue.async { [listener] in
            do {
                try listener?.start()
            } catch {
                NSLog("Balagan control socket start failed: \(error)")
            }
        }
    }

    private func handle(clientFD: Int32) {
        // Read one newline-terminated request line. We're on the background queue, so a blocking read
        // here never stalls the UI.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.contains(0x0a) == false {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            break // EOF or error
        }

        let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let request = ControlWire.decodeRequestLine(line)
        let handler = self.handler

        // The handler runs on the main actor (it touches the view model / window); compute the reply,
        // write it, and close the socket there.
        DispatchQueue.main.async {
            let body: Data = MainActor.assumeIsolated {
                if let request {
                    return handler(request.method, request.params)
                }
                return Data(#"{"ok":false,"error":"malformed request"}"#.utf8)
            }
            var responseData = body
            responseData.append(0x0a)
            ControlSocketServer.write(responseData, to: clientFD)
            Darwin.close(clientFD)
        }
    }

    private static func write(_ data: Data, to clientFD: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(clientFD, base.advanced(by: written), data.count - written)
                if count <= 0 { break }
                written += count
            }
        }
    }
}

import Combine
import Foundation
import BalaganCore

/// Live-follows an agent transcript on disk while reader mode is open: a short-interval timer polls
/// the file for appended bytes, parses complete lines off-main, and publishes the growing entry
/// list. Deliberately a timer + read (the `AppPullRequestPolling` shape), not a vnode
/// `DispatchSource` — it only runs while the reader is visible, and avoids the guarded-fd teardown
/// rules the socket sources need.
@MainActor
final class TranscriptTailer: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var fileExists = true

    private let source: ReaderTranscriptSource
    private let queue = DispatchQueue(label: "balagan.transcript-tailer", qos: .userInitiated)
    private var timer: Timer?
    private var pollInFlight = false
    private let reader: TranscriptTailFileReader

    init(source: ReaderTranscriptSource) {
        self.source = source
        self.reader = TranscriptTailFileReader(format: source.format)
    }

    func start(interval: TimeInterval = 0.75) {
        guard timer == nil else { return }
        // The first read is synchronous so the reader opens with content already there (and headless
        // snapshots are deterministic); only the follow-up polls hop to the queue.
        apply(reader.readAppendedEntries(path: source.path))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard pollInFlight == false else { return }
        pollInFlight = true
        let path = source.path
        let reader = reader
        queue.async { [weak self] in
            let outcome = reader.readAppendedEntries(path: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                self.apply(outcome)
            }
        }
    }

    private func apply(_ outcome: TranscriptTailFileReader.PollOutcome) {
        switch outcome {
        case .missing:
            fileExists = false
        case .unchanged:
            fileExists = true
        case let .appended(newEntries):
            fileExists = true
            entries.append(contentsOf: newEntries)
        case let .replaced(allEntries):
            fileExists = true
            entries = allEntries
        }
    }
}

/// The tailer's file cursor + line buffer. Confined to the tailer's serial queue (all calls happen
/// there), hence the unchecked Sendable.
private final class TranscriptTailFileReader: @unchecked Sendable {
    enum PollOutcome {
        case missing
        case unchanged
        case appended([TranscriptEntry])
        case replaced([TranscriptEntry])
    }

    private var buffer: TranscriptTailBuffer
    private var byteOffset: UInt64 = 0

    init(format: AgentTranscriptFormat) {
        buffer = TranscriptTailBuffer(format: format)
    }

    /// Reads bytes past the current offset; a shrunken file (truncation/replacement) resets and
    /// re-reads from the top.
    func readAppendedEntries(path: String) -> PollOutcome {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .missing }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var wasReset = false
        if size < byteOffset {
            buffer.reset()
            byteOffset = 0
            wasReset = true
        }
        guard size > byteOffset else { return wasReset ? .replaced([]) : .unchanged }

        guard (try? handle.seek(toOffset: byteOffset)) != nil,
              let chunk = try? handle.readToEnd(), chunk.isEmpty == false
        else {
            return wasReset ? .replaced([]) : .unchanged
        }
        byteOffset += UInt64(chunk.count)
        let newEntries = buffer.consume(chunk)
        if wasReset {
            return .replaced(newEntries)
        }
        return newEntries.isEmpty ? .unchanged : .appended(newEntries)
    }
}

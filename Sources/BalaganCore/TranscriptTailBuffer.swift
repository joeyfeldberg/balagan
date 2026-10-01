import Foundation

/// Incremental JSONL decoding for a transcript that is still being written: feed it appended byte
/// chunks in order and it emits entries for every *complete* line, carrying a partial trailing line
/// (agents write lines atomically, but a read can still land mid-write) until its newline arrives.
/// Pure — file I/O and scheduling stay in the app layer.
public struct TranscriptTailBuffer: Sendable {
    private var partialLine = Data()
    private var lineIndex = 0
    public let format: AgentTranscriptFormat

    public init(format: AgentTranscriptFormat) {
        self.format = format
    }

    public mutating func consume(_ chunk: Data) -> [TranscriptEntry] {
        guard chunk.isEmpty == false else { return [] }
        var buffer = partialLine
        buffer.append(chunk)

        var entries: [TranscriptEntry] = []
        var searchStart = buffer.startIndex
        while let newlineIndex = buffer[searchStart...].firstIndex(of: 0x0a) {
            let lineData = buffer[searchStart..<newlineIndex]
            let line = String(decoding: lineData, as: UTF8.self)
            entries.append(contentsOf: AgentTranscriptParser.entries(
                fromLine: line,
                lineIndex: lineIndex,
                format: format
            ))
            lineIndex += 1
            searchStart = buffer.index(after: newlineIndex)
        }
        partialLine = Data(buffer[searchStart...])
        return entries
    }

    /// Forget everything (the file was truncated or replaced); entry ids restart from zero.
    public mutating func reset() {
        partialLine = Data()
        lineIndex = 0
    }
}

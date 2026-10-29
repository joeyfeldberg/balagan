import Foundation

/// The end of a file that may be many MB (transcripts, Codex rollouts), as whole lines.
public enum FileTail {
    public struct Tail: Equatable, Sendable {
        public var text: String
        /// The tail reached the start of the file, so nothing was cut off.
        public var isWholeFile: Bool
    }

    /// The last `maxBytes` of the file, nil if it can't be read. A tail that starts mid-file drops its
    /// partial first line (and any cut-off UTF-8 character before it).
    public static func read(atPath path: String, maxBytes: Int) -> Tail? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        guard start > 0 else {
            return Tail(text: String(decoding: data, as: UTF8.self), isWholeFile: true)
        }
        var text = String(decoding: data.drop { $0 & 0xC0 == 0x80 }, as: UTF8.self)
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return Tail(text: text, isWholeFile: false)
    }
}

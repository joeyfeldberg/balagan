import Foundation

/// Parses the ISO 8601 timestamps agents and GitHub write, with or without fractional seconds.
public enum ISO8601Timestamp {
    // Configured once and only ever read with `date(from:)`, which is thread-safe, so the unchecked
    // statics are safe. Building them per call was the cost here: transcripts parse one per record.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Claude writes microseconds ("…59.606369+00:00"), which `ISO8601DateFormatter` can't read, so
    /// the fraction is cut (or padded) to milliseconds first.
    public static func parse(_ string: String) -> Date? {
        var text = string
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(
                text.index(after: dot)..<end,
                with: String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            )
        }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

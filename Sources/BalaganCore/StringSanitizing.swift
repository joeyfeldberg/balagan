import Foundation

public extension String {
    /// A whitespace-and-newline-trimmed copy, used to normalize user-entered text before storing it.
    var trimmedForStorage: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The trimmed value, or `nil` when it is empty after trimming.
    var nilIfBlank: String? {
        let value = trimmedForStorage
        return value.isEmpty ? nil : value
    }
}

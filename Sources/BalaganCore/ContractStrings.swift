import Foundation

/// Strings the app and the UI driver must spell identically, since one writes what the other looks
/// up: accessibility identifiers and artifact file names.
public extension String {
    /// A lowercase, dash-separated slug for an accessibility identifier ("Build kanban shell" →
    /// "build-kanban-shell"); "item" when nothing alphanumeric is left.
    var accessibilitySlug: String {
        let scalars = trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? "item" : slug
    }

    /// Safe inside an artifact file name: anything but letters, digits, `-`, `_` and `.` becomes `-`.
    var safeArtifactComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}

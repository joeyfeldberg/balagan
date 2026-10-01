import Foundation
import BalaganCore

extension String {
    var accessibilitySlug: String {
        let scalars = trimmedForStorage.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let slug = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? "item" : slug
    }
}

func uniqueID(base: String, existingIDs: Set<String>) -> String {
    let trimmed = base.trimmedForStorage.lowercased()
    let scalars = trimmed.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) {
            return Character(scalar)
        }
        return "-"
    }
    var slug = String(scalars)
        .split(separator: "-")
        .joined(separator: "-")

    if slug.isEmpty {
        slug = "item"
    }

    var candidate = slug
    var suffix = 2
    while existingIDs.contains(candidate) {
        candidate = "\(slug)-\(suffix)"
        suffix += 1
    }
    return candidate
}

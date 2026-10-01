import Foundation

public enum BranchNaming {
    /// Derives a git-safe branch slug from a task title: lowercased, each run of non-alphanumeric
    /// characters collapsed to a single hyphen, no leading/trailing hyphen, length-capped. Returns an
    /// empty string when the title has no usable characters.
    public static func slug(from title: String, maxLength: Int = 50) -> String {
        var out = ""
        var pendingHyphen = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingHyphen && out.isEmpty == false {
                    out.append("-")
                }
                pendingHyphen = false
                out.append(character)
            } else {
                pendingHyphen = true
            }
        }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

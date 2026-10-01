import Foundation

public struct EnvironmentSanitizer: Equatable, Sendable {
    private static let sensitiveKeyFragments = [
        "ACCESS_KEY",
        "API_KEY",
        "AUTH",
        "COOKIE",
        "CREDENTIAL",
        "PASSWORD",
        "PASSWD",
        "PRIVATE_KEY",
        "SECRET",
        "TOKEN",
    ]

    public var allowlist: Set<String>

    public init(allowlist: Set<String> = EnvironmentSanitizer.defaultAllowlist) {
        self.allowlist = allowlist
    }

    public func sanitize(_ environment: [String: String]) -> [String: String] {
        Self.sanitize(environment, allowlist: allowlist)
    }

    public static func isSensitive(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }
}

extension EnvironmentSanitizer {
    public static var defaultAllowlist: Set<String> {
        [
            "COLORTERM",
            "HOME",
            "LANG",
            "LC_*",
            "PATH",
            "PWD",
            "SHELL",
            "TERM",
            "TERM_PROGRAM",
            "TMPDIR",
            "USER",
        ]
    }

    public static func sanitize(
        _ environment: [String: String],
        allowlist: Set<String>
    ) -> [String: String] {
        environment.reduce(into: [:]) { sanitized, pair in
            let key = pair.key

            guard isAllowed(key, allowlist: allowlist), !isSensitive(key) else {
                return
            }

            sanitized[key] = pair.value.replacingOccurrences(of: "\0", with: "")
        }
    }

    public static func isAllowed(_ key: String, allowlist: Set<String> = EnvironmentSanitizer.defaultAllowlist) -> Bool {
        allowlist.contains { pattern in
            if pattern.hasSuffix("*") {
                return key.hasPrefix(String(pattern.dropLast()))
            }

            return key == pattern
        }
    }
}

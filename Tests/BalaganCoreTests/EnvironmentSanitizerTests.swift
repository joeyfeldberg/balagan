import XCTest
@testable import BalaganCore

final class EnvironmentSanitizerTests: XCTestCase {
    func testSanitizerKeepsAllowlistedValuesAndDropsSecrets() {
        let environment = [
            "API_TOKEN": "secret",
            "CUSTOM": "drop-me",
            "HOME": "/Users/example",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
            "SSH_AUTH_SOCK": "/tmp/auth.sock",
            "TERM": "xterm-256color",
            "WEIRD": "a\0b",
        ]

        let sanitized = EnvironmentSanitizer.sanitize(
            environment,
            allowlist: ["API_TOKEN", "HOME", "LC_*", "PATH", "SSH_AUTH_SOCK", "TERM", "WEIRD"]
        )

        XCTAssertEqual(sanitized["HOME"], "/Users/example")
        XCTAssertEqual(sanitized["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["TERM"], "xterm-256color")
        XCTAssertEqual(sanitized["WEIRD"], "ab")
        XCTAssertNil(sanitized["API_TOKEN"])
        XCTAssertNil(sanitized["CUSTOM"])
        XCTAssertNil(sanitized["SSH_AUTH_SOCK"])
    }

    func testSurfaceUsesItsEnvironmentAllowlist() {
        let surface = BalaganFixtures.surface(
            environment: [
                "HOME": "/Users/example",
                "PATH": "/usr/bin:/bin",
                "BALAGAN_MODE": "fixture",
            ],
            resumeBinding: nil
        )

        let sanitized = surface.sanitizedEnvironment(
            from: surface.environment,
            allowlist: ["PATH", "BALAGAN_MODE"]
        )

        XCTAssertEqual(sanitized, [
            "PATH": "/usr/bin:/bin",
            "BALAGAN_MODE": "fixture",
        ])
    }
}

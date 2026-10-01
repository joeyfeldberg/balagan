import XCTest
@testable import BalaganCore

final class LibGhosttyRuntimeTests: XCTestCase {
    func testRequiredSymbolsCoverEmbeddingLifecycle() {
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_init"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_config_new"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_app_new"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_app_tick"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_surface_new"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_surface_set_focus"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_surface_key"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_surface_text"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_surface_size"))
        XCTAssertTrue(LibGhosttyRuntimeProbe.requiredSymbols.contains("ghostty_surface_binding_action"))
    }

    func testSearchPathsPreferExplicitPathThenEnvironment() {
        let paths = LibGhosttyRuntimeProbe.searchPaths(
            explicitPath: "/tmp/explicit-libghostty.dylib",
            environment: ["BALAGAN_LIBGHOSTTY_PATH": "/tmp/env-libghostty.dylib"]
        )

        XCTAssertEqual(paths[0], "/tmp/explicit-libghostty.dylib")
        XCTAssertEqual(paths[1], "/tmp/env-libghostty.dylib")
    }

    func testSearchPathsIncludeInstalledGhosttyAppExecutable() {
        let paths = LibGhosttyRuntimeProbe.searchPaths(environment: [:])

        XCTAssertTrue(paths.contains("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
    }

    func testGhosttyAppDependencyPathsIncludeSparkleFramework() {
        let paths = LibGhosttyRuntimeProbe.ghosttyAppDependencyPaths(
            for: "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        )

        XCTAssertEqual(paths, ["/Applications/Ghostty.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"])
    }

    func testMissingExplicitPathReportsUnavailableWhenNoLinkedRuntimeExists() {
        let status = LibGhosttyRuntimeProbe.probe(
            explicitPath: "/tmp/balagan-missing-libghostty.dylib",
            environment: [:]
        )

        if status.isAvailable {
            XCTAssertTrue(status.isAvailable)
        } else {
            XCTAssertFalse(status.isAvailable)
            XCTAssertEqual(status.source, .unavailable)
            XCTAssertTrue(status.checkedPaths.contains("/tmp/balagan-missing-libghostty.dylib"))
            XCTAssertFalse(status.missingSymbols.isEmpty)
        }
    }

    func testDynamicLibraryLoadReportsUnavailableForMissingExplicitPath() {
        do {
            let library = try LibGhosttyDynamicLibrary.load(
                explicitPath: "/tmp/balagan-missing-libghostty.dylib",
            environment: [:]
        )
            XCTAssertTrue([.linkedProcess, .dynamicLibrary].contains(library.status.source))
        } catch {
            if case .unavailable(let status) = error as? LibGhosttyDynamicLibraryError {
                XCTAssertEqual(status.source, .unavailable)
                XCTAssertTrue(status.checkedPaths.contains("/tmp/balagan-missing-libghostty.dylib"))
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

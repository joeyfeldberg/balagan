import Darwin
import Foundation

public enum LibGhosttyRuntimeSource: String, Codable, Equatable, Sendable {
    case linkedProcess
    case dynamicLibrary
    case unavailable
}

public struct LibGhosttyRuntimeStatus: Codable, Equatable, Sendable {
    public var isAvailable: Bool
    public var source: LibGhosttyRuntimeSource
    public var path: String?
    public var checkedPaths: [String]
    public var resolvedSymbols: [String]
    public var missingSymbols: [String]
    public var diagnostic: String?

    public init(
        isAvailable: Bool,
        source: LibGhosttyRuntimeSource,
        path: String? = nil,
        checkedPaths: [String] = [],
        resolvedSymbols: [String] = [],
        missingSymbols: [String] = [],
        diagnostic: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.source = source
        self.path = path
        self.checkedPaths = checkedPaths
        self.resolvedSymbols = resolvedSymbols
        self.missingSymbols = missingSymbols
        self.diagnostic = diagnostic
    }
}

public enum LibGhosttyRuntimeProbe {
    public static let requiredSymbols = [
        "ghostty_init",
        "ghostty_config_new",
        "ghostty_config_finalize",
        "ghostty_app_new",
        "ghostty_app_tick",
        "ghostty_app_free",
        "ghostty_surface_config_new",
        "ghostty_surface_new",
        "ghostty_surface_free",
        "ghostty_surface_set_size",
        "ghostty_surface_size",
        "ghostty_surface_set_focus",
        "ghostty_surface_set_occlusion",
        "ghostty_surface_key",
        "ghostty_surface_text",
        "ghostty_surface_binding_action",
    ]

    public static func probe(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LibGhosttyRuntimeStatus {
        if let linkedStatus = probeLinkedProcess(), linkedStatus.isAvailable {
            return linkedStatus
        }

        let paths = searchPaths(explicitPath: explicitPath, environment: environment)
        var diagnostics: [String] = []

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                diagnostics.append("\(path): missing")
                continue
            }

            let preloadedHandles = preloadDependencies(for: path)
            defer {
                for handle in preloadedHandles {
                    dlclose(handle)
                }
            }

            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                diagnostics.append("\(path): \(currentDynamicLoaderError())")
                continue
            }
            defer { dlclose(handle) }

            let resolution = resolveSymbols(in: handle)
            if resolution.missing.isEmpty {
                return LibGhosttyRuntimeStatus(
                    isAvailable: true,
                    source: .dynamicLibrary,
                    path: path,
                    checkedPaths: paths,
                    resolvedSymbols: resolution.resolved,
                    missingSymbols: []
                )
            }

            diagnostics.append("\(path): missing symbols \(resolution.missing.joined(separator: ", "))")
        }

        return LibGhosttyRuntimeStatus(
            isAvailable: false,
            source: .unavailable,
            checkedPaths: paths,
            resolvedSymbols: [],
            missingSymbols: requiredSymbols,
            diagnostic: diagnostics.joined(separator: "\n")
        )
    }

    public static func searchPaths(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var paths: [String] = []

        if let explicitPath, !explicitPath.isEmpty {
            paths.append(explicitPath)
        }

        for key in ["BALAGAN_LIBGHOSTTY_PATH", "LIBGHOSTTY_PATH"] {
            if let path = environment[key], !path.isEmpty {
                paths.append(path)
            }
        }

        paths.append(contentsOf: [
            "/opt/homebrew/lib/libghostty.dylib",
            "/usr/local/lib/libghostty.dylib",
            "/Applications/Ghostty.app/Contents/Frameworks/libghostty.dylib",
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            "/opt/homebrew/Caskroom/ghostty/latest/Ghostty.app/Contents/Frameworks/libghostty.dylib",
            "/opt/homebrew/Caskroom/ghostty/latest/Ghostty.app/Contents/MacOS/ghostty",
            "/opt/homebrew/Caskroom/ghostty/1.0.0/Ghostty.app/Contents/MacOS/ghostty",
        ])

        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }

    private static func probeLinkedProcess() -> LibGhosttyRuntimeStatus? {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }

        let resolution = resolveSymbols(in: handle)
        guard resolution.missing.isEmpty else {
            return nil
        }

        return LibGhosttyRuntimeStatus(
            isAvailable: true,
            source: .linkedProcess,
            resolvedSymbols: resolution.resolved,
            missingSymbols: []
        )
    }

    private static func resolveSymbols(in handle: UnsafeMutableRawPointer) -> (resolved: [String], missing: [String]) {
        var resolved: [String] = []
        var missing: [String] = []

        for symbol in requiredSymbols {
            if dlsym(handle, symbol) == nil {
                missing.append(symbol)
            } else {
                resolved.append(symbol)
            }
        }

        return (resolved, missing)
    }

    private static func currentDynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "unknown dlopen failure"
        }

        return String(cString: error)
    }

    private static func preloadDependencies(for path: String) -> [UnsafeMutableRawPointer] {
        ghosttyAppDependencyPaths(for: path).compactMap {
            dlopen($0, RTLD_NOW | RTLD_LOCAL)
        }
    }

    public static func ghosttyAppDependencyPaths(for path: String) -> [String] {
        let suffix = "/Contents/MacOS/ghostty"
        guard path.hasSuffix(suffix) else {
            return []
        }

        let appRoot = String(path.dropLast(suffix.count))
        return [
            "\(appRoot)/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
        ]
    }
}

import CGhosttyShim
import Foundation

public enum LibGhosttyDynamicLibraryError: Error, Equatable, Sendable {
    case unavailable(LibGhosttyRuntimeStatus)
    case initializationFailed(Int32)
    case appCreationFailed(String)
    case surfaceCreationFailed(String)
    case textReadFailed(String)
}

public struct LibGhosttySurfaceDescriptor: Equatable {
    public var platformView: UnsafeMutableRawPointer?
    public var scaleFactor: Double
    public var fontSize: Float
    public var workingDirectory: String
    public var command: String?
    public var environment: [String: String]

    public init(
        platformView: UnsafeMutableRawPointer?,
        scaleFactor: Double,
        fontSize: Float = 13,
        workingDirectory: String,
        command: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.platformView = platformView
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
    }
}

public final class LibGhosttyDynamicLibrary: @unchecked Sendable {
    private let library: OpaquePointer
    private static let initializationState = LibGhosttyInitializationState()
    public let status: LibGhosttyRuntimeStatus

    deinit {
        balagan_ghostty_library_close(library)
    }

    public static func load(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LibGhosttyDynamicLibrary {
        if let library = open(path: nil) {
            return LibGhosttyDynamicLibrary(
                library: library,
                status: LibGhosttyRuntimeStatus(
                    isAvailable: true,
                    source: .linkedProcess,
                    resolvedSymbols: LibGhosttyRuntimeProbe.requiredSymbols,
                    missingSymbols: []
                )
            )
        }

        let paths = LibGhosttyRuntimeProbe.searchPaths(explicitPath: explicitPath, environment: environment)
        var diagnostics: [String] = []

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                diagnostics.append("\(path): missing")
                continue
            }

            var library: OpaquePointer?
            var error = ErrorBuffer()
            let result = path.withCString { pathPointer in
                error.withMutableCString { errorPointer, errorLength in
                    balagan_ghostty_library_open(pathPointer, &library, errorPointer, errorLength)
                }
            }
            if result == 0, let library {
                Self.exportResourcesDirectory(forLibraryPath: path)
                GhosttyConfigOverrides.install()
                return LibGhosttyDynamicLibrary(
                    library: library,
                    status: LibGhosttyRuntimeStatus(
                        isAvailable: true,
                        source: .dynamicLibrary,
                        path: path,
                        checkedPaths: paths,
                        resolvedSymbols: LibGhosttyRuntimeProbe.requiredSymbols,
                        missingSymbols: []
                    )
                )
            }

            diagnostics.append("\(path): \(error.message)")
        }

        throw LibGhosttyDynamicLibraryError.unavailable(LibGhosttyRuntimeStatus(
            isAvailable: false,
            source: .unavailable,
            checkedPaths: paths,
            missingSymbols: LibGhosttyRuntimeProbe.requiredSymbols,
            diagnostic: diagnostics.joined(separator: "\n")
        ))
    }

    /// Ghostty locates its bundled resources (color themes like `jubi`, shell-integration scripts)
    /// relative to the *running* executable — which here is the host app, not Ghostty.app — so theme
    /// and shell-integration lookups fail and terminals render with default colors instead of the
    /// user's theme. Point Ghostty at the resources dir inside the Ghostty.app we dlopen'd, derived
    /// from the library path (…/Contents/MacOS/ghostty → …/Contents/Resources/ghostty). Must run
    /// before any config is loaded/finalized. An explicit GHOSTTY_RESOURCES_DIR is respected.
    private static func exportResourcesDirectory(forLibraryPath libraryPath: String) {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"], existing.isEmpty == false {
            return
        }
        let macosDir = (libraryPath as NSString).deletingLastPathComponent      // …/Contents/MacOS
        let contentsDir = (macosDir as NSString).deletingLastPathComponent      // …/Contents
        let resources = (contentsDir as NSString).appendingPathComponent("Resources/ghostty")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resources, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
    }

    private static func open(path: String?) -> OpaquePointer? {
        var library: OpaquePointer?
        var error = ErrorBuffer()
        let result = error.withMutableCString { errorPointer, errorLength in
            balagan_ghostty_library_open(path, &library, errorPointer, errorLength)
        }
        guard result == 0 else {
            return nil
        }
        return library
    }

    private init(library: OpaquePointer, status: LibGhosttyRuntimeStatus) {
        self.library = library
        self.status = status
    }

    public func initialize(arguments: [String] = ["Balagan"]) throws {
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        let result = balagan_ghostty_initialize(library, UInt(arguments.count), &argv)
        guard result == 0 else {
            throw LibGhosttyDynamicLibraryError.initializationFailed(result)
        }
    }

    public func initializeOnce(arguments: [String] = ["Balagan"]) throws {
        Self.initializationState.lock.lock()
        defer { Self.initializationState.lock.unlock() }

        guard Self.initializationState.hasInitialized == false else {
            return
        }

        try initialize(arguments: arguments)
        Self.initializationState.hasInitialized = true
    }

    public func createApp() throws -> LibGhosttyAppHandle {
        var app: OpaquePointer?
        var error = ErrorBuffer()
        let result = error.withMutableCString { errorPointer, errorLength in
            balagan_ghostty_create_app(library, &app, errorPointer, errorLength)
        }
        guard result == 0, let app else {
            throw LibGhosttyDynamicLibraryError.appCreationFailed(error.message)
        }

        return LibGhosttyAppHandle(app: app)
    }

    /// The `font-size` from the user's Ghostty config (default files), or `nil` if unset/unavailable.
    /// Lets the app adopt the user's preferred terminal font size as its base size.
    public func configuredFontSize() -> Float? {
        let value = balagan_ghostty_library_config_font_size(library)
        guard value > 0 else {
            return nil
        }
        return Float(value)
    }
}

private final class LibGhosttyInitializationState: @unchecked Sendable {
    let lock = NSLock()
    var hasInitialized = false
}

public final class LibGhosttyAppHandle: @unchecked Sendable {
    private let app: OpaquePointer

    fileprivate init(app: OpaquePointer) {
        self.app = app
    }

    deinit {
        balagan_ghostty_app_free(app)
    }

    public func tick() {
        balagan_ghostty_app_tick(app)
    }

    public func createSurface(descriptor: LibGhosttySurfaceDescriptor) throws -> LibGhosttySurfaceHandle {
        _ = LibGhosttyEventBridge.install
        let context = LibGhosttySurfaceContext()
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        var surface: OpaquePointer?
        var error = ErrorBuffer()

        let result = try withDescriptorPointers(descriptor) { commandPointer, cwdPointer, envPointer, envCount in
            error.withMutableCString { errorPointer, errorLength in
                balagan_ghostty_app_create_surface(
                    app,
                    descriptor.platformView,
                    descriptor.scaleFactor,
                    descriptor.fontSize,
                    cwdPointer,
                    commandPointer,
                    envPointer,
                    envCount,
                    contextPointer,
                    &surface,
                    errorPointer,
                    errorLength
                )
            }
        }

        guard result == 0, let surface else {
            throw LibGhosttyDynamicLibraryError.surfaceCreationFailed(error.message)
        }

        return LibGhosttySurfaceHandle(surface: surface, context: context)
    }
}

struct ErrorBuffer {
    private var bytes = [CChar](repeating: 0, count: 1_024)

    var message: String {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, baseAddress.pointee != 0 else {
                return "unknown libghostty error"
            }
            return String(cString: baseAddress)
        }
    }

    mutating func withMutableCString<T>(
        _ body: (UnsafeMutablePointer<CChar>?, Int) -> T
    ) -> T {
        bytes.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }
}

private func withDescriptorPointers<T>(
    _ descriptor: LibGhosttySurfaceDescriptor,
    _ body: (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>,
        UnsafePointer<balagan_ghostty_env_var_t>?,
        Int
    ) throws -> T
) throws -> T {
    guard let cwdPointer = strdup(descriptor.workingDirectory) else {
        throw LibGhosttyDynamicLibraryError.surfaceCreationFailed("failed to allocate working directory")
    }
    let commandPointer = descriptor.command.flatMap { strdup($0) }
    let envPointers = descriptor.environment.map {
        balagan_ghostty_env_var_t(key: strdup($0.key), value: strdup($0.value))
    }

    defer {
        free(cwdPointer)
        if let commandPointer {
            free(commandPointer)
        }
        for env in envPointers {
            free(UnsafeMutableRawPointer(mutating: env.key))
            free(UnsafeMutableRawPointer(mutating: env.value))
        }
    }

    if envPointers.isEmpty {
        return try body(
            commandPointer.map { UnsafePointer($0) },
            UnsafePointer(cwdPointer),
            nil,
            0
        )
    }

    return try envPointers.withUnsafeBufferPointer { buffer in
        try body(
            commandPointer.map { UnsafePointer($0) },
            UnsafePointer(cwdPointer),
            buffer.baseAddress,
            buffer.count
        )
    }
}

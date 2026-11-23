import CGhosttyShim
import Foundation

/// Is the libghostty we loaded a release the shim has action-tag numbers for?
///
/// The shim reads those numbers (`SET_TITLE`, `RING_BELL`, …) off `include/ghostty.h`, one row per
/// Ghostty release, and Ghostty.app updates itself through Sparkle underneath us. A release that
/// renumbers the enum doesn't error: under the old numbers a payload is read as the wrong type,
/// which crashed the app when 1.4 arrived. So the shim routes no terminal events for a release it
/// has no row for, and at launch the app says so. The same major.minor as a verified release is
/// compatible (patch releases don't touch the C API); anything else means titles, folders, bells,
/// terminal notifications and search are off until the shim gets a row for it.
public enum LibGhosttyVersionCompatibility: Equatable, Sendable {
    case compatible(reported: String)
    case mismatch(reported: String, verified: [String])
    /// libghostty reported no version (no `ghostty_info`, or an unparsable string).
    case unknown(verified: [String])

    /// The version libghostty reported, when it did.
    public var reported: String? {
        switch self {
        case .compatible(let reported), .mismatch(let reported, _):
            return reported
        case .unknown:
            return nil
        }
    }

    /// One line for the log and `balagan status`; nil when compatible.
    public var warning: String? {
        switch self {
        case .compatible:
            return nil
        case .mismatch(let reported, let verified):
            return "libghostty \(reported) is loaded, but Balagan has only been verified against Ghostty "
                + "\(verified.joined(separator: ", ")). Terminal titles, bells, working folders and search "
                + "are off until Balagan is updated for \(reported)."
        case .unknown(let verified):
            return "libghostty did not report its version (no ghostty_info), so terminal titles, bells, "
                + "working folders and search are off. Balagan is verified against Ghostty "
                + "\(verified.joined(separator: ", "))."
        }
    }
}

public enum LibGhosttyVersionCheck {
    /// The Ghostty releases the shim has action-tag numbers for, oldest first (the table in
    /// `CGhosttyShim.c`).
    public static let verifiedVersions: [String] = {
        var versions: [String] = []
        while let version = balagan_ghostty_verified_version(versions.count) {
            versions.append(String(cString: version))
        }
        return versions
    }()

    public struct MajorMinor: Equatable, Sendable {
        public var major: Int
        public var minor: Int

        public init(major: Int, minor: Int) {
            self.major = major
            self.minor = minor
        }
    }

    public static func check(
        reported: String?,
        verified: [String] = verifiedVersions
    ) -> LibGhosttyVersionCompatibility {
        let trimmed = reported?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let reportedPair = majorMinor(trimmed) else {
            return .unknown(verified: verified)
        }
        guard verified.contains(where: { majorMinor($0) == reportedPair }) else {
            return .mismatch(reported: trimmed, verified: verified)
        }
        return .compatible(reported: trimmed)
    }

    /// The leading `<major>.<minor>` of a version string: "1.3.1" and "1.4.0-dev+39943e7" both parse,
    /// anything that doesn't start with two dotted numbers is nil.
    public static func majorMinor(_ version: String) -> MajorMinor? {
        let parts = version.split(whereSeparator: { !$0.isNumber && $0 != "." })
        guard let numeric = parts.first else { return nil }
        let components = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1])
        else {
            return nil
        }
        return MajorMinor(major: major, minor: minor)
    }
}

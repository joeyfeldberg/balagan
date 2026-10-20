import CGhosttyShim
import Foundation

/// Does the libghostty we loaded match the `include/ghostty.h` the shim was written against?
///
/// The shim hard-codes the action-tag numbers (`GHOSTTY_ACTION_SET_TITLE` = 32, `RING_BELL` = 50, …)
/// from one header, and Ghostty.app updates itself through Sparkle underneath us. A release that
/// renumbers that enum doesn't error; titles, bells, working folders and search counts just stop
/// arriving, and with them the agents' working-state. So at launch the app compares what
/// `ghostty_info()` reports with the pin. The same major.minor is compatible (patch releases don't
/// touch the C API); anything else is a mismatch worth a warning, so the tags get re-verified and
/// the pin bumped.
public enum LibGhosttyVersionCompatibility: Equatable, Sendable {
    case compatible(reported: String)
    case mismatch(reported: String, pinned: String)
    /// libghostty reported no version (no `ghostty_info`, or an unparsable string).
    case unknown(pinned: String)

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
        case .mismatch(let reported, let pinned):
            return "libghostty \(reported) is loaded, but Balagan's shim is pinned to Ghostty \(pinned). "
                + "Terminal titles, bells, working folders and search may not reach Balagan "
                + "until its action tags are re-verified against \(reported)."
        case .unknown(let pinned):
            return "libghostty did not report its version (no ghostty_info); Balagan's shim is pinned to Ghostty \(pinned)."
        }
    }
}

public enum LibGhosttyVersionCheck {
    /// The Ghostty release the shim's action tags were taken from (`BALAGAN_GHOSTTY_PINNED_VERSION`
    /// in `CGhosttyShim.h`, next to the tags).
    public static let pinnedVersion: String = BALAGAN_GHOSTTY_PINNED_VERSION

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
        pinned: String = pinnedVersion
    ) -> LibGhosttyVersionCompatibility {
        let trimmed = reported?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let reportedPair = majorMinor(trimmed) else {
            return .unknown(pinned: pinned)
        }
        guard let pinnedPair = majorMinor(pinned), pinnedPair == reportedPair else {
            return .mismatch(reported: trimmed, pinned: pinned)
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

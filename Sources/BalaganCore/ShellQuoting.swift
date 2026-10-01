import Foundation

public extension String {
    /// POSIX single-quote quoting: wraps the value in single quotes and escapes any embedded
    /// single quote as `'\''`. Safe to interpolate into a `/bin/sh` command line.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

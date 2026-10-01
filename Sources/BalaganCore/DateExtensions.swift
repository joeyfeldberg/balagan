import Foundation

public extension Date {
    /// Whole milliseconds since the Unix epoch (truncated toward zero).
    var millisecondsSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1000)
    }
}

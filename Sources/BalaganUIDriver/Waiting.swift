import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    /// Polls `probe` until it returns a non-nil value or `timeout` elapses, returning nil on
    /// timeout without any side effects. Callers that need a dump-on-timeout + throw use
    /// `waitUntil`; the pixel-snapshot path polls directly so it can stay dump-free.
    func poll<T>(
        timeout: TimeInterval,
        interval: UInt32 = 100,
        _ probe: () -> T?
    ) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = probe() {
                return value
            }
            sleep(milliseconds: interval)
        } while Date() < deadline

        return nil
    }

    /// Shared deadline loop: polls `probe` every 100ms, and on timeout writes the lookup
    /// accessibility dump before throwing `DriverError.timeout(timeoutMessage)`.
    @discardableResult
    func waitUntil<T>(
        timeout: TimeInterval,
        timeoutMessage: @autoclosure () -> String,
        _ probe: () -> T?
    ) throws -> T {
        if let value = poll(timeout: timeout, probe) {
            return value
        }

        try? writeAccessibilityDump(fileName: flow.lookupDumpName)
        throw DriverError.timeout(timeoutMessage())
    }

    @discardableResult
    func waitForElement(identifier: String, timeout: TimeInterval) throws -> AXUIElement {
        try waitUntil(timeout: timeout, timeoutMessage: identifier) {
            findElement(identifier: identifier)
        }
    }

    @discardableResult
    func waitForAnyElement(identifiers: [String], timeout: TimeInterval) throws -> AXUIElement {
        try waitUntil(timeout: timeout, timeoutMessage: "one of: \(identifiers.joined(separator: ", "))") {
            for identifier in identifiers {
                if let element = findElement(identifier: identifier) {
                    return element
                }
            }
            return nil
        }
    }

    func waitForElementToDisappear(identifier: String, timeout: TimeInterval) throws {
        try waitUntil(timeout: timeout, timeoutMessage: "\(identifier) to disappear") { () -> Bool? in
            findElement(identifier: identifier) == nil ? true : nil
        }
    }

    func sleep(milliseconds: UInt32) {
        usleep(milliseconds * 1_000)
    }
}

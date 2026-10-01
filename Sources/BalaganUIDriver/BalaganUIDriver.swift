import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

private struct DriverArguments {
    var pid: pid_t?
    var artifactDirectory: URL?
    var flow: DriverFlow = .nativeFlow

    static func parse(_ arguments: [String]) throws -> DriverArguments {
        var result = DriverArguments()

        for index in arguments.indices {
            switch arguments[index] {
            case "--pid" where arguments.indices.contains(index + 1):
                guard let pid = Int32(arguments[index + 1]) else {
                    throw DriverError.invalidArguments("invalid pid: \(arguments[index + 1])")
                }
                result.pid = pid
            case "--artifact-dir" where arguments.indices.contains(index + 1):
                result.artifactDirectory = URL(fileURLWithPath: arguments[index + 1])
            case "--flow" where arguments.indices.contains(index + 1):
                result.flow = try DriverFlow(argument: arguments[index + 1])
            default:
                continue
            }
        }

        guard result.pid != nil else {
            throw DriverError.invalidArguments("--pid is required")
        }
        guard result.artifactDirectory != nil else {
            throw DriverError.invalidArguments("--artifact-dir is required")
        }

        return result
    }
}

@main
private enum BalaganUIDriver {
    static func main() {
        do {
            if CommandLine.arguments.contains("--send-session-report") {
                try SessionReportSender.run(arguments: CommandLine.arguments)
                return
            }

            let arguments = try DriverArguments.parse(CommandLine.arguments)
            let driver = NativeFlowDriver(
                pid: arguments.pid!,
                artifactDirectory: arguments.artifactDirectory!,
                flow: arguments.flow
            )
            try driver.run()
        } catch {
            let message = (error as? DriverError)?.description ?? String(describing: error)
            fputs("BalaganUIDriver: \(message)\n", stderr)
            if let arguments = try? DriverArguments.parse(CommandLine.arguments),
               let artifactDirectory = arguments.artifactDirectory {
                try? NativeFlowDriver.writeArtifact(
                    artifactDirectory: artifactDirectory,
                    fileName: arguments.flow.errorArtifactName,
                    text: message + "\n"
                )
            }
            exit(1)
        }
    }
}

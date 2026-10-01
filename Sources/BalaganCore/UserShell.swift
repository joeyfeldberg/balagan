import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum UserShell {
    public static func defaultShellPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        accountShell: @autoclosure () -> String? = currentAccountShell()
    ) -> String {
        if let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           shell.isEmpty == false {
            return shell
        }

        if let shell = accountShell()?.trimmingCharacters(in: .whitespacesAndNewlines),
           shell.isEmpty == false {
            return shell
        }

        return "/bin/sh"
    }

    public static func currentAccountShell() -> String? {
        #if os(macOS) || os(Linux)
        guard let passwd = getpwuid(getuid()),
              let shell = passwd.pointee.pw_shell
        else {
            return nil
        }
        return String(cString: shell)
        #else
        return nil
        #endif
    }
}

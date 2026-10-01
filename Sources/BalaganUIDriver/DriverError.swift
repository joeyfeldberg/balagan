import ApplicationServices
import Foundation

enum DriverError: Error, CustomStringConvertible {
    case accessibilityNotTrusted
    case invalidArguments(String)
    case missingElement(String)
    case actionFailed(String, AXError)
    case textEntryFailed(String, AXError)
    case pickerSelectionFailed(String, String)
    case timeout(String)
    case artifactWriteFailed(Error)
    case unsupportedPhysicalKey(Character)
    case screenshotFailed(String)
    case staleRenderedPixels(String)

    var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility access is not trusted for this terminal process. Grant Accessibility permission to the shell/Codex host in System Settings > Privacy & Security > Accessibility, then rerun the smoke."
        case .invalidArguments(let message):
            return message
        case .missingElement(let identifier):
            return "missing accessibility element: \(identifier)"
        case .actionFailed(let identifier, let error):
            return "AX press failed for \(identifier): \(error.rawValue)"
        case .textEntryFailed(let identifier, let error):
            return "AX text entry failed for \(identifier): \(error.rawValue)"
        case .pickerSelectionFailed(let identifier, let value):
            return "could not select \(value) in picker \(identifier)"
        case .timeout(let message):
            return "timed out waiting for \(message)"
        case .artifactWriteFailed(let error):
            return "failed to write driver artifact: \(error)"
        case .unsupportedPhysicalKey(let character):
            return "no physical key mapping for typed character: \(character)"
        case .screenshotFailed(let message):
            return "screenshot capture failed: \(message)"
        case .staleRenderedPixels(let message):
            return "terminal rendered pixels did not visibly update after typing: \(message)"
        }
    }
}

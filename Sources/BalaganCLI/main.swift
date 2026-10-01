import Foundation
import BalaganCore

// `balagan` — a thin client that drives the running Balagan app over its control socket.
// Argument parsing + the wire protocol live in BalaganCore (`ControlCLI` / `ControlSocketClient`);
// this file is just I/O and human-readable formatting.

func emitError(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func prettyJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8)
    else {
        return String(describing: object)
    }
    return string
}

/// Formats a successful `result` payload per command. Falls back to pretty JSON for anything unmapped.
func printResult(method: String, result: Any?) {
    switch method {
    case "ping":
        let version = (result as? [String: Any])?["version"] as? String
        print("pong" + (version.map { " (Balagan \($0))" } ?? ""))

    case "projects":
        let projects = (result as? [String: Any])?["projects"] as? [[String: Any]] ?? []
        if projects.isEmpty { print("No projects."); return }
        for project in projects {
            let id = project["id"] as? String ?? "?"
            let name = project["name"] as? String ?? ""
            let repo = project["repoPath"] as? String ?? ""
            print("\(id)\t\(name)\t\(repo)")
        }

    case "tasks":
        let tasks = (result as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
        if tasks.isEmpty { print("No tasks."); return }
        for task in tasks {
            let id = task["id"] as? String ?? "?"
            let title = task["title"] as? String ?? ""
            let status = task["status"] as? String ?? ""
            let running = (task["running"] as? Bool ?? false) ? "●" : ((task["live"] as? Bool ?? true) ? " " : "☾")
            let attention = (task["needsAttention"] as? Bool ?? false) ? "!" : " "
            let branch = task["branch"] as? String
            let branchSuffix = branch.map { "  [\($0)]" } ?? ""
            print("\(running)\(attention) \(status.padding(toLength: 11, withPad: " ", startingAt: 0)) \(id)\t\(title)\(branchSuffix)")
        }

    case "task.create":
        let dict = result as? [String: Any]
        print("Created task \(dict?["id"] as? String ?? "?")")

    case "task.open", "open":
        let dict = result as? [String: Any]
        print("Opened \(dict?["opened"] as? String ?? "?")")

    case "task.state":
        let dict = result as? [String: Any] ?? [:]
        print("\(dict["id"] as? String ?? "?") is \(dict["state"] as? String ?? "?")")

    case "status":
        let dict = result as? [String: Any] ?? [:]
        let selectedTask = dict["selectedTask"] as? String ?? "(none)"
        let selectedProject = dict["selectedProject"] as? String ?? "(none)"
        let running = dict["running"] as? [String] ?? []
        print("Selected project: \(selectedProject)")
        print("Selected task:    \(selectedTask)")
        print("Tasks: \(dict["taskCount"] as? Int ?? 0)   Projects: \(dict["projectCount"] as? Int ?? 0)")
        print("Running agents: \(running.isEmpty ? "(none)" : running.joined(separator: ", "))")
        if let notifications = dict["notifications"] as? String {
            print("Notifications:  \(notifications)")
        }

    case "autosleep":
        let dict = result as? [String: Any] ?? [:]
        let minutes = dict["idleMinutes"] as? Int ?? 0
        print("Auto-sleep: \(minutes == 0 ? "off (memory pressure only)" : "after \(minutes)m idle")")
        let tasks = dict["tasks"] as? [[String: Any]] ?? []
        if tasks.isEmpty { print("No tasks with live terminals.") }
        for task in tasks {
            let id = task["id"] as? String ?? "?"
            let idle = (task["idleSeconds"] as? Int ?? 0) / 60
            let surfaces = (task["surfaces"] as? [String] ?? []).joined(separator: ",")
            var why: [String] = []
            if task["onScreen"] as? Bool == true { why.append("on screen") }
            if task["unseenResult"] as? Bool == true { why.append("unseen result") }
            let verdict = (task["safe"] as? Bool ?? false) ? "can sleep" : "stays awake"
            let detail = why.isEmpty ? "" : " (\(why.joined(separator: ", ")))"
            print("  \(id)\tidle \(idle)m\t[\(surfaces)]\t\(verdict)\(detail)")
        }
        let would = dict["wouldSleep"] as? [String] ?? []
        let slept = dict["slept"] as? [String] ?? []
        print(slept.isEmpty
            ? "Would sleep now: \(would.isEmpty ? "nothing" : would.joined(separator: ", "))"
            : "Slept: \(slept.joined(separator: ", "))")

    default:
        if let result { print(prettyJSON(result)) } else { print("ok") }
    }
}

/// Blocks until a task's aggregate agent state reaches one of the `--until` states, by polling the
/// `task.state` command. This is a client-side loop on purpose: the app answers each poll on the main
/// actor synchronously, so a long wait never blocks the UI. An orchestrator agent uses it to wait for
/// a sub-agent it directed to settle. Never returns — exits 0 on match, 1 on timeout / error.
func runWait(_ invocation: ControlInvocation) -> Never {
    let socketPath = invocation.socketPath ?? ControlSocket.defaultPath()
    let params = invocation.request.params
    guard let id = params["id"]?.nilIfBlank else {
        emitError("balagan: wait requires a task id")
    }
    guard let untilStates = TaskAgentState.parseUntil(params["until"]) else {
        let names = TaskAgentState.allCases.map(\.rawValue).joined(separator: ", ")
        emitError("balagan: invalid --until (expected a comma-separated list of: \(names))")
    }
    let untilSet = Set(untilStates.map(\.rawValue))
    let timeoutMs = params["timeout"].flatMap { Int($0) }
    let stateRequest = ControlRequest(method: "task.state", params: ["id": id])
    let start = Date()
    let pollInterval: TimeInterval = 0.15

    while true {
        let data: Data
        do {
            data = try ControlSocketClient.send(request: stateRequest, socketPath: socketPath)
        } catch {
            emitError("balagan: could not reach Balagan at \(socketPath)\n  \(error)\n  Is the app running?")
        }
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            emitError("balagan: empty or malformed response from the app at \(socketPath)")
        }
        if (response["ok"] as? Bool ?? false) == false {
            emitError("balagan: \(response["error"] as? String ?? "unknown error")")
        }
        let state = (response["result"] as? [String: Any])?["state"] as? String ?? "none"
        if untilSet.contains(state) {
            if invocation.rawJSON {
                print(prettyJSON(response))
            } else {
                print("\(id) is \(state)")
            }
            exit(0)
        }
        if let timeoutMs, Date().timeIntervalSince(start) * 1000 >= Double(timeoutMs) {
            let wanted = untilStates.map(\.rawValue).joined(separator: "/")
            emitError("balagan: timed out after \(timeoutMs)ms waiting for \(id) to be \(wanted) (last: \(state))")
        }
        Thread.sleep(forTimeInterval: pollInterval)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch ControlCLI.parse(arguments) {
case .help:
    print(ControlCLI.usage)
    exit(0)

case let .error(message):
    emitError("balagan: \(message)")

case let .invocation(invocation):
    // `wait` is client-driven: poll `task.state` in a loop rather than a single request/response.
    if invocation.request.method == "task.wait" {
        runWait(invocation)
    }

    let socketPath = invocation.socketPath ?? ControlSocket.defaultPath()
    let responseData: Data
    do {
        responseData = try ControlSocketClient.send(request: invocation.request, socketPath: socketPath)
    } catch {
        emitError("balagan: could not reach Balagan at \(socketPath)\n  \(error)\n  Is the app running?")
    }

    guard let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
        emitError("balagan: empty or malformed response from the app at \(socketPath)")
    }

    let succeeded = response["ok"] as? Bool ?? false
    if invocation.rawJSON {
        print(prettyJSON(response))
        exit(succeeded ? 0 : 1)
    }
    if succeeded {
        printResult(method: invocation.request.method, result: response["result"])
        exit(0)
    } else {
        emitError("balagan: \(response["error"] as? String ?? "unknown error")")
    }
}

import Darwin
import Foundation

/// A process listening on a TCP port, as seen by `ListeningPortScanner`.
public struct ListeningProcess: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var workingDirectory: String?
    public var ports: [Int]

    public init(pid: Int32, parentPID: Int32, name: String, workingDirectory: String?, ports: [Int]) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.workingDirectory = workingDirectory
        self.ports = ports
    }
}

/// A local server a task's terminal started: `localhost:<port>`, and the process serving it.
public struct DevServerPort: Hashable, Sendable, Comparable {
    public var port: Int
    public var processName: String

    public init(port: Int, processName: String) {
        self.port = port
        self.processName = processName
    }

    public var url: URL { URL(string: "http://localhost:\(port)")! }

    public static func < (lhs: DevServerPort, rhs: DevServerPort) -> Bool { lhs.port < rhs.port }
}

/// Which task each local server belongs to. Pure: the scanner supplies the processes.
public enum DevServerPorts {
    /// The agents themselves (and the IDE / MCP helpers they open) aren't dev servers.
    public static let excludedProcessNames: Set<String> = ["claude", "codex", "opencode", "pi", "BalaganApp", "balagan-agent"]

    /// Ports at or above this are the OS's ephemeral range: things like MCP helpers and debuggers
    /// that grab a random port, never a dev server you'd open.
    public static let ephemeralPortStart = 49152

    /// Assigns each listening port to the task whose directory contains the listening process's
    /// working directory (the most specific directory wins). A server shared by several tasks on the
    /// same checkout shows on each of them.
    ///
    /// - Parameter taskDirectories: each task's directories (its worktree / repo, plus its terminals'
    ///   current folders). Pass only tasks with live terminals.
    public static func assign(
        processes: [ListeningProcess],
        taskDirectories: [String: [String]]
    ) -> [String: [DevServerPort]] {
        let candidates = taskDirectories.flatMap { task, directories in
            directories.map { (task: task, directory: normalized($0)) }
        }.filter { $0.directory != "/" && $0.directory.isEmpty == false }

        var result: [String: Set<DevServerPort>] = [:]
        for process in processes where excludedProcessNames.contains(process.name) == false {
            guard let cwd = process.workingDirectory.map(normalized) else { continue }
            let matches = candidates.filter { cwd == $0.directory || cwd.hasPrefix($0.directory + "/") }
            guard let longest = matches.map(\.directory.count).max() else { continue }
            for match in matches where match.directory.count == longest {
                for port in process.ports where port > 0 && port < ephemeralPortStart {
                    result[match.task, default: []].insert(DevServerPort(port: port, processName: process.name))
                }
            }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Every process descended from `root` (the app: every terminal is its child).
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }
        var found: Set<Int32> = []
        var queue = children[root] ?? []
        while let pid = queue.popLast() {
            guard found.insert(pid).inserted else { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return found
    }

    /// Expands `~`, resolves symlinks the way the kernel reports a process's folder (`/tmp` is
    /// `/private/tmp`), and drops a trailing slash.
    static func normalized(_ path: String) -> String {
        var path = (path as NSString).expandingTildeInPath
        if let resolved = realpath(path, nil) {
            path = String(cString: resolved)
            free(resolved)
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Finds TCP listeners among the app's descendant processes with libproc, no `lsof`: the process
/// table for parentage, then each descendant's sockets and working directory.
public enum ListeningPortScanner {
    public static func scan(root: Int32 = getpid()) -> [ListeningProcess] {
        let table = processTable()
        let parents = table.mapValues(\.parent)
        return DevServerPorts.descendants(of: root, parents: parents).compactMap { pid in
            let ports = listeningPorts(pid: pid)
            guard ports.isEmpty == false else { return nil }
            return ListeningProcess(
                pid: pid,
                parentPID: parents[pid] ?? 0,
                name: table[pid]?.name ?? "",
                workingDirectory: workingDirectory(pid: pid),
                ports: ports
            )
        }
    }

    /// Every process's parent and name, from `sysctl(KERN_PROC_ALL)` — what `ps` uses. libproc's
    /// `PROC_PIDTBSDINFO` refuses root-owned processes, and every terminal runs under
    /// `/usr/bin/login` (root), which would cut the app's process tree in two.
    static func processTable() -> [Int32: (parent: Int32, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [:] }
        var table: [Int32: (parent: Int32, name: String)] = [:]
        for process in processes.prefix(size / stride) {
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            table[process.kp_proc.p_pid] = (process.kp_eproc.e_ppid, name)
        }
        return table
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func listeningPorts(pid: Int32) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var ports: Set<Int> = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}

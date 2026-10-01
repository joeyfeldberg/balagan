import Foundation

/// The files that let any Balagan terminal run agents the integrated way, even when you just type
/// `codex` at the prompt. All generated here (pure, tested) and written by `AgentIntegrationInstaller`
/// under `~/.balagan`:
///
/// - `shims/<command>`: one per agent. Inside a Balagan terminal it runs the agent through
///   `balagan-agent`, which reports the session so the tab becomes an agent tab; anywhere else (or
///   when already inside an agent) it runs the real binary.
/// - `shell/zsh/.zshenv …`: a `ZDOTDIR` that sources your own zsh startup files, then keeps the shims
///   first on `PATH` — your `.zshrc` (Homebrew, mise, `~/.local/bin`) would otherwise put the real
///   binaries in front of them, and mise rewrites `PATH` at every prompt, so the shims are re-asserted
///   in `precmd`, after everyone else's hooks.
/// - `integrations/pi/balagan.js`, `integrations/opencode/plugin/balagan.js`: the pi extension and
///   OpenCode plugin that report working state and the session (via `balagan-agent report`).
public enum AgentIntegrationFiles {
    // MARK: - Shims

    public static func shim(for profile: AgentProfile) -> String {
        let command = profile.command
        let id = profile.id
        return """
        #!/bin/sh
        # Balagan shim for \(command). Inside a Balagan terminal it runs \(command) through the agent
        # wrapper, so the tab becomes an agent tab (state, notifications, resume). Everywhere else — or
        # when an agent is already running this one — it runs the real \(command). Generated; don't edit.
        if [ -n "$BALAGAN_SURFACE_ID" ] && [ -z "$BALAGAN_AGENT_ACTIVE" ] && [ -x "$BALAGAN_AGENT_WRAPPER" ]; then
          exec "$BALAGAN_AGENT_WRAPPER" '\(id)' "$@"
        fi
        balagan_shim_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
        IFS=:
        for balagan_dir in $PATH; do
          [ -z "$balagan_dir" ] && continue
          [ "$(CDPATH= cd -- "$balagan_dir" 2>/dev/null && pwd -P)" = "$balagan_shim_dir" ] && continue
          if [ -x "$balagan_dir/\(command)" ] && [ ! -d "$balagan_dir/\(command)" ]; then
            exec "$balagan_dir/\(command)" "$@"
          fi
        done
        echo "\(command): command not found" >&2
        exit 127

        """
    }

    // MARK: - zsh startup chain

    /// Our `ZDOTDIR` files, by name. Each switches `ZDOTDIR` to yours, sources your file of the same
    /// name, remembers where your `ZDOTDIR` ended up (your `.zshenv` may move it), and switches back so
    /// zsh keeps reading ours. The last file zsh reads hands `ZDOTDIR` back to you for good.
    public static func zshFiles() -> [String: String] {
        let header = "# Balagan: runs your zsh startup files, then keeps Balagan's agent shims first on PATH. Generated; don't edit.\n"
        func chain(_ name: String) -> String {
            """
            typeset -g _balagan_zdotdir="${_balagan_zdotdir:-$ZDOTDIR}"
            ZDOTDIR="${_balagan_user_zdotdir:-$HOME}"
            [[ -r "$ZDOTDIR/\(name)" ]] && builtin source "$ZDOTDIR/\(name)"
            typeset -g _balagan_user_zdotdir="${ZDOTDIR:-$HOME}"
            ZDOTDIR="$_balagan_zdotdir"

            """
        }
        let restore = """
        _balagan_restore_zdotdir() {
          if [[ "$_balagan_user_zdotdir" == "$HOME" ]]; then builtin unset ZDOTDIR; else ZDOTDIR="$_balagan_user_zdotdir"; fi
          builtin unset _balagan_zdotdir
        }

        """
        let prepend = """
        _balagan_prepend_shims() {
          [[ -n "$BALAGAN_SHIMS_DIR" && -d "$BALAGAN_SHIMS_DIR" ]] || return 0
          path=("$BALAGAN_SHIMS_DIR" ${path:#$BALAGAN_SHIMS_DIR})
        }

        """
        let zshenv = header + """
        typeset -g _balagan_zdotdir="$ZDOTDIR"
        typeset -g _balagan_user_zdotdir="${BALAGAN_USER_ZDOTDIR:-$HOME}"

        """ + chain(".zshenv") + restore + """
        # A non-interactive, non-login zsh (`zsh -c …`) reads nothing after .zshenv.
        if [[ ! -o interactive && ! -o login ]]; then _balagan_restore_zdotdir; fi

        """
        let zprofile = header + chain(".zprofile")
        let zshrc = header + chain(".zshrc") + prepend + """
        _balagan_prepend_shims
        autoload -Uz add-zsh-hook && add-zsh-hook precmd _balagan_prepend_shims
        # A non-login interactive zsh reads no .zlogin, so hand ZDOTDIR back now.
        if [[ ! -o login ]]; then _balagan_restore_zdotdir; fi

        """
        let zlogin = header + chain(".zlogin") + "_balagan_restore_zdotdir\n"
        return [".zshenv": zshenv, ".zprofile": zprofile, ".zshrc": zshrc, ".zlogin": zlogin]
    }

    // MARK: - pi extension

    public static let piExtension = """
    // Balagan integration for pi. Loaded with `pi --extension` by Balagan's agent wrapper; reports
    // the session and the agent's working state (running / waiting for you / idle) to Balagan.
    // Generated; don't edit.
    import { spawn } from "node:child_process";

    const wrapper = process.env.BALAGAN_AGENT_WRAPPER;

    function report(...args) {
      if (!wrapper || !process.env.BALAGAN_SURFACE_ID) return;
      try {
        const child = spawn(wrapper, ["report", "pi", ...args], { stdio: "ignore" });
        child.on("error", () => {});
        child.unref();
      } catch {}
    }

    export default function (pi) {
      let running = false;
      pi.on("session_start", async (_event, ctx) => {
        const id = ctx.sessionManager?.getSessionId?.();
        const file = ctx.sessionManager?.getSessionFile?.() ?? "";
        if (id) report("session", String(id), String(file));
      });
      pi.on("agent_start", async () => { running = true; report("lifecycle", "running"); });
      pi.on("agent_settled", async () => { running = false; report("lifecycle", "idle"); });
      pi.on("ui_prompt_start", async () => report("lifecycle", "needs-input"));
      pi.on("ui_prompt_end", async () => report("lifecycle", running ? "running" : "idle"));
    }

    """

    // MARK: - OpenCode plugin

    public static let opencodePlugin = """
    // Balagan integration for OpenCode. Loaded through OPENCODE_CONFIG_DIR by Balagan's agent
    // wrapper (added to your own config, never replacing it); reports the session and the agent's
    // working state to Balagan. Subagent (child) sessions never drive the tab's state, except that a
    // permission request from one still means OpenCode is waiting on you. Generated; don't edit.
    import { spawn } from "node:child_process";

    const wrapper = process.env.BALAGAN_AGENT_WRAPPER;

    function report(...args) {
      if (!wrapper || !process.env.BALAGAN_SURFACE_ID) return;
      try {
        const child = spawn(wrapper, ["report", "opencode", ...args], { stdio: "ignore" });
        child.on("error", () => {});
        child.unref();
      } catch {}
    }

    export const Balagan = async () => {
      // A freshly started OpenCode is idle until you send it something.
      report("lifecycle", "idle");
      const children = new Set();
      let reportedSession = null;
      const noteSession = (id) => {
        if (id && !children.has(id) && id !== reportedSession) {
          reportedSession = id;
          report("session", String(id));
        }
      };
      return {
        event: async ({ event }) => {
          const p = event?.properties ?? {};
          switch (event?.type) {
            case "session.created":
            case "session.updated": {
              const info = p.info;
              if (!info) return;
              if (info.parentID) { children.add(info.id); return; }
              if (event.type === "session.created") noteSession(info.id);
              return;
            }
            case "session.status": {
              if (children.has(p.sessionID)) return;
              const type = p.status?.type;
              if (type === "busy" || type === "retry") { noteSession(p.sessionID); report("lifecycle", "running"); }
              else if (type === "idle") report("lifecycle", "idle");
              return;
            }
            case "session.idle":
              if (!children.has(p.sessionID)) report("lifecycle", "idle");
              return;
            case "permission.asked":
            case "permission.updated":
            case "question.asked":
              report("lifecycle", "needs-input");
              return;
            case "permission.replied":
            case "question.replied":
              report("lifecycle", "running");
              return;
          }
        },
      };
    };

    """
}

/// Paths under Balagan's home (`~/.balagan`) for the integration files.
public struct AgentIntegrationPaths: Equatable, Sendable {
    public var root: String

    public init(root: String = NSHomeDirectory() + "/.balagan") {
        self.root = root
    }

    public var shims: String { root + "/shims" }
    public var zsh: String { root + "/shell/zsh" }
    public var piExtension: String { root + "/integrations/pi/balagan.js" }
    /// The directory handed to OpenCode as `OPENCODE_CONFIG_DIR` (it loads `plugin/*.js` from it).
    public var opencodeConfigDir: String { root + "/integrations/opencode" }
    public var opencodePlugin: String { opencodeConfigDir + "/plugin/balagan.js" }
}

/// Writes the integration files. Idempotent: a file is only rewritten when its content changed, and
/// shims for agents that no longer have a profile are removed (only files that are ours — a shim
/// always carries the "Balagan shim" marker).
public enum AgentIntegrationInstaller {
    public static func install(paths: AgentIntegrationPaths = AgentIntegrationPaths(), profiles: [AgentProfile]) {
        let fm = FileManager.default
        for directory in [paths.shims, paths.zsh, (paths.piExtension as NSString).deletingLastPathComponent,
                          (paths.opencodePlugin as NSString).deletingLastPathComponent] {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        var wanted: Set<String> = []
        for profile in profiles where AgentProfiles.isSafeCommandName(profile.command) {
            let path = (paths.shims as NSString).appendingPathComponent(profile.command)
            wanted.insert(profile.command)
            write(AgentIntegrationFiles.shim(for: profile), to: path, executable: true)
        }
        for existing in (try? fm.contentsOfDirectory(atPath: paths.shims)) ?? [] where wanted.contains(existing) == false {
            let path = (paths.shims as NSString).appendingPathComponent(existing)
            if let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains("Balagan shim for") {
                try? fm.removeItem(atPath: path)
            }
        }

        for (name, content) in AgentIntegrationFiles.zshFiles() {
            write(content, to: (paths.zsh as NSString).appendingPathComponent(name), executable: false)
        }
        write(AgentIntegrationFiles.piExtension, to: paths.piExtension, executable: false)
        write(AgentIntegrationFiles.opencodePlugin, to: paths.opencodePlugin, executable: false)
    }

    private static func write(_ content: String, to path: String, executable: Bool) {
        if (try? String(contentsOfFile: path, encoding: .utf8)) != content {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if executable {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }
}

/// Environment every Balagan terminal gets so typed agent commands are integrated.
public enum AgentShellEnvironment {
    /// - Parameters:
    ///   - wrapperPath: the `balagan-agent` binary, or nil (then nothing is added: no shims without a
    ///     wrapper to hand off to).
    ///   - userShell: the shell the terminal runs; only zsh gets the `ZDOTDIR` chain.
    ///   - current: the environment the terminal would otherwise start with.
    public static func variables(
        paths: AgentIntegrationPaths,
        wrapperPath: String?,
        userShell: String,
        current: [String: String]
    ) -> [String: String] {
        guard let wrapperPath, wrapperPath.isEmpty == false else { return [:] }
        var variables = [
            "BALAGAN_AGENT_WRAPPER": wrapperPath,
            "BALAGAN_SHIMS_DIR": paths.shims,
            // First on PATH from the start: enough for shells whose startup files leave PATH alone.
            "PATH": [paths.shims, current["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":"),
        ]
        if (userShell as NSString).lastPathComponent == "zsh" {
            variables["ZDOTDIR"] = paths.zsh
            if let userDotDir = current["ZDOTDIR"], userDotDir.isEmpty == false, userDotDir != paths.zsh {
                variables["BALAGAN_USER_ZDOTDIR"] = userDotDir
            }
        }
        return variables
    }
}

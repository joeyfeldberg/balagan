# Testing and UI Debug Harness

This project keeps deterministic UI testing hooks next to the macOS app shell. The harness files are app-facing contracts: storage, terminal backend selection, accessibility dumps, and screenshots are all validated through the same workflow developers use locally.

## Commands

```bash
make build
make test
make ui-test
make ui-controls-smoke
make ui-flow-smoke
make ui-native-flow-smoke
make ui-daily-driver-smoke
make terminal-input-smoke
make terminal-manual-input-smoke
make terminal-visible-typing-smoke
make terminal-navigation-smoke
make terminal-state-smoke
make hook-lifecycle-smoke
make ui-debug FIXTURE=multi-project-running
make normal-store-smoke
make first-run-smoke
make live-backend-smoke
make lint
```

Current behavior:

- `make build` and `make test` detect `Package.swift`, `.xcodeproj`, or `.xcworkspace`. If none exists, they report a skipped placeholder and exit successfully.
- `make ui-test` validates all fixture JSON, creates a UI artifact directory, seeds a temporary SQLite fixture database when `sqlite3` is available, launches the app in deterministic smoke-test mode, verifies JSON and SQLite durable snapshots, relaunches once from `Balagan.state.json`, relaunches once from `Balagan.sqlite` with fixture input removed, captures artifacts, and runs XCUITest once an Xcode project or workspace exists.
- `make ui-controls-smoke` launches the deterministic fixture app and asserts that create/edit project, create/edit task, status move, and terminal-tab create/rename/delete controls are exposed through `accessibility-tree.txt` or `ui-controls.json`.
- `make ui-flow-smoke` launches the app with `--run-ui-flow-smoke`, expects the app to run a deterministic create/edit/status/tab management flow, asserts the flow artifact and SQLite snapshot contain the edited project, edited task, final status, renamed tab, and deleted transient tab, then relaunches from SQLite without fixture or JSON state input and checks the restored observation artifact.
- `make ui-native-flow-smoke` launches the real app and uses the SwiftPM `BalaganUIDriver` executable to drive SwiftUI controls through macOS Accessibility. It creates/edits a project, creates a task, clicks the task to enter the terminal-first workspace, edits task status, creates/renames/deletes terminal tabs, verifies a terminal split, asserts the SQLite snapshot, then relaunches from SQLite.
- `make ui-daily-driver-smoke` launches the real app and uses the same native Accessibility driver with the `daily-driver` flow. It covers drag/drop task movement, task-click navigation into the terminal workspace, deleting or closing the only terminal tab into an empty-workspace or replacement state, project-click navigation back to the kanban board, context-menu task edit, and context-menu task delete. Missing controls fail the run and write driver logs plus an AX dump.
- `make terminal-input-smoke` launches the app with the live `libghostty` backend, creates a task with a default-shell terminal, focuses the embedded terminal through macOS Accessibility, types a marker command with synthesized keystrokes, writes a marker in the first tab, creates and writes to a second tab, switches back without clicking the terminal, writes another command in the first tab, and fails unless the typed marker plus the first tab's exported environment both survive.
- `make terminal-manual-input-smoke` launches the app with the live `libghostty` backend, creates a task with a default-shell terminal, clicks the embedded terminal, sends physical-style letter key events rather than paste or Unicode text injection, and verifies shell-created marker files after opening, after creating a tab, after switching back, and after navigating away/back.
- `make terminal-visible-typing-smoke` launches the app with the live `libghostty` backend, clicks the embedded terminal, sends physical-style letter key events, reads the visible `libghostty` text buffer, and fails unless the typed characters are displayed in tab 1, tab 2, after switching back, and after navigating away/back.
- `make terminal-navigation-smoke` launches the app with the live `libghostty` backend, creates two tasks, opens a task terminal, writes shell state into it, navigates back to the project board, opens another task workspace, returns to the board, reopens the original task, and fails unless the original shell state is still present.
- `make terminal-state-smoke` launches the fixture app with `--capture-terminal-state`, runs surfaces with startup/resume metadata through the PTY capture layer, persists captured scrollback to SQLite, then relaunches from SQLite and verifies the scrollback is restored.
- `make hook-lifecycle-smoke` launches the app in `--ui-test-mode` and drives the real `balagan-agent hook` binary through a `needs-input` → `running` → `idle` sequence, asserting the task state the `balagan` CLI reports at each step plus the wrapper's hook-log lines. No display or sandbox exception needed. See "Agent Lifecycle Hook Smoke" below.
- `make ui-debug FIXTURE=<name>` validates and stages the requested fixture, seeds a temporary SQLite fixture database, disables real process launch, and launches either `BALAGAN_APP_PATH`, a discoverable `.app` bundle, or the SwiftPM `BalaganApp` executable.
- `make normal-store-smoke` seeds a SQLite store from a fixture, then relaunches with no fixture path, no JSON state path, and `uiTestMode=false` while real processes are disabled. It asserts `dataSource: sqlite`.
- `make first-run-smoke` launches the SwiftPM app in normal mode with a fresh temporary SQLite database, no fixture path, no JSON state path, no fixture argument, and real processes disabled. It asserts `dataSource: empty`, zero projects, zero tasks, no `task-card-` accessibility identifiers, and a persisted SQLite snapshot.
- `make live-backend-smoke` launches the app outside UI-test mode with the harmless multi-project fixture, requires `terminalBackend.kind` to be `libghostty`, waits for the AppKit host to write a mounted surface artifact, then stops the app.
- `make lint` validates fixture JSON and shell script syntax.

## Running GUI smokes and screenshots (sandbox)

The unit tests (`swift test`) and `swift build` / `make lint` need no special environment.

Anything that drives the **GUI**, however, needs window-server / GPU / display access, and AI coding
agents run shell commands inside a **sandbox** that blocks exactly that. When the GUI is blocked you
see these symptoms (none of which mean the display is asleep, and none of which are fixed by macOS
permissions):

- `screencapture` fails with `could not create image from display`,
- libghostty surface creation returns null (`ghostty_surface_new returned null`),
- the Accessibility UI driver can only see a bare `AXApplication` (no window contents), so
  `ui-*` / `live-backend-smoke` / `terminal-*` smokes fail or time out.

So: run the GUI smokes and screenshots **unsandboxed**. In Claude Code that means
`dangerouslyDisableSandbox: true` on the Bash call. (The older `*-failure.json` artifacts attribute
these to "Accessibility permissions" — for agents the usual cause is the sandbox, not a missing
TCC grant.)

### Taking screenshots

Two reliable methods (both unsandboxed):

1. **In-process snapshot** — no display required. Launch the app with `--artifact-dir <dir>`; it
   renders the SwiftUI/AppKit tree via `cacheDisplay` to `<dir>/screenshots/board-app.png`. This does
   **not** capture the Metal-backed terminal contents (panes show the fallback scrollback view), but
   it's deterministic and works even when `screencapture` can't.

2. **Live single-window capture** — captures real pixels including live libghostty terminals:

   ```bash
   # find the app's CoreGraphics window id
   swift -e 'import CoreGraphics; for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String:Any]]) ?? [] where ((w[kCGWindowOwnerName as String] as? String) ?? "").contains("Balagan") { print(w[kCGWindowNumber as String] as? Int ?? 0) }'
   # capture just that window (no desktop, no shadow)
   screencapture -l<WINDOW_ID> -o /tmp/appwin.png
   ```

To screenshot a specific layout (e.g. a multi-pane split, or the kanban board rather than a task
workspace), craft a `BoardSnapshot` state file and launch with `--state-path`. The built-in fixtures
auto-select task[0], so to show the board set `uiState.selectedTaskID = null`. `WorkspaceLayout`
encodes as `{"tabs":{"_0":[...]}}`, `{"surface":{"_0":"id"}}`, and
`{"split":{"axis":"horizontal","children":[...]}}` (axis `horizontal` = side-by-side panes / vertical
dividers; `vertical` = stacked).

## App Launch Contract

The future macOS app should support these launch arguments:

```text
--ui-test-mode
--fixture <name>
--fixture-path <absolute path to fixture JSON>
--database <absolute path to temporary SQLite database>
--state-path <absolute path to durable board snapshot JSON>
--artifact-dir <absolute path to run artifacts>
--run-ui-flow-smoke
--capture-terminal-state
```

The harness sets these environment variables for UI tests and manual UI debugging:

```text
BALAGAN_DISABLE_REAL_PROCESSES=1
BALAGAN_FAKE_TERMINAL_OUTPUT=<fixture name>
BALAGAN_FIXTURE_PATH=<absolute path to fixture JSON>
BALAGAN_SQLITE_PATH=<absolute path to temporary SQLite database>
BALAGAN_STATE_PATH=<absolute path to durable board snapshot JSON>
BALAGAN_UI_TEST_ARTIFACT_DIR=<absolute path to run artifacts>
BALAGAN_FREEZE_TIME=2026-05-29T12:00:00Z
BALAGAN_RUN_UI_FLOW_SMOKE=1
BALAGAN_CAPTURE_TERMINAL_STATE=1
BALAGAN_LIBGHOSTTY_PATH=<optional path to libghostty.dylib for non-test launches>
```

In `--ui-test-mode`, the app must not start real agents, shells, or repo-mutating commands. Terminal panes should render deterministic fake output from the selected fixture, animations should be disabled, and timestamps should use `BALAGAN_FREEZE_TIME`.

Outside UI test mode, the app selects its terminal backend explicitly:

- `fixture` when `--ui-test-mode` is set or `BALAGAN_DISABLE_REAL_PROCESSES=1`.
- `libghostty` when the libghostty C API is linked into the process or a usable dylib is provided with `BALAGAN_LIBGHOSTTY_PATH`.
- `unavailable` when real processes are allowed but libghostty cannot be loaded.

`BalaganCore` includes a small C shim target, `CGhosttyShim`, that keeps libghostty's unstable C structs out of Swift. The Swift package does not require libghostty at build time; the shim resolves the C API at runtime with `dlopen`/`dlsym`.

When `terminalBackend.kind` is `libghostty`, the SwiftUI terminal workspace mounts an AppKit `NSView` host for the active terminal surface. That host creates the libghostty app/surface, forwards text, paste, and discrete key input, resizes the surface, and ticks/draws it on the main run loop. UI-test mode never enters this host path.

The backend selection is written into `app-ready.json` so UI tests can assert that deterministic fixture runs never accidentally use live terminals.

The app also writes a versioned `BoardSnapshot` into SQLite. Test launches pass `--database` / `BALAGAN_SQLITE_PATH`; normal app launches default to `~/Library/Application Support/Balagan/Balagan.sqlite`. Explicit fixture input wins over persisted state, explicit `--state-path` JSON wins over SQLite, and SQLite wins over built-in fixtures for ordinary restart restore.

The app writes these files into `BALAGAN_UI_TEST_ARTIFACT_DIR` once the board window is ready:

```text
app-ready.json
accessibility-tree.txt
```

The create/edit/status control smoke also accepts:

```text
ui-controls.json
```

If present, `ui-controls.json` must include the stable accessibility identifier strings listed in `scripts/balagan-ui-control-contract.txt`. If it is absent, the harness looks for the same identifiers in `accessibility-tree.txt`.

When `--run-ui-flow-smoke` or `BALAGAN_RUN_UI_FLOW_SMOKE=1` is set, the app should execute the deterministic create/edit/status/tab flow through the app model, then persist normally to SQLite. The harness expects:

```text
ui-flow-smoke.json
```

That artifact must include `schemaVersion`, the flow name `create-edit-status-tab`, and the stable strings from `scripts/balagan-ui-flow-smoke-contract.txt`. The app should use the same values in the persisted board snapshot so the harness can verify SQLite, not a direct database edit, contains the mutation.

On a SQLite restore launch where no fixture path or JSON state path is provided, the app should write:

```text
ui-flow-observed-state.json
```

The restored observation must include `dataSource` and the same stable strings from `scripts/balagan-ui-flow-smoke-contract.txt`.

`make ui-native-flow-smoke` additionally writes:

```text
ui-native-flow-driver.json
ui-native-flow-driver.log
ui-native-flow-driver-failure.json
ui-native-accessibility-dump.txt
ui-native-accessibility-final.txt
```

The native driver requires macOS Accessibility permission for the launching shell/Codex host. If permission is missing, the run exits nonzero and writes `ui-native-flow-driver-error.txt` plus `ui-native-flow-driver-failure.json` with the System Settings path to enable it. On element lookup failures it writes `ui-native-accessibility-dump.txt`; on completed flows it writes `ui-native-accessibility-final.txt` so the real macOS AX tree can be inspected.

`make ui-daily-driver-smoke` writes the same class of artifacts with daily-driver names:

```text
ui-daily-driver.json
ui-daily-driver.log
ui-daily-driver-failure.json
ui-daily-driver-error.txt
ui-daily-driver-accessibility-dump.txt
ui-daily-driver-accessibility-final.txt
```

The daily-driver flow expects these future app controls or equivalent accessible menu items:

```text
task-card-harness-task
column-doing
task-card-harness-task-status-doing
task-card-harness-task-in-doing
empty-terminal-workspace
terminal-workspace-empty-state
terminal-tab-replacement-state
task-context-edit-button
context-menu-edit-task
task-context-delete-button
context-menu-delete-task
task-delete-confirm-button
```

The task-in-doing identifiers are alternatives; the app only needs to expose one state that proves the drag/drop movement persisted to the Doing column. The empty terminal workspace identifiers are alternatives; the app only needs to expose one state that proves deleting or closing the only terminal tab did not leave a stale selected surface. Context-menu actions may be identified either by stable identifiers or by visible menu item titles `Edit Task` / `Delete Task`.

`app-ready.json` includes `dataSource`, `storage`, `terminalBackend.kind`, and `terminalBackend.libGhostty` availability details.

When `--capture-terminal-state` or `BALAGAN_CAPTURE_TERMINAL_STATE=1` is set, the app runs terminal surfaces that have launch metadata through the PTY capture layer, updates the persisted surface scrollback, and writes:

```text
terminal-state-capture.json
```

The restore launch writes the same artifact with `phase: observed` when persisted scrollback contains the capture marker. The harness checks `scripts/balagan-terminal-state-smoke-contract.txt` against both the artifact and `board_snapshots.payload_json`, validating terminal output is in SQLite and not only in the visible terminal view.

Live backend smoke runs also write:

```text
libghostty-terminal-<surface-id>.json
```

That artifact records whether the AppKit host mounted a libghostty surface for the selected terminal.

`make terminal-input-smoke` writes:

```text
ui-terminal-input-driver.json
ui-terminal-input-driver.log
ui-terminal-input-driver-error.txt
ui-terminal-input-accessibility-dump.txt
ui-terminal-input-accessibility-final.txt
terminal-input-output.txt
terminal-input-typed.txt
terminal-input-before-switch.txt
terminal-input-after-switch.txt
terminal-input-second-tab.txt
```

The marker files are created by shells inside the embedded terminals. They prove typed keystrokes reach the live shell, input works before switching tabs, input works in the second tab, input works after switching back to the first tab without an extra terminal click, and that the first tab's exported environment survives the round trip. If any marker is missing, keyboard focus, stale-host forwarding, paste routing, command execution, terminal state, or the live terminal process is broken.

`make terminal-manual-input-smoke` writes:

```text
ui-terminal-manual-input-driver.json
ui-terminal-manual-input-driver.log
ui-terminal-manual-input-driver-error.txt
ui-terminal-manual-input-accessibility-dump.txt
ui-terminal-manual-input-accessibility-final.txt
```

The driver artifact points to unique files under `/tmp/balagan-harness-smoke` created by typed `touch` commands. Those marker files prove physical-style key events and Return reach the live shell after opening the terminal, creating a tab, switching tabs, and navigating away/back.

`make terminal-visible-typing-smoke` writes:

```text
ui-terminal-visible-typing-driver.json
ui-terminal-visible-typing-driver.log
ui-terminal-visible-typing-driver-error.txt
ui-terminal-visible-typing-accessibility-dump.txt
ui-terminal-visible-typing-accessibility-final.txt
libghostty-terminal-visible-text-surface-harness-task-main.txt
libghostty-terminal-visible-text-tab-2.txt
```

The visible text files are copied from `ghostty_surface_read_text`, not marker files created by the shell. The smoke fails unless the physical key tokens are present in the visible text for the first tab, second tab, first tab after switching back, and first tab after navigating away and back.

`make terminal-navigation-smoke` writes:

```text
ui-terminal-navigation-driver.json
ui-terminal-navigation-driver.log
ui-terminal-navigation-driver-error.txt
ui-terminal-navigation-accessibility-dump.txt
ui-terminal-navigation-accessibility-final.txt
terminal-navigation-before.txt
terminal-navigation-after.txt
```

The navigation marker files are created by the original task's live shell before and after leaving the terminal workspace. They prove project/task/board navigation does not recreate the shell or lose shell environment state. If the after-navigation marker is missing or empty, SwiftUI removed the view and the app treated that as terminal session teardown.

When `BALAGAN_RECORD_SELECTED_RESUME=1` and the selected terminal surface has a resume binding, the app also writes:

```text
resume-request.json
```

## Fixture Files

Fixtures live in `UITestFixtures/*.json`.

Required first fixtures:

- `empty-board.json`: no projects, tasks, or workspaces.
- `multi-project-running.json`: several projects with tasks spread across Todo, Doing, Done, and Parked, plus fake terminal output for active workspaces.
- `resumable-task.json`: a selected task with trusted Codex and untrusted tmux resume bindings for resume-button and confirmation flows.

Fixture schema version `1` uses stable string IDs, frozen timestamps, project/task records, workspace layout records, terminal surface records, optional scrollback snapshots, and `uiState` for selected project/task/view.

## Artifacts

UI commands write under `.ui-artifacts/<command>/<timestamp>-<fixture>/`.

Each run directory is prepared to contain:

- `fixture.json`: copy of the fixture used for the run.
- `Balagan.sqlite`: temporary SQLite fixture database when `sqlite3` is installed.
- `Balagan.state.json`: versioned durable board snapshot written by the app.
- `restore/`: second app launch that restores from `Balagan.state.json` without a fixture path.
- `database-restore/`: third app launch that restores from `Balagan.sqlite` without fixture or JSON state input.
- `database-snapshot.json`: decoded current SQLite snapshot payload when the `sqlite3` CLI is available.
- `ui-flow-smoke.json`: scripted create/edit/status/tab flow summary written by `ui-flow-smoke` seed launches.
- `ui-native-flow-driver.json`: native macOS Accessibility driver summary written by `ui-native-flow-smoke`.
- `ui-native-flow-driver-failure.json`: explicit native-driver failure metadata when Accessibility permissions or another UI-driver error blocks the run.
- `ui-native-accessibility-dump.txt`: native macOS Accessibility tree written on driver lookup failure.
- `ui-native-accessibility-final.txt`: native macOS Accessibility tree written after a completed native driver flow.
- `ui-daily-driver.json`: native macOS Accessibility summary for drag/drop status movement, only-terminal-tab deletion, context-menu edit, and context-menu delete.
- `ui-daily-driver-failure.json`: explicit daily-driver failure metadata when Accessibility permissions or missing controls block the run.
- `ui-daily-driver-accessibility-dump.txt`: native macOS Accessibility tree written on daily-driver lookup failure.
- `ui-daily-driver-accessibility-final.txt`: native macOS Accessibility tree written after a completed daily-driver flow.
- `ui-terminal-input-driver.json`: native macOS Accessibility summary for the live terminal input smoke.
- `terminal-input-before-switch.txt`: first-tab marker written before switching tabs.
- `terminal-input-second-tab.txt`: second-tab marker written after creating the second terminal tab.
- `terminal-input-after-switch.txt`: first-tab marker written after switching back without an extra terminal click.
- `terminal-input-output.txt`: final first-tab state marker written from an exported environment variable.
- `ui-terminal-manual-input-driver.json`: native macOS Accessibility summary for the physical-key live terminal input smoke.
- `ui-terminal-visible-typing-driver.json`: native macOS Accessibility summary for visible physical-key terminal typing.
- `libghostty-terminal-visible-text-<surface-id>.txt`: visible terminal text copied from the active libghostty surface during live terminal smokes.
- `terminal-state-capture.json`: captured terminal scrollback metadata written by `terminal-state-smoke` seed and restore launches.
- `session-report-socket.json`: Unix domain socket endpoint metadata for hook/session reports.
- `session-report-sent.json`: fake hook event emitted by `hook-smoke` through the same socket endpoint wrappers should use.
- `session-report-last.json`: app-side result after applying the latest session report.
- `fake-claude-argv.txt`: fake Claude arguments recorded by `agent-wrapper-smoke`, including the wrapper-generated `--session-id`.
- `fake-claude-ran.txt`: marker proving `agent-wrapper-smoke` executed the fake Claude binary.
- `database-restore/ui-flow-observed-state.json`: restored board observation written after `ui-flow-smoke` relaunches from SQLite.
- `normal-restore/`: `normal-store-smoke` launch proving SQLite is used as the app data source without `--ui-test-mode`.
- `first-run-smoke/`: fresh normal-mode launch proving a new SQLite path starts from an empty board without fixture or JSON state input.
- `BalaganApp.app`: temporary app bundle created by `ui-debug` when running from SwiftPM.
- `app-ready.json`: readiness and board-state summary written by the app.
- `resume-request.json`: process-safe resume request artifact for selected resumable surfaces.
- `launch.env`: environment contract for the app.
- `launch-args.txt`: launch arguments used by manual debug runs.
- `app.log`: placeholder now, app log destination later.
- `accessibility-tree.txt`: deterministic identifier dump written by the app.
- `screenshots/`: screenshot checkpoint output. Set `BALAGAN_CAPTURE_SCREENSHOTS=0` to skip OS screenshot capture.

Expected screenshot checkpoints once XCUITest exists:

- full board
- filtered board
- task terminal workspace
- terminal workspace
- resume confirmation
- restored workspace after relaunch

## Session Report Hook Smoke

`make hook-smoke` verifies the first app-side hook path for cmux-like restore. The app listens on a local Unix domain socket at `BALAGAN_SOCKET_PATH` and accepts newline-delimited `SessionReportEvent` JSON. Runtime terminal launches receive:

- `BALAGAN_TASK_ID`
- `BALAGAN_WORKSPACE_ID`
- `BALAGAN_SURFACE_ID`
- `BALAGAN_SOCKET_PATH`

The app's own session-report socket path resolves as `--session-report-socket`, else
`<artifact-dir>/balagan-session-report.sock`, else the stable default
`~/.balagan/session-report.sock` (beside `control.sock`). The server unlinks any stale file before
binding, so a killed app never blocks the next launch. **Always pass `--session-report-socket` (or
`--artifact-dir`) from a test** so a run cannot touch the live app's socket.

The smoke launches `multi-project-running`, sends a fake `session-start` for `task-fake-terminal` / `workspace-fake-terminal` / `surface-fake-terminal-main` with `agentName=codex` and `sessionID=fake-session-123`, then verifies the JSON state file and SQLite snapshot contain a trusted `agent-hook` `ResumeBinding` with `autoResume=true`. It relaunches from SQLite and records `codex resume fake-session-123` in `database-restore/resume-request.json`.

This path intentionally does not require real Codex or Claude shell wrappers. Launch commands that go through `balagan-agent` emit the same JSON event schema to the socket path provided in the runtime environment.

## Agent Lifecycle Hook Smoke

`make hook-lifecycle-smoke` (`scripts/hook-lifecycle-smoke.sh`) is the end-to-end check of the *other*
half of the hook path: the working-state hooks moving a task's agent state. It runs the real
`balagan-agent hook <event>` binary against a real running app and asserts what `balagan state`
reports — the exact production wire (stdin payload → `AgentHookEvent` → `SessionReportEvent` →
session-report socket → `applyReportedSessionCapture` → control socket).

It needs **no display and no sandbox exception**: the app runs `--ui-test-mode`.

The sequence, with the fixture's real task/workspace/surface ids read out of the `app-ready.json` the
app writes (never hard-coded):

| step | hook | payload | expected |
| --- | --- | --- | --- |
| 1 | `permission-request` | `tool_name: Bash` | `needs-input` |
| 2 | `post-tool` | `tool_name: Bash` | `running` |
| 3 | `pre-tool` | `tool_name: Read`, `agent_id` set | still `running` (subagent hooks are dropped) |
| 4 | `stop` | — | `idle` |
| 5 | `stop` | no `BALAGAN_*` env | logged `dropped: missing-env` |
| 6 | `stop` | socket path that doesn't exist | logged `send-failed: connect: …` |

It also asserts the wrapper's own contract on every hook — exit 0, empty stdout — and that the hook
log contains one line per invocation with the expected outcome and no payload content.

Everything (control socket, session-report socket, state JSON, artifacts, hook log) is redirected to
short `/tmp/tb-hs-$$…` paths, so a run never touches the live app's `~/.balagan` sockets or hook
log, and never overflows the ~104-byte `sun_path` cap. Artifacts are deleted on success and kept
(with the path printed) on failure. `BALAGAN_SKIP_BUILD=1` skips the `swift build`.

## Agent Hook Log

Every `balagan-agent hook <event>` invocation appends exactly one line to
`~/.balagan/agent-hooks.log`. This is what makes "the hook never fired" distinguishable from "it
fired and the send failed" — before it, every failure in the wrapper was silent.

```text
2026-09-06T17:18:02.127Z event=permission-request lifecycle=needs-input task=task-42 surface=agent tool=Bash outcome=send-failed: connect: No such file or directory (errno 2)
```

- Fields: ISO-8601 UTC timestamp (ms), then `event=` (the hook, or `launch` for the pre-exec
  session-start report), `lifecycle=`, `task=`, `surface=`, `tool=`, `outcome=`. An absent field
  reads `-`.
- Outcomes: `sent`, `send-failed: <errno text>`, `dropped: subagent`, `dropped: no-mapping`,
  `dropped: missing-env`, `dropped: no-session-id`.
- **No payload bodies or prompts are ever written** — only the hook name, derived lifecycle, routing
  ids, and tool name.
- `BALAGAN_HOOK_LOG=<path>` overrides the file; `BALAGAN_HOOK_LOG=off` disables logging.
- The file is capped at ~1 MB: the next append past the cap rotates it to `agent-hooks.log.1` (one
  generation).
- Formatting, path resolution and the rotation rule are the pure `AgentHookLog` /
  `AgentHookLogEntry` in Core (`AgentHookLogTests`); the wrapper is just the I/O around them.

## Agent Wrapper Smoke

`make agent-wrapper-smoke` verifies the real wrapper layer that shell launch configuration should call. The wrapper executable is `balagan-agent` and its first argument selects the agent:

```text
balagan-agent claude [claude arguments...]
balagan-agent codex [codex arguments...]
```

The wrapper requires `BALAGAN_TASK_ID`, `BALAGAN_WORKSPACE_ID`, `BALAGAN_SURFACE_ID`, and `BALAGAN_SOCKET_PATH`. It reports a `session-start` event through the same `SessionReportEvent` parser/encoder and Unix socket sender used by `BalaganUIDriver --send-session-report`, then runs the real agent with inherited stdio and exits with the child exit code.

Project defaults should use the stable commands `balagan-agent codex` or `balagan-agent claude`. Balagan stores that command on `Project.defaultAgentCommand`. The initial task agent surface and the explicit agent-tab action use the project default as the new surface `startupCommand`; ordinary shell tabs created with the plain plus button still have no startup command and launch the user's default shell.

In normal app mode, `balagan-agent` is resolved from `PATH`, so install or link the SwiftPM product into a directory on the app's shell PATH when using real launches. In harness/test mode, set `BALAGAN_AGENT_WRAPPER_PATH` to the SwiftPM-built `balagan-agent` executable; Balagan rewrites only commands beginning with `balagan-agent` to that absolute wrapper path before storing the surface startup command.

For Claude, fresh launches predeclare a UUID using the locally supported `--session-id <uuid>` flag. Existing `--resume`, `-r`, or `--session-id` arguments are detected and reported without adding another session id. Persisted restore uses the core planner's `claude --resume <session-id>` command.

For Codex, `codex resume <session-id>` is supported for known restore IDs. Fresh Codex launches cannot predeclare a session id, so the wrapper records launch time, starts a detached capture helper, and then `exec`s Codex so the interactive process takes over the terminal promptly. The helper polls `~/.codex/state_5.sqlite` for exactly one new `threads` row matching the current `cwd`, and falls back to scanning new `~/.codex/sessions/**/*.jsonl` rollout files for the first `session_meta` id. If capture is missing or ambiguous, the helper stays silent and does not persist an unreliable binding.

The smoke uses `BALAGAN_CLAUDE_EXECUTABLE` to point at a fake Claude script. It launches the app socket listener, runs `balagan-agent claude --model sonnet`, verifies the wrapper-generated session id reaches `session-report-last.json`, state JSON, and the SQLite snapshot, then relaunches from SQLite and verifies `database-restore/resume-request.json` contains `claude --resume <generated-id>` without confirmation.

The same smoke places a fake `codex` first on `PATH` and uses `BALAGAN_CODEX_CAPTURE_HOME` to run it against a temporary `.codex/state_5.sqlite`. This deterministically verifies default executable resolution, visible terminal output, wrapper-to-Codex `exec` PID handoff, and the helper capture path without touching the user's real Codex state or starting an interactive Codex session. Real Codex live capture still needs a manual validation pass because fresh Codex session IDs are discovered from local state after the real process starts.

## Future XCUITest Expectations

Every important UI control should have a stable accessibility identifier. UI failures should save screenshots, accessibility tree dumps, app logs, and the current SQLite fixture copy into the run artifact directory printed by `make ui-test`.

The first create/edit/status UI slice should satisfy `scripts/balagan-harness.sh ui-controls-smoke` by exposing:

- `create-project-button`
- `edit-project-button`
- `create-task-button`
- `edit-task-button`
- `task-status-control`
- `task-status-option-todo`
- `task-status-option-doing`
- `task-status-option-done`
- `task-status-option-parked`
- `create-terminal-tab-button`
- `rename-terminal-tab-button`
- `delete-terminal-tab-button`

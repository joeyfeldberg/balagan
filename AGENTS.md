# AGENTS.md

Orientation for AI agents working in this repo. Read this before touching the terminal layer,
running GUI tests, or trying to take screenshots — there are non-obvious gotchas below.

## What this is

A native macOS (AppKit + SwiftUI) **kanban board where each task owns an embedded terminal
workspace**, powered by an embedded **libghostty**. Inspired by cmux. Swift Package, macOS 14+.

Targets (`Package.swift`):
- `BalaganCore` — library: the single domain model + terminal/PTY/resume/agent logic.
- `BalaganApp` — the AppKit/SwiftUI executable (the app).
- `BalaganUIDriver` — accessibility-based UI test driver.
- `balagan-agent` — agent wrapper that captures session ids.
- `balagan` — control CLI that drives the running app over a local socket (see "Controlling the app").
- `CGhosttyShim` — C shim that dlopens libghostty and exposes a narrow API.

## Build / test / lint

```bash
swift build          # or: make build
swift test           # or: make test   — ~520 unit tests (Core + App), fast, no GUI
make lint
```

Unit tests + `swift build` are the fast inner loop and need **no** display/sandbox exceptions.

## The rename from TaskBoard

The app was called **TaskBoard** until 2026-10-01. On first launch `LegacyTaskBoardMigration` (Core)
copies, never moves, the old data: `Application Support/TaskBoard/TaskBoard.sqlite` →
`Application Support/Balagan/Balagan.sqlite`, `~/.taskboard/agents` → `~/.balagan/agents`, and the
`com.joeyfeldberg.TaskBoard` UserDefaults domain into the new one (once, tracked by
`migratedFromTaskBoard`). Everything else under `~/.balagan` is regenerated. Those legacy names are
the only places "TaskBoard" should still appear in the code.

## Packaging the app

```bash
make app            # or: scripts/build-app.sh [version]
```

Builds a real, double-clickable `dist/Balagan.app` (release binary + `balagan-agent`, the
SwiftPM resource bundle, `AppIcon.icns` generated from `Sources/BalaganApp/Resources/AppIcon.png`,
an `Info.plist`, ad-hoc code-signed). Version comes from the `VERSION` file; build number from the
git commit count. Install with `scripts/install-app.sh` (not `cp -R` — see the notifications gotcha). No auto-updater yet —
distribution to other Macs needs Developer ID signing + notarization (see the note at the bottom of
`build-app.sh`), and Sparkle/GitHub-Releases would slot in on top of this bundle.

## ⚠️ The sandbox gotcha (read this!)

Agent Bash runs in a **sandbox by default** that blocks window-server / GPU / display access.
Inside the sandbox:
- `screencapture` fails with `could not create image from display`,
- libghostty surface creation returns null (`ghostty_surface_new returned null`),
- the accessibility UI driver can't read window trees (dumps only bare `AXApplication`).

This is **not** display sleep, and **not** a missing macOS permission — it's the sandbox.
Anything that touches the GUI must run **unsandboxed** (`dangerouslyDisableSandbox: true`):
- screenshots / `screencapture`
- the live libghostty path (mounting real terminal surfaces)
- the GUI smokes: `ui-*`, `live-backend-smoke`, `terminal-*`

`swift build`, `swift test`, and `make lint` do **not** need this.

## Taking screenshots

**Run unsandboxed** for anything here — window-server/GPU/display access is blocked in the default
agent sandbox (libghostty surfaces return null, `screencapture` errors with "could not create image
from display"). The host terminal is **Ghostty** (`com.mitchellh.ghostty`, the project we embed).

### Method 1 — in-process snapshot (the default; no display needed)

The app renders its own SwiftUI/AppKit tree via `cacheDisplay` when given `--artifact-dir`, writing
`<dir>/screenshots/board-app.png`. Launch → wait for the PNG → kill → **Read** it:

```bash
ART=/tmp/tb-$$
.build/debug/BalaganApp --ui-test-mode --fixture multi-project-running \
  --control-socket /tmp/tb-$$.sock --artifact-dir "$ART" >/tmp/tb-log-$$ 2>&1 &
PID=$!
for i in $(seq 1 60); do [ -f "$ART/screenshots/board-app.png" ] && break; sleep 0.2; done
sleep 0.5; kill $PID 2>/dev/null
# then Read "$ART/screenshots/board-app.png"
```

- **Captures:** the SwiftUI/AppKit chrome in the window contentView — sidebar, task header + tabs,
  kanban board, and in-content overlays (command palette, Archived view).
- **Does NOT capture (in `board-app.png`):** the Metal-backed terminal pixels (in `--ui-test-mode`
  panes show fallback scrollback *text*); the **titlebar accessory** (sidebar toggle / agent-sessions /
  bell — it lives in the window frame, outside the contentView snapshot, use Method 2); and **`.sheet`
  modals** (Settings, project/task forms), which present as a *separate* window. A live attached sheet
  is written to `screenshots/board-sheet.png`; headless (no shown window) never attaches one, so the
  **Settings** sheet (`BALAGAN_SHOW_SETTINGS=1`) and the **New Task** form (`BALAGAN_SHOW_TASK_FORM=1`)
  are rendered offscreen to `board-sheet.png` on demand.
- **Read small regions legibly** by cropping then upscaling with `sips` before Read
  (`-c <H> <W> --cropOffset <Y> <X>` crops; `-z <H> <W>` scales up):
  ```bash
  sips -c 46 1232 --cropOffset 6 248 board-app.png --out crop.png   # the header bar
  sips -z 70 1880 crop.png --out crop.png                           # ~1.5× upscale → Read crop.png
  ```
- **Put a specific state on screen:** `--fixture <name>` (see below), or `--state-path <snapshot.json>`.
  Easiest way to a *valid* state file: launch a fixture with `--state-path /tmp/s.json` once (the app
  writes a full valid `BoardSnapshot` there), then edit that JSON and relaunch — hand-writing surfaces
  from scratch fails to decode. To force a view that's otherwise behind interaction, set a launch-time
  env hook: `BALAGAN_SHOW_ARCHIVED=1`, `BALAGAN_SHOW_COMMAND_PALETTE=1`, `BALAGAN_SHOW_READER=1`
  (pairs with `--fixture reader-transcript`, whose surface binds to a sample transcript written to the
  temp dir), or `BALAGAN_SHOW_SETTINGS=1` (the last renders the Settings sheet to
  `screenshots/board-sheet.png`). `BALAGAN_FIXTURE_AGENT_STATES_FILE=<json>` (with
  `BALAGAN_FIXTURE_AGENT_STATES=1`) seeds per-task activity from a file keyed by task id
  (`{state, summary, response, minutes}`), and `BALAGAN_CHANGES_FILE=<path>` picks the file the
  Changes view opens on.
- **README screenshots** are regenerated by `zsh docs/screenshots/capture.sh` (unsandboxed). It builds
  the demo board (`fixtures.py`) and a sample repo for the diff (`sample-repo.sh`), then snapshots and
  crops into `docs/images`. Edit those scripts rather than hand-editing images.

### Method 2 — live single-window capture (real terminal pixels + titlebar)

Needs an **awake, unlocked display** (still unsandboxed):

```bash
# 1) find the window id (swift one-liner over CGWindowListCopyWindowInfo)
swift -e 'import CoreGraphics; for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String:Any]]) ?? [] where ((w[kCGWindowOwnerName as String] as? String) ?? "").contains("Balagan") { print(w[kCGWindowNumber as String] as? Int ?? 0) }'
# 2) capture just that window
screencapture -l<WINDOW_ID> -o /tmp/appwin.png
```

### Not verifiable headlessly at all
Real keystrokes/focus (keyboard nav, IME, the palette's ↑/↓/⏎/Esc, drag-reorder) and clicking the
titlebar buttons — those need the user's live run. The accessibility UI driver needs Accessibility
permission, which isn't granted in this environment.

## Launching the app directly

```bash
.build/debug/BalaganApp \
  --state-path /tmp/state.json \                 # load/persist a BoardSnapshot here
  --artifact-dir /tmp/art \                       # writes app-ready.json, screenshots/, host artifacts
  --libghostty-path /Applications/Ghostty.app/Contents/MacOS/ghostty
```
Other flags: `--fixture <name>`, `--database <path>`, `--ui-test-mode` (deterministic; disables real
processes), `--capture-terminal-state`, `--run-ui-flow-smoke`, `--run-agent-reopen-capture-smoke`,
`--record-selected-resume`, `--agent-wrapper-path`, `--session-report-socket`.

Built-in fixtures (`BoardFixtures.seed(named:)`): `empty-board`, `resumable-task`, and the default
(multi-task) board. The non-empty fixtures **auto-select task[0]** (so the app opens into that
task's terminal workspace, not the kanban board). To show the board, load a state with
`uiState.selectedTaskID = null`.

State JSON is a `BoardSnapshot`: `{schemaVersion, savedAt, boardState:{projects,tasks,workspaces}, uiState:{...}}`.
`WorkspaceLayout` (a Swift enum) follows the **Ghostty model**: the root is `.tabs`, and each tab is a
split tree (`.surface`/`.split`) — tabs are the outer level, splits live *inside* a tab. It encodes as:
- a surface: `{"surface":{"_0":"surfaceA"}}`
- tabs (each child is a tab's sub-layout): `{"tabs":{"_0":[{"surface":{"_0":"a"}},{"surface":{"_0":"b"}}]}}`
- split (axis `horizontal` = side-by-side / vertical dividers, `vertical` = stacked):
  `{"split":{"axis":"horizontal","children":[{"surface":{"_0":"a"}},{"surface":{"_0":"b"}}]}}`
- a tab containing a split: `{"tabs":{"_0":[{"split":{"axis":"horizontal","children":[{"surface":{"_0":"a"}},{"surface":{"_0":"b"}}]}}]}}`

The legacy `.tabs` form (`{"tabs":{"_0":["surfaceA","surfaceB"]}}`, an array of surface-id strings) still
decodes — `WorkspaceLayout`'s custom `Codable` maps it to `.surface` children, and load-time
`canonicalized()` lifts any "inverted" legacy layouts (tabs trapped inside a split) to the canonical
root-tabs shape.

## Architecture (post model-collapse)

**One domain model lives in `BalaganCore`** and is used directly by the app — there is no app-side
mirror layer anymore. Core types: `Project`, `TaskItem`, `Workspace`, `Surface`, `TaskStatus`,
`TaskPriority`, `WorkspaceLayout`, `ResumeBinding`, `ResumeCommandPlan`, `AgentLaunchMetadata`,
`KeyboardShortcutSettings`.

**Keyboard shortcuts are user-configurable** (Settings → Keyboard Shortcuts). `KeyboardShortcuts.swift`
(Core, pure) defines `ShortcutAction` (the configurable Terminal-menu commands), `KeyChord`
(key + modifiers, with `displayString`), and `KeyboardShortcutSettings` (overrides keyed by action,
persisted in `PersistedUIState.keyboardShortcuts`). The app bridges chords to AppKit in
`KeyChordAppKit.swift` (`KeyChord.keyEquivalent`/`modifierFlags` for menu items, `KeyChord.from(event:)`
for the recorder). `installTerminalMenu()` reads the chords and is **rebuilt** whenever
`viewModel.keyboardShortcuts` changes (Combine sink) — menu key equivalents are the live path, so the
in-view `handleCommandShortcut` deliberately does **not** re-handle these actions (a rebind would
otherwise keep firing on the old combo).

App-only behavior is added via **extensions on the core types** (don't reintroduce mirror structs):
- `BoardDomainExtensions.swift` — on `Surface`: `output` (computed over `scrollbackSnapshot`),
  `resumePlan(taskID:)` (derived from `resumeBinding`), `liveEnvironment`, `launchAction`,
  `initialLaunchCommand`, `confirmedResumeCommand`, `resumeAffordancePlan`,
  `shouldAutoCloseAfterEndedProcessPrompt`, `workspaceID(taskID:)`; on `Workspace`: tab/split
  navigation helpers + the `fakeTerminal`/`resumableCodex` fixture factories.
- `BoardModelExtensions.swift` — `TaskStatus.accessibilitySlug`, `TaskPriority.fixtureValue(Int)`.

Note: runtime-only state is **derived, not stored separately** — `Surface.output` is backed by
`scrollbackSnapshot`; `resumePlan` is computed from `resumeBinding`. Don't add a side-table.

`BoardViewModel` (in `BalaganApp.swift`) is the `@Published` ObservableObject; its logic is split
into sibling files by concern: `BoardSurfaceLifecycle`, `BoardCRUD`, `BoardSessionEvents`,
`BoardCodexRecovery`, `BoardFixtures`, `BoardSnapshotMapping`, `BoardAccessibilityTree`.

`BalaganApp.swift` is still large; it holds the app delegate, the view model state + navigation,
and all the SwiftUI views.

## Terminal layer (libghostty)

- Live terminals = **libghostty**, loaded at runtime via `CGhosttyShim` (C) + `LibGhosttyDynamicLibrary.swift`.
  libghostty owns its own PTY + child process; we do **not** feed it from `PtySession`.
- **Sessions are offloaded, processes aren't.** Each terminal's process is a libghostty child *inside*
  the app process — no daemon, no detach — so it dies with the surface/app. What survives is the
  *session*: agents launch through the `balagan-agent` wrapper (`Sources/BalaganAgentWrapper/main.swift`),
  which captures the agent's session id (Claude: injects `--session-id` and installs the merged
  `--settings` hooks below; Codex: a detached helper polls its session files) and reports it
  over the session-report socket (`BoardSessionEvents.applyReportedSessionCapture`). The app records a
  `ResumeBinding` on the `Surface` (persisted), so reopen/restart rebuilds the surface and runs the
  native resume (`claude --resume <id>`). Plain shells have no session → scrollback is replayed
  (`TerminalScrollbackReplay`) instead. This is why hibernating an idle agent is safe.
- **Agent working-state (`surfaceLifecycle`: running/idle/needs-input) is hook-driven for Claude, with a
  pid-liveness safety net** (Codex has no hooks — its state is title-derived, two bullets down). The
  Claude hooks drive the transitions, routed per-surface via
  `BALAGAN_SURFACE_ID`. The wrapper installs them by injecting `--settings` (merges with the user's
  settings; re-passed on `--resume`), and the hook → working-state mapping is the pure, unit-tested
  `AgentHookEvent` (Core) — the wrapper is only I/O around it:
  - `PermissionRequest`→**needs-input**. This is the accurate "blocked on you" signal: it fires
    *immediately, before* the dialog. `Notification`/`permission_prompt` fires **6 s after** the dialog
    and **never** if you answer sooner, so on its own "waiting" showed late or not at all. Exiting 0
    with empty stdout keeps the hook a pure observer — it does not alter the permission flow.
  - `PostToolUse`→**running**. This is what resolves an *approved* prompt: `PreToolUse` runs *before*
    the dialog, so without it nothing re-asserts running until the agent reaches the next tool.
  - `UserPromptSubmit` and `PreToolUse`→**running** (the heartbeat), except `PreToolUse` for
    `AskUserQuestion`/`ExitPlanMode`→**needs-input** (they block on you without a permission dialog).
  - `Stop`→**idle**. `Notification`→classified by `AgentNotification` on `notification_type`
    (`permission_prompt`/`worker_permission_prompt`→needs-input, `idle_prompt`/`agent_completed`→idle,
    quota arm/cancel/offer and anything unrecognized→leave the state unchanged).
  - `SessionStart` reports the session id + transcript path, not a working state.

  Two payload-level rules: a hook payload carrying **`agent_id` is a subagent's** and never drives the
  surface lifecycle (a background subagent's `PreToolUse` otherwise clobbers a real needs-input on the
  parent surface); and the injected settings set `"preferredNotifChannel": "notifications_disabled"`
  because Balagan posts its own banners off these transitions (cmux does the same).

  **Every hook invocation logs one line to `~/.balagan/agent-hooks.log`** — the wrapper is otherwise
  silent by design (a hook's stdout is fed back into the agent, so it must exit 0 with nothing on it),
  which used to make "the hook never fired" indistinguishable from "it fired and the send failed":

  ```text
  2026-09-06T17:18:02.127Z event=permission-request lifecycle=needs-input task=task-42 surface=agent tool=Bash outcome=sent
  ```

  Outcomes are `sent`, `send-failed: <errno text>`, `dropped: subagent | no-mapping | missing-env |
  no-session-id`; absent fields read `-`; `event=launch` is the pre-exec session-start report (logged
  only when it fails, alongside its stderr line). **No payload bodies or prompts are ever written.**
  Override the path with `BALAGAN_HOOK_LOG=<path>`, disable with `BALAGAN_HOOK_LOG=off`. The file
  caps at ~1 MB and rotates to `.1`. Format/path/rotation are the pure `AgentHookLog` in Core; the
  end-to-end path (hook → state, no display needed) is `make hook-lifecycle-smoke`.

  A 2 s reconciler (`AgentLifecycleReconciler`, pure/tested in Core; driven by
  `BoardViewModel.reconcileAgentLifecycles`) does what hooks can't: **clear** a state stranded by a
  dead process (`kill(pid,0)` ⇒ `ESRCH`), plus the title-spinner cross-check below. It deliberately
  does **not** infer state from transcript activity/silence — an earlier build did (mtime⇒running) and it was too blunt (a long
  silent tool looked idle; a resume write looked like new work, so a restarted-but-idle agent got
  stuck showing a spinner). `surfaceLifecycle` is runtime-only, so a restart starts clean. Sleep
  (`BoardHibernation`) SIGTERMs the agent pid+group and clears the lifecycle; the reconciler skips
  hibernated tasks. `taskIsRunning` ORs across a task's surfaces (and is false for a slept task), so
  multi-tab aggregation was never the bug. (cmux self-heals the same way via pid-liveness.)
- **Title-spinner cross-check** (`AgentTitleHeuristic`, fed by `SET_TITLE` — no text reads, so no leak).
  Agents prefix the terminal title with an animated spinner while working: **Claude Code ≥ 2.1.228 uses
  the half-circles `◐◑◒◓` (U+25D0–25D3)** (older builds and **Codex** use Braille U+2800–28FF — match
  both); not-working reads `✳ <summary>`. Spinner present ⇒ running (recovers a missed hook); absent
  while `.running` ⇒ idle (the only recovery for Esc/interrupt, which fires no hook); absent while
  `.needsInput` ⇒ untouched. Absence is trusted only once a surface has shown a spinner at least once.
  Because the spinner keeps animating for a few hundred ms after a permission dialog opens, a hook-set
  `.needsInput` is overturned only after **two consecutive** spinner ticks (`titleWorkingStreak`, reset
  by `BoardLifecycleReconcile` on a spinner-absent tick and whenever a hook writes `.needsInput`).
- **Codex working-state is title-*derived*, not corroborated** — the wrapper installs no Codex hooks, so
  the title is the only signal there is (and Codex is the default agent, so without this every Codex task
  read `.idle` forever). `AgentTitleHeuristic.classify` reads a title as `working` (leading spinner) /
  `blocked` (contains "Action Required", which only Codex writes) / `idle` (any other non-blank title),
  and `AgentLifecycleReconciler` branches on `Surface.agentKind`: for `.codex`, spinner ⇒ `.running`,
  "Action Required" ⇒ `.needsInput`, anything else ⇒ `.idle` on the next 2 s tick (the tick *is* the
  debounce, so spinner frames can't flap it). Codex's `.needsInput` is **not** sticky (the title set it,
  so the title clears it) and ignores the "ever showed a spinner" latch — both of those exist to protect
  a *hook*-set state. Dead-pid clear and the hibernated-task skip are unchanged. The branch lives in the
  pure reconciler, not the `SET_TITLE` callback, so the whole table is unit-testable. `agentKind` is
  derived, never stored: `ResumeBinding.agentName` (wrapper-reported) → `AgentLaunchMetadata.agentName` →
  a per-*token* scan of the launch command (`balagan-agent codex`); token-wise so
  `tmux attach -t task_resume_codex` isn't mistaken for an agent.
- Target version: **Ghostty 1.3.1** (`/Applications/Ghostty.app/...`). Action-tag values in the shim
  (`GHOSTTY_ACTION_*`) are matched to that version — re-verify against `include/ghostty.h` if upgrading.
- The shim's runtime `action_cb` is wired and routes events to Swift (via a global event callback +
  per-surface `userdata`): `SET_TITLE` (32), `PWD` (35), `DESKTOP_NOTIFICATION` (31), `RING_BELL` (50).
  Mouse (`mouse_button`/`mouse_pos`/`mouse_scroll`), selection (`has_selection`/`read_selection`),
  and `process_exited` (polled for exit detection) are also exposed.
- **Notifications** come from two sources, both through `SystemNotificationPresenter` and both only
  when the target surface isn't focused. (1) *Terminal-escaped*: a `DESKTOP_NOTIFICATION`, or a bell
  from an unfocused surface. (2) *App-posted*, from the lifecycle transitions themselves
  (`BoardAgentBanners.swift`), because the injected Claude settings turn Claude's own OSC banners off
  (`preferredNotifChannel: notifications_disabled`) — so **entering `needsInput`** schedules a
  "waiting for your input" banner and **`running → idle`** posts a "finished" banner immediately.
  The waiting one is **armed regardless of focus** (you're almost always looking at the tab when its
  prompt appears), held ~5 s and **re-validated before it fires** (still `needsInput`, *now* unfocused,
  not hibernated, not `--ui-test-mode`), one pending per surface, cancelled the moment the state
  leaves `needsInput` — a permission prompt you answer straight away never buzzes. If it was dropped
  because you were looking, it is **re-armed once per waiting episode when you look away** (selection
  change or Balagan resigning active — `rearmWaitingBannersAfterFocusChange`, tracked in
  `postedWaitingBanners`), so "read the question, then walked off" still gets one banner. The pure
  decision (flag? banner? still valid?) is `AgentAttentionPolicy` in Core; the app side only supplies
  facts and performs effects, and both are gated by `BoardViewModel.agentNotificationsEnabled`.
  In a packaged `.app` (has a bundle id) delivery uses **UNUserNotificationCenter** — the banner shows
  Balagan's icon, and clicking it activates the app and jumps to the waiting task/surface (ids ride
  in `userInfo`). The dev/`.build` binary has **no** bundle id, so it falls back to **osascript**
  (macOS attributes that to Script Editor → generic script icon, click opens Script Editor). Posting
  also flags the surface's tab/task/project "needs attention", which renders through one shared
  `AgentStatusGlyph` (spinner = running, amber `questionmark.circle.fill` = waiting, accent dot =
  finished; precedence running > waiting > finished) on the task card, the sidebar project rows, the
  terminal tab strip and the titlebar agents menu. `BALAGAN_FIXTURE_AGENT_STATES=1` seeds all three
  states for a headless snapshot.
- The **`TerminalSurfaceSession` / `PtySession` / `PlainTextTerminalEmulator`** core layer is the
  **headless backend for the smoke harness only** (run-to-completion + plaintext capture). It is
  **not** the live terminal path. It lives behind the harness (`BoardSmokeHarness.swift`).

## Agents: profiles, integrations, typing an agent at a prompt

Every agent is an **`AgentProfile`** (Core, `AgentProfile.swift`). There are built-ins for **Claude Code, Codex,
OpenCode and pi**, and custom ones load from `~/.balagan/agents/*.json` (only `id` is required;
optional `command`, `displayName`, `sessionIDFlag`, `resumeArguments` with `{session}`, `sessionFlags`,
`passthroughSubcommands`, `passthroughFlags`). A profile says how to launch the agent, how its session
is known, how to resume it, and which integration reports its state. The wrapper (`balagan-agent
<id> …`, planned by `AgentWrapperPlanner`), the resume planner, and the launch layer's
resume-through-the-wrapper rewrite all read profiles instead of branching on names. Custom profiles
can't take a built-in id or claim a built-in integration.

| Agent | Session | Resume | State signals (integration) |
|---|---|---|---|
| Claude Code | injected `--session-id` | `claude --resume <id>` | hooks via `--settings` |
| Codex | captured from rollout files by the helper (polls until the first message, up to 1 h, stops when Codex exits) | `codex resume <id>` | terminal title (reconciler) |
| pi | injected `--session-id` | `pi --session-id <id>` | extension via `--extension` (`agent_start`/`agent_settled`/`ui_prompt_*`, `session_start`) |
| OpenCode | reported by the plugin | `opencode --session <id>` | plugin via `OPENCODE_CONFIG_DIR` (additive to the user's config; skipped if they set their own). `session.status`/`idle`, `permission.*`, `question.*`; child sessions ignored |
| custom | optional injected flag | its `resumeArguments` | title spinner / notifications only |

The pi extension and the OpenCode plugin talk back through **`balagan-agent report <agent> lifecycle
<state>` / `report <agent> session <id> [transcript]`** (`AgentReportCommand`), and every call logs a
`report-*` line in the hook log.

**Typing `codex` (or `pi`, `opencode`, `claude`, any profile's command) in any Balagan terminal makes
it an agent tab.** `AgentIntegrationInstaller` (run at launch, not in `--ui-test-mode`) writes
`~/.balagan/shims/<command>` for every profile, plus a zsh `ZDOTDIR` chain in `~/.balagan/shell/zsh`
and the integration files. `AgentShellEnvironment` gives every terminal `BALAGAN_AGENT_WRAPPER`,
`BALAGAN_SHIMS_DIR`, the shims first on `PATH`, and, for zsh, `ZDOTDIR` (the user's own is passed as
`BALAGAN_USER_ZDOTDIR`).

The chain works with Ghostty's integration, which saves our `ZDOTDIR` and sources it. It sources the
user's `.zshenv`/`.zprofile`/`.zshrc`/`.zlogin` in order (following a `ZDOTDIR` the user's `.zshenv`
moves), then puts the shims first after `.zshrc` and again in `precmd`, because mise rewrites `PATH`
every prompt. At the end it hands `ZDOTDIR` back. This is tested in a real zsh in
`AgentShellIntegrationTests`. Bash and fish only get the `PATH` prepend.

Inside a Balagan terminal a shim runs the wrapper; anywhere else it runs the real binary. The
wrapper passes through untouched when:

- it's a subcommand or one-shot run (`codex login`, `opencode run`, `claude -p`, `pi --print`);
- stdin isn't a terminal;
- the Balagan env is missing;
- it's already inside an agent (`BALAGAN_AGENT_ACTIVE`, set before exec, so a tool calling
  `claude -p` never takes over the tab).

It resolves the real binary with `AgentExecutableResolver`, which skips the shims and its own folder.

A session-start without an id (OpenCode before your first message, Codex in its first seconds) makes
the tab an agent tab at once through `BoardViewModel.runningAgents`. The binding follows when the
session is reported, and the reconciler clears the record when the process dies (you quit the agent
and are back at the shell). `balagan tasks --json` lists each task's `agents` as `name:session` or
`name:pending`.

**UI**: right-click `+` gives "New <Agent> Tab" for each installed agent, with the project default
marked. Installed means found on the login shell's `PATH`, detected once at launch
(`BoardAgentInstallation`). Settings → Agents has the default agent for new projects (all built-ins),
each agent's install path and signals, and "Open Agents Folder" for custom profiles. The project form
has OpenCode/pi presets.

**Verified live** (debug scratch instance, real agents started at a zsh prompt):

- Claude: shim → real `~/.local/bin/claude`, session injected, hooks installed.
- pi: session injected, extension reported session → running → idle.
- OpenCode: agent tab immediately, plugin reported idle → session → running → idle.
- Codex: session bound within 5 s of its first message (in a folder Codex trusts; in an untrusted one
  it waits at its own trust prompt).

## Live activity on task cards

Each card shows what its agent is doing, not just the notes typed at creation: a state + elapsed
line (`Waiting 4m · <summary>`), then a two-line preview of the agent's last response (hidden while
it's running, since the previous turn's answer would read as current). All of it is projected from
signals we already have. State comes from `surfaceLifecycle`, the clock from `surfaceLifecycleSince`
(stamped in `setSurfaceLifecycle`), the summary from the stored `SET_TITLE` title (Claude's
`✳ <summary>`), and the preview from the transcript **tail** (last 256 KB), read off-main when the
agent goes idle/needs-input and once at launch. A multi-tab task describes its loudest tab (waiting >
running > idle, then most recent). Pure rules are `TaskActivity` (Core); the glue is
`BoardTaskActivity.swift`. Transcript reads are off in `--ui-test-mode`; `BALAGAN_FIXTURE_AGENT_STATES=1`
seeds summaries and previews for snapshots.

## Sidebar task list & "next agent needing you"

The sidebar lists each project's tasks under it, in **board order** (the project's lane order, then
position on the board). The order never follows agent state, so rows don't reshuffle under the
cursor. Done tasks are hidden unless they're selected or still need you. A project folds with its
chevron (`Project.sidebarCollapsed`, persisted). When a project is expanded, each task row carries
its own glyph, so the project row only shows the glyph for its hidden Terminals workspace. The
project rows are board filters, so they only highlight on the board. Inside a task, the task row is
the you-are-here marker.

**⌘J** (`ShortcutAction.nextAgentNeedingYou`, rebindable, works from the board too) opens the next
agent that needs you. Waiting agents come first, oldest first, then agents that finished off-screen.
Pressing it again walks the queue and wraps; it beeps when nothing needs you. The sidebar's
"N agents need you" row is the clickable form of the same thing. The queue is the pure
`AgentAttentionQueue`, and the list is `SidebarTaskList` (both Core). The glue is
`BoardAttentionNavigation.swift`.

## Keyboard on the board

When the board is showing, it holds keyboard focus. The arrow keys move a highlight between cards
(an accent ring). Up/down stay in a lane; left/right jump to the nearest lane with cards, keeping
the row. The highlighted card scrolls into view. ⏎ opens it, 1–9 moves it to that lane (counting
collapsed lanes too), ⌘⌫ archives it (with the usual confirmation), and Esc clears the highlight.
Movement is the pure `BoardKeyboardNavigation` (Core); the keys are `onKeyPress` handlers in
`KanbanBoard`, which return `.ignored` for anything else, so menu shortcuts keep working. The
highlight drops when its card leaves the board. Real key presses can't be tested headlessly;
`BALAGAN_SHOW_BOARD_HIGHLIGHT=<task id>` starts with a card highlighted for a snapshot.

## Visual language

Text sizes come from `Theme.TextSize`, never literals: `micro` 10.5 (section caps, badges, counts),
`small` 11.5 (metadata), `body` 12.5 (rows, content), `title` 13.5 (card, project and header titles),
and `heading` 15 (empty-state titles), each times the UI scale. Only glyph-only icon sizes stay
literal. The sidebar has no title or button row. Project actions (`+` = `create-project-button`, and
the pencil = `edit-project-button` when a project is selected) sit on the PROJECTS header. The UI
driver's readiness check and `scripts/balagan-ui-control-contract.txt` depend on those two
identifiers. Project rows are one line, with the repo path in the tooltip. Cards only mark High
priority (a red flag, keeping the `priority-<level>` identifier), and tags render as quiet `#tag`
text.

## Settings window, palette, first run

- **Settings** is a real window (`SettingsWindowController` in `SettingsWindow.swift`), reached
  with ⌘, (app menu "Settings…", a nil-targeted `showSettingsWindow:` that the responder chain hands
  to the app delegate), the sidebar, and the palette. There's no sheet anymore. The window reuses
  `SettingsSheet`'s content (no Done button; the window closes itself). `BALAGAN_SHOW_SETTINGS=1`
  still renders it offscreen to `board-sheet.png`, and `BALAGAN_SETTINGS_CATEGORY=<Name>` picks the
  page. There are two app-level pages beyond the originals:
  - **Agents**: the default agent for new projects, pre-filled into the project form and used by
    the welcome screen.
  - **Notifications**: separate switches for "waiting" and "finished" banners, gated at post time in
    `BoardAgentBanners` (the in-app markers are unaffected), plus the macOS permission state.

  Both pages live in `AppPreferences` (UserDefaults, bound with `@AppStorage`).
- **Command palette** rows can carry a `shortcut` (shown on the right, read from the user's
  bindings). With nothing typed, up to 5 recent tasks come first (`RecentTasks`, Core). "Recent"
  means `taskLastActiveAt`, falling back to `workspace.lastOpenedAt`, and the palette never lists the
  task you're in or repeats a recent one later. The palette also has Review Changes, Reader Mode,
  Show/Hide Inspector, Next Agent Needing You and Sleep Task. Agent-session rows are keyed by
  task + surface.
- **First run**: with no projects, the board shows `WelcomeView`. It explains what a project is and
  has a drop zone. Dropping a folder, or "Choose Folder…", runs `createProject(fromFolder:)`, which
  names the project after the folder and uses the default agent. "New Project…" opens the full
  form.

## Task header

Left to right: the task breadcrumb (status / edit menu), the terminal tabs and `+`, then a
**Terminal | Reader | Changes** switch (`WorkspaceViewSwitcher`, in `TerminalWorkspaceView.swift`).
The three are views of the same task, backed by the existing exclusive `showingReaderMode` /
`showingChangesView` toggles. After that comes the PR chip (when the task tracks a PR), one **Open in**
menu (Zed, Fork, Finder, Copy Path), and ⋯. The ⋯ menu holds layout (Split Right/Down, Zoom Pane) and
tab management (new agent/configured tab, rename, delete). Split and zoom shortcuts come from the
Terminal menu, so there are no view-level `.keyboardShortcut`s for them. Reader and Changes have no
close button of their own: the switch or Esc goes back. The switch falls back to icon-only segments
(`ViewThatFits`) when the header is tight, and never wraps a label. (A right-hand task inspector
existed briefly and was removed: everything in it was already on the card, in Changes, in Open in,
or in the card's right-click menu.)

Right-click menus: a **tab** offers Restart Agent (agent tabs only, meaning ones with an agent session
or an agent launch command; it restarts *that* tab through `TerminalRestart.restart(surfaceID:)`),
Rename Tab… and Close Tab. The **`+`** offers New Terminal Tab and New Agent Tab. The latter is
disabled when the project has no agent command. A plain click on `+` still opens a terminal tab.

## Changes view (review what an agent did)

**⌘⇧G** (`ShortcutAction.toggleChangesView`), or "Changes" in the header's view switch, swaps the terminal pane for
the task's diff, the same way reader mode does. The two are mutually exclusive. The terminal keeps
running detached, and Esc goes back. It shows every file that differs between the task's checkout
and the point where its branch left the project's default branch (`git merge-base HEAD <base>`,
falling back to `origin/<base>`). That covers committed work, uncommitted edits, and untracked files
(shown as all-added). A task working directly on its base branch shows only uncommitted changes. Files
with uncommitted edits get an amber dot, and the header shows commits ahead and +/− totals.

It loads on open, on task switch, when that task's agent stops (idle / needs-input), and on the
refresh button. The data path is read-only git, run off-main (inline in `--ui-test-mode`), with
`GIT_OPTIONAL_LOCKS=0` so it never takes `index.lock` while an agent commits. The runner reads stdout
*before* waiting, because waiting first deadlocks once a big diff fills the pipe buffer, and
`GitWorktreeManager.runGit` still does that. Caps: 8 MB of diff, 200 untracked files at 512 KB each,
and 5000 rendered lines per file. Past those, a "truncated" note points at the editor. Pure parsing is
`GitDiffParser` and git I/O is `TaskChangesLoader` (Core). The glue is `BoardTaskChanges.swift`, and
the view is `Terminal/ChangesView.swift`. `BALAGAN_SHOW_CHANGES=1` opens it for a snapshot. Point
the task's project `repoPath` at a scratch repo to get content.

### Review comments (send feedback to the agent)

Hover a diff line and click its `+` to comment on it (⌘⏎ saves, Esc cancels). Comments show under
their line, with Edit and Delete. The file list shows a count per file, and the top bar shows
"N comments · Discard · **Send to agent**". A comment is a `DiffComment` (Core): path, side (`new`
line number, or `old` for a removed line), the line's text, and the body. Pending comments are saved
on the task (`TaskItem.reviewComments`, optional so older boards decode), so they survive switching
tasks and restarts.

Send composes one message with `ReviewMessage.compose`. It's grouped by file in the diff's order,
then by line, and quotes each line. `BoardReviewComments.sendReviewComments` pastes it into the
task's agent tab: the selected tab if it's an agent, otherwise the first agent tab with a live
terminal. The paste goes through `sendText`, which Ghostty delivers as one **bracketed paste**, so a
multi-line review lands as a single message. An Enter follows 250 ms later to submit it. Then the
comments clear and the view switches to that terminal. Send is disabled, with the reason as its
tooltip, when there are no comments, no live agent tab, or the agent is waiting on a prompt
(`.needsInput`), so the paste can't land inside a permission dialog. The unlisted control method
`review.send --id <task>` triggers the same path. It was verified live against a stand-in that
enables bracketed paste and prints raw bytes: `^[[200~…^[[201~^M`.

### Saved prompts and sending text to an agent

`SavedPrompt` (Core) is a title and text you send to a task's agent in one click. Global prompts live
in UserDefaults (`AppPreferences.Keys.savedPrompts`, JSON; never saved means `SavedPrompts.defaults`:
Write tests, Review your diff, Summarize changes, Commit), edited in **Settings → Prompts**. A project
can add its own (`Project.savedPrompts`, optional in the decoder, edited in the project form). A
task's list is `SavedPrompts.forTask`: the project's first, and a project prompt with the same title
replaces the global one. They're offered as **Send Prompt** in the task header's ⋯ menu and on a
card's right-click menu (`SendPromptMenu`, which shows the reason instead when sending isn't
possible), as "Send: <title>" palette commands, and as `balagan prompt <task> "<title>"`.

Everything that types into an agent goes through one path, `BoardViewModel.sendToAgent(taskID:text:)`
(in `BoardReviewComments.swift`): pick the task's agent tab (`reviewTargetSurface`), refuse with
`agentSendBlocker` (no live agent tab, or the agent is waiting on a prompt), paste as one bracketed
paste, press Enter 250 ms later, then show that terminal. Review comments, saved prompts, and
`balagan send <task> "<text>"` (any text, for scripts and orchestrating agents) all use it.

## When a tab's process exits

Before, any launched process exiting deleted its tab. For an agent that also threw away its
session, and agents quit on their own when they update themselves. Codex offers an update at launch,
installs it and exits. Now `handleEndedProcess` (`BoardAgentExit.swift`) asks the pure
`AgentExitPolicy` (Core):

- **Plain shell**: close the tab, as before.
- **Agent that exits within 90 s of launching** (the self-update pattern): resume its session in
  place (`agentRelauncher` → `TerminalRestart.restart`), and show a 6 s notice over the pane. At most
  2 automatic resumes per tab per 10 min, so a crash-on-start stops looping.
- **Any other agent exit** (quit, crash later, or the loop guard tripped): the tab stays, with a bar
  along the bottom of the pane, "<Agent> exited", **Resume ⏎** and **Close Tab**. An agent tab with
  no captured session offers **Start Agent** instead.

⏎ in a terminal whose process has exited is forwarded by the host (`exitedSurfaceReturnReporter`)
as "resume". Ghostty's own close-on-keypress is a no-op in our runtime, so keys there were dead
anyway. Launch times come from `surfaceLaunchedReporter`, which also clears a stale exited state.
`balagan tasks --json` has `exitedAgent`. Verified live by SIGTERMing `claude` three times: resume,
resume, then offer.

## Earlier sessions per tab

When a tab reports a new agent session, the one it replaces moves into `Surface.previousSessions`
(`SessionRecord`: the full `ResumeBinding`, a title, and when it was replaced). It's newest first,
capped at 20, de-duplicated by session id, and optional so older boards decode. The rules are the
pure `SessionHistory.archiving` / `switching` (Core). Titles are each session's first prompt, read off
the head of its transcript off-main (`SessionHistory.title`, glue in `BoardSessionHistory.swift`), when
a session is archived and once at launch for any untitled record.

Right-click a tab → **Earlier Sessions ▸** "Oct 5, 13:31 · Add passkey login" resumes that session in
the tab: the current one goes into the history, then the tab restarts through the normal Restart
Agent path, which resumes whatever binding is current. Two pid rules keep this safe. An archived
binding never keeps its `pid`, because the OS may have reused it. And the switch SIGTERMs the
*running* agent itself before rebinding, since the restart afterwards only knows the switched-to
session, which has no process. Task token counts include every session the tabs remember.

## Dormant vs live tasks

Terminals only exist once a task is opened or woken in this run of the app. So after a restart
every task is **dormant** (nothing running) until you open it, which looks the same as a task you
slept. `TerminalHostRegistry` reports which tasks have a live host whenever one is created or freed
(`liveTasksReporter`, feeding `BoardViewModel.liveTaskIDs`). `taskIsDormant` means the task has
terminals and none are live. Cards dim and show the moon, sidebar rows show the moon, and the tooltip
gives `dormantReason`: an auto-sleep reason, "Put to sleep", or "Not started since Balagan opened".
Right-click → **Wake** (`wakeInBackground`, via the app's `launchTaskInBackground`) starts every tab
off-screen, so agents resume and shells replay without the task being opened. `balagan tasks` marks
dormant tasks with ☾ (the `live` field in `--json`). In `--ui-test-mode` (fake terminals register
no host) tracking is off, and only an explicit sleep reads as dormant (`tracksLiveTerminals`).

## Auto-sleep (memory reclamation)

Quiet tasks go to sleep on their own, using the same mechanism as the manual right-click → Sleep.
That frees every terminal (renderer, grid, scrollback, child processes), and reopening the task
resumes its agents and replays its shells. It's **on by default at 30 min** (Settings → General →
"Sleep idle tasks after", UserDefaults `autoSleepIdleMinutes`, 0 = never). A task sleeps only when
all of these hold:

- Every agent tab is idle, or hasn't reported a state since resume (it has a session, so it's
  resumable).
- Every plain shell is at its prompt.
- It isn't on screen, has no unseen finished result, and has been quiet for the threshold. Quiet
  means you haven't opened or left it and no agent changed state.

macOS memory-pressure warnings run a pass with a 2 min threshold, even when the timer is off. The
rules are the pure `AutoSleepPlanner` (Core). The glue, timer and `DispatchSourceMemoryPressure` are in
`BoardAutoSleep.swift`. An auto-slept card's moon tooltip says why ("Slept after 32m idle").

**"Shell at its prompt" is Ghostty's own close-confirm check**, `ghostty_surface_needs_confirm_quit`,
which relies on shell-integration prompt marks (`TerminalHostRegistry.terminalIsBusy`). Two things
were learned the hard way here:

- macOS strips the environment from `KERN_PROCARGS2` for every process but your own, even same-user
  children. So "find the terminal's processes by `BALAGAN_SURFACE_ID`" doesn't work, and there's no
  process-scan fallback.
- A reopened plain shell launches as `/bin/sh <replay-script>` → `exec zsh -l`. Ghostty's integration
  *detection* sees `sh` and skips injection, so that shell had no prompt marks and always read as
  busy. `GhosttyConfigOverrides` (Core) fixes it by layering `shell-integration = <shell>` onto the
  user's config through an overrides file the shim loads after the defaults
  (`BALAGAN_GHOSTTY_CONFIG_OVERRIDES`). This only applies to zsh, fish and elvish, whose injection is
  env-only and survives the `exec`. Bash's injection rewrites argv, so it's never forced. A user who
  set `shell-integration` themselves is left alone.

If the check is unavailable or wrong, the failure is safe: the shell reads as busy and the task stays
awake. `balagan autosleep` prints what the planner sees per task, and `--now` runs a pass.
`BALAGAN_AUTOSLEEP_IDLE_SECONDS=<n>` shortens the threshold for a live smoke. Live checks need an
awake display, because surfaces don't mount otherwise; `caffeinate -u -t 120 &` wakes it.

## Terminal search (⌘F)

`ShortcutAction.findInTerminal` (⌘F, rebindable) opens `TerminalSearchBar` over the focused pane
(`LibGhosttyTerminalHostView+Search.swift`). libghostty 1.3 does the matching, highlighting and
scrolling. We drive it with binding actions (`search:<text>`, `navigate_search:next|previous`,
`end_search`), and it reports back through four runtime actions the shim forwards as events:
`START_SEARCH` 59 (with a needle), `END_SEARCH` 60, `SEARCH_TOTAL` 61 and `SEARCH_SELECTED` 62
(0-based; -1 = unknown). The bar shows `selected+1/total` like Ghostty's own overlay. ⏎ = next,
⇧⏎ = previous, Esc closes. While the field has focus, the host view hands key equivalents to it, so
⌘V/⌘A edit the query instead of reaching the terminal. The unlisted control method `terminal.search`
(`--text`, `--next 1`, `--end 1`) drives it headlessly and returns the counts; that's how it was
verified live.

## Dropping files and images onto a terminal

A terminal accepts drops (`LibGhosttyTerminalHostView+Drop.swift`). Files paste as their paths,
backslash-escaped for the shell the way Ghostty does, space-separated with a trailing space
(`TerminalDrop`, Core). Claude Code turns a pasted image path into an image attachment. Image data
with no file behind it (dragged out of a browser) is saved as a PNG under `$BALAGAN_HOME/drops`
first. Links paste as their URL, and text as itself. It's one paste (bracketed, like ⌘V) and never
presses Enter. The pane gets an accent border while hovering. A real drag can't be simulated
headlessly, so the unlisted control method `terminal.drop --paths a,b` (or `--text`) runs the same
`acceptDrop` path. That's how it was verified: `^[[200~/tmp/x/Screen\ Shots/shot\ \(1\).png …^[[201~`.

## Dev server ports

Every 3 s (not in `--ui-test-mode`), `BoardDevServers` scans for TCP listeners among the app's
**descendant processes**. Every terminal is a child of the app, so a server you started elsewhere
never shows. Each listener's working folder is matched to a task: the most specific of each live
task's worktree or repo folder and its terminals' folders wins, and tasks sharing a checkout both
show it. The result is `localhost:<port>` chips (`DevServerChips`) on the card (`:3000`) and in the
task header, which open the browser, and `ports` in `balagan tasks --json`. The rules are the pure
`DevServerPorts.assign`. Agents' own processes (claude, codex, …) and ephemeral ports (≥ 49152, used
by MCP helpers and debuggers) are ignored.

The I/O is `ListeningPortScanner` (libproc, no `lsof`). Two things were learned: parentage must
come from `sysctl(KERN_PROC_ALL)`, because every terminal runs under `/usr/bin/login` (root) and
libproc's `PROC_PIDTBSDINFO` refuses root processes, which cut the tree in two. And the kernel
reports folders by real path (`/tmp` is `/private/tmp`), so task folders go through `realpath`
first. `BALAGAN_FIXTURE_PORTS=1` seeds chips for a snapshot.

## Tokens and cost per task

Each card shows "≈ $4.71 · 7.3M tokens" (`TaskTokenBadge`; hover for input / cache writes / cache
reads / output and the models). It's summed over the task's agent tabs' **current** sessions, from
their transcripts (`ResumeBinding.transcriptPath`, resolved by `TranscriptLocator`). An earlier session a
tab has since replaced isn't counted. The pure counter is `TranscriptTokenCounter` (Core), which is
incremental: `TranscriptTokenCache` keeps one per file and reads only what was appended.

- **Claude** writes one `assistant` line per content block, each repeating the response's `usage`,
  so lines are de-duplicated by message id (a long session has about 2.3× as many lines as
  responses). Sidechain lines (subagents) are skipped. Cache writes are split into 5-minute and
  1-hour writes from `usage.cache_creation`.
- **Codex** logs a running total (`token_count` → `total_token_usage`); the last one counts. Its
  `input_tokens` includes `cached_input_tokens`. The model comes from `turn_context`.

The cost is at **Anthropic API list prices** (`ClaudePricing`, matched by model-id prefix): input,
output, cache writes at 1.25× input (5 minutes) or 2× (1 hour), and cache reads at each model's own
rate (0.025× input on Fable 5.1, 0.05× on Opus 5.5, 0.1× elsewhere). It's a yardstick, since a
subscription isn't billed per token. Codex has no price table, so it shows tokens only. Refreshed at
launch, when a task's agent goes idle or needs input, and every 60 s for live tasks. It's off in
`--ui-test-mode`; `BALAGAN_FIXTURE_TOKENS=1` seeds sample numbers. `balagan tasks --json` includes
`tokens`.

## Subscription usage

The sidebar's meter (`SidebarUsageMeter`, `BoardAgentUsage.swift`) and `balagan usage` show each
agent's 5-hour and weekly limits: percent used and when each resets. The numbers come from what the
agents themselves record, parsed by the pure `AgentUsageParser` / `AgentUsageStore` (Core):

- **Codex** writes `rate_limits` (`primary` / `secondary`: `used_percent`, `window_minutes`,
  `resets_at`) with each `token_count` event in its rollouts. We read the tails of the newest few
  files in the newest day folders of `$CODEX_HOME/sessions`.
- **Claude** only hands `rate_limits` (`five_hour` / `seven_day`) to its **status line** command
  (Pro/Max, after the session's first response). So the injected `--settings` also sets
  `statusLine` to `balagan-agent statusline`. That records the limits in
  `$BALAGAN_HOME/usage/claude.json` (default `~/.balagan`) and then runs the user's own status line
  (`ClaudeStatusLine.userSetting`: project `settings.local.json` → project `settings.json` → user
  settings; ours is never picked) with the same stdin, passing its output through. Their
  `padding`/`refreshInterval` are copied onto ours. With no status line of their own, we print a
  compact `model · ctx · 5h · Week` line.

Claude's numbers are the status line's live 5-hour / weekly reading **merged** with Claude's own
cache of its usage page, `cachedUsageUtilization` in `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json`
when set), which Claude refreshes when it fetches usage (e.g. `/usage`). The cache adds every other
limit in its `limits` array (model-scoped ones like the **Fable weekly limit**), extra-usage status,
and the plan (from `oauthAccount`: "Max 5x · Team"). Per window the newer reading wins, and an older
window keeps its own `observedAt` so the details can say "as of 22h ago". Codex adds its `plan_type`
and credits. `AgentUsageParser.claudeCache` / `AgentUsage.merged(with:)` are pure and tested; the
timestamp parser trims Claude's microseconds, which `ISO8601DateFormatter` rejects.

A window past its reset time reads 0% (`UsageWindow.hasReset`, dimmed) until the agent reports
again. In the sidebar the 5h / Week windows always sit in the same columns, and other windows only
show in the details. Compact shows just each agent's tightest window
(`AppPreferences.Keys.usageCompact`). **Each agent's row is a button** that opens its own
`AgentUsageDetails` popover: plan, every window with its bar and exact reset time, notes, when it
last reported, refresh, a link to the agent's usage page, and the Detailed / Compact choice.
`BALAGAN_SHOW_USAGE_DETAILS=<agent>` opens one at launch for a screenshot (a popover is its own
window, so capture the screen, not `board-app.png`). Usage refreshes the moment
`usage/claude.json` is rewritten (a folder watcher), every 60 s, and whenever an agent goes idle or
needs input. It's off in `--ui-test-mode`;
`BALAGAN_FIXTURE_USAGE=1` seeds sample numbers for a snapshot.

## Reader mode & speak-last-response

Both features are **projections of the agent's on-disk session transcript** — they never scrape the
terminal (so no `read_text` calls; see the leak gotcha).

- **Data path**: `balagan-agent` captures the transcript path at session start (Claude: the hook
  payload's `transcript_path`; Codex: the rollout file resolved by session id) →
  `SessionReportEvent.transcriptPath` → persisted on `ResumeBinding.transcriptPath`.
  `TranscriptLocator` (Core) resolves stored-path-first with a session-id glob fallback over
  `~/.claude/projects` / `~/.codex/sessions` (session ids are unique — no cwd-slug derivation).
- **Parsing** (Core, pure, tested): `AgentTranscriptParser` normalizes both agents' JSONL into
  `TranscriptEntry` (user / assistant / toolUse / thinking), filtering sidechains, meta records, tool
  results, and harness noise. `lastAssistantResponse` extracts the latest prose;
  `SpeakableText.sentences` turns markdown into TTS-safe sentences (code fences announced not read,
  URLs → host, paths → basename). `TranscriptTailBuffer` handles incremental line parsing.
- **Reader mode** (⌘⇧R, "Reader" in the header's view switch, `balagan reader`): swaps the terminal pane — not an
  overlay — for `ReaderModeView` (the terminal host survives detachment exactly like an unselected
  tab). Renders prose via `ReaderMarkdownView` (a reading-size sibling of `MarkdownBlockView`) at a
  ~66-char measure; `TranscriptTailer` live-follows the file while open (timer + off-main incremental
  parse; first read synchronous so snapshots are deterministic). Plain shells fall back to re-wrapped
  scrollback. Font size and theme (dark/sepia/light — `ReaderPalette`; the dark variant deliberately
  dims body text to avoid halation) persist in `UIAppearanceSettings.readerFontSize`/`.readerTheme`;
  `BALAGAN_READER_THEME=<dark|sepia|light>` forces one for snapshots.
- **Speech** (⌘⇧S toggle-to-stop, `balagan speak [--dry-run]`): `SpeechController` (one long-lived
  `AVSpeechSynthesizer` — it stops if deallocated) speaks sentence-sized utterances (enables sentence
  skip ± and the HUD's current-sentence display; avoids the long-string range-callback drift).
  `SpeechHUD` floats at board level so playback survives navigation. Voice/rate live in UserDefaults
  (app-level, not board state). Siri voices are never available to apps; premium voices appear only
  after the user downloads them in System Settings.

## Smoke harness

`BoardSmokeHarness.swift` holds the deterministic recorders, invoked by launch flags and the
`scripts/balagan-harness.sh` wrappers (the `make *-smoke` targets). These drive the app and/or the
`BalaganUIDriver` and write artifacts (JSON, accessibility dumps, screenshots) under
`.ui-artifacts/` (gitignored). GUI smokes need the unsandboxed exception above.

## Controlling the app from the CLI

The `balagan` executable is a thin client that drives the **running** app over a local
request/response Unix socket (cmux-style). The app listens; the CLI connects, sends one JSON request
line, reads one JSON response line, and exits.

- **Socket path**: `~/.balagan/control.sock` (override with `$BALAGAN_CONTROL_SOCKET`, or the app's
  `--control-socket <path>` launch flag — used by tests to avoid clobbering a real instance's socket).
- **Wire**: `{"method":"…","params":{…}}\n` → `{"ok":true,"result":…}\n` / `{"ok":false,"error":"…"}\n`.
- **Where it lives**: protocol + arg-parsing + client in `BalaganCore/ControlProtocol.swift` (pure,
  unit-tested in `ControlProtocolTests`); the app-side server in `BalaganApp/ControlSocketServer.swift`
  (reads on a background queue, replies on the main actor); the command dispatch is
  `handleControlCommand(method:params:)` in `BalaganApp.swift` (`@MainActor`, touches `BoardViewModel`
  + the window). The CLI front-end is `Sources/BalaganCLI/main.swift` (I/O + human formatting only).
- **Commands**: `ping`, `projects`, `usage`, `send <task> <text>`, `prompt <task> <title>`, `tasks [--project <id>]` (`--json` includes each task's `agents`), `create --project <id> --title <t> [--branch|--notes|--status|--priority]`,
  `open <task-id>`, `status`, `reader` (toggle reader mode on the selected task), `speak [<task-id>]
  [--dry-run]` (speak the last agent response; `--dry-run` returns the speakable text — the headless
  test seam for the whole transcript→speech pipeline). `--json` prints the raw response; a dotted
  command (e.g. `task.open`) is sent verbatim as the method. Add a command by adding a `case` to
  `handleControlCommand` (+ a mapping in `ControlCLI.parse` if it needs a friendly subcommand).
- This path is **headless-verifiable** (no display): launch the app `--ui-test-mode --control-socket
  /tmp/x.sock`, then run `balagan --socket /tmp/x.sock …`.
- **Auto-install on launch**: a packaged `.app` symlinks its bundled `balagan` onto PATH on every
  launch (first writable of `/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`). Logic is the
  unit-tested `ControlCLIInstaller` (never clobbers a real file; replaces only a stale symlink of
  ours); the gated glue is `installControlCLISymlinkIfPossible` in `BalaganApp.swift` (only fires
  from a `.app`, never the dev/.build binary, never in `--ui-test-mode`). Test override:
  `--control-cli-link-dir <dir>`.

## Gotchas (learned the hard way)

- **`ghostty_surface_read_text` leaks ~3 KB per call inside libghostty 1.3.1** (verified with
  `leaks`: `heap.CAllocator.alloc` roots; pairing with `ghostty_surface_free_text` does not release
  it — the leak is ghostty-internal). Never call it on a hot path. Visible-text reads are rationed:
  the render loop reads only while watching for the ended-process prompt (post-exit) or when
  artifacts are enabled, and autosave serves cached text for debounced saves — only the 30 s
  periodic floor, explicit saves, and the termination flush read fresh
  (`TerminalCaptureFreshness`). An earlier build that read on every save reached a 28 GB footprint
  in a day (footprint, not RSS — the leaked pages compress out of RSS, so check Activity Monitor
  or `vmmap --summary`, not `ps -o rss`).
- **Don't close a `DispatchSource`-monitored fd anywhere but its cancel handler — and not at all on
  quit.** A read source (`ControlSocketServer` / `AppSessionReportServer`) guards its fd; closing it a
  second time crashes with `EXC_GUARD` (`GUARD_TYPE_FD`, "CLOSE on file descriptor N") only when the
  freed fd number is reused by another guarded fd in the window between the two closes — so it's an
  *intermittent* crash, not a deterministic one (a plain double-close just returns `EBADF`). Two ways it
  bit us: (1) `stop()` closed the fd directly **and** via the cancel handler; (2) even single-close
  teardown on `applicationWillTerminate` cancels the source on a background queue, whose async close
  races with the synchronous termination autosave opening the SQLite db onto the just-freed fd number.
  Fix: close exactly once (cancel handler owns it), and **do not tear the sockets down on quit at all** —
  the kernel reaps fds and both servers `unlink`+rebind on next launch. Diagnosing this: the launch time
  in the `.ips` predated the fix commit, proving the long-lived process was running stale pre-fix code —
  check `procLaunch` vs. `git log` dates, and don't trust `CFBundleVersion` (the build-number stamp skews).
- **An ad-hoc signed bundle gets NO desktop notifications — and so does a signed one with duplicate
  LaunchServices records.** macOS's notification daemon refuses `UNUserNotificationCenter.requestAuthorization`
  ("Notifications are not allowed for this application"; `didGrant: 0 hasError: 1` in the unified log),
  leaves the app `authorizationStatus: Denied` *without ever creating a Notifications entry in System
  Settings*, and drops every posted request ("Presenting … as none") while `add(request)` reports
  success. This is why banners "never worked" until 2026-09-06. What fixed it, in order: (1) sign with
  a stable identity — the **self-signed** cert from `scripts/make-signing-cert.sh` is sufficient
  (Apple-issued preferred if present; `build-app.sh` auto-detects, `BALAGAN_CODESIGN_IDENTITY`
  overrides); (2) leave exactly **one** LaunchServices registration for the bundle id — with a
  `.previous` copy in /Applications and the dist/ build both registered, the daemon kept refusing even
  after re-signing, and `lsregister -u <other copies>; lsregister -f /Applications/Balagan.app` is
  what made macOS finally prompt "Balagan would like to send you notifications". `scripts/install-app.sh`
  does both the move-aside and the registration cleanup — use it instead of `cp -R`. Re-signing changes
  the app's TCC identity, so macOS re-prompts (click Allow). `SystemNotificationPresenter` records the
  authorization outcome (and re-checks it at post time, since the grant can arrive after launch); when
  denied it drops the banner and shows a one-time alert with the fix — deliberately *not* the osascript
  fallback, whose banners carry Script Editor's icon and open Script Editor on click — and `balagan
  status` prints the state (`Notifications: …`). Diagnose with
  `/usr/bin/log show --info --last 10m --predicate 'process == "usernoted"' | grep -i balagan` and
  `lsregister -dump | grep -B1 com.joeyfeldberg.Balagan | grep path:` (must list one path).
- **One `.alert(item:)` per view.** SwiftUI silently honors only the *last* `.alert(item:)` in a view;
  stacking two makes the earlier one stop presenting (this is exactly what made "Remove Worktree" do
  nothing once the archive alert was added alongside it). Use the `.alert(title:isPresented:)` form when
  a view needs several alerts — those coexist fine.
- **`.sheet` modals are separate windows.** They're *not* in the window `contentView`, so the
  in-process snapshot (`board-app.png`) never captures them (see "Taking screenshots"); and only one
  `.sheet` presents at a time. `UNUserNotificationCenter` likewise needs a real bundle id — neither
  works from the dev `.build` binary the way it does from a packaged `.app`.
- **Worktree/branch contract.** A task's `branchOrWorktree` **blank = the project's main checkout, no
  worktree** (the New Task form's "Work on main" toggle); non-blank = a git worktree on that branch,
  auto-named from the title via `BranchNaming.slug`. You cannot express "main" by *typing* the default
  branch name — `git worktree add … main` fails because it's already checked out, so "main" must be the
  blank/no-worktree state. Removing a worktree also runs `git branch -d` (safe: keeps unmerged branches).

## Conventions

- Git: work off `main`; commit per logical change (the model collapse was done one model per commit
  with a build + `swift test` gate between each — keep that discipline for risky refactors). The
  maintainer pushes each commit straight to `main` right after committing, with no feature branch or
  PR. Outside contributors should open a pull request.
- When changing behavior, prefer extending the smoke harness / unit tests over manual checks.
- `docs/testing.md` (harness) has deeper detail.

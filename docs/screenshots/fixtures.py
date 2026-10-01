# Writes the README demo states (board / task / changes) and the agent activity seed into OUT.
# BASE is any valid BoardSnapshot the app wrote; its schema and UI settings are reused.
import json, copy, sys
BASE, OUT, REPO = sys.argv[1], sys.argv[2], sys.argv[3]
base = json.load(open(BASE))
lanes = copy.deepcopy(base['boardState']['projects'][0]['lanes'])
for l in lanes:
    if l['id'] == 'parked': l['name'] = 'Review'
lanes = [lanes[0], lanes[1], lanes[3], lanes[2]]  # Todo, Doing, Review, Done
def project(pid, name, path): return {"id": pid, "name": name, "repoPath": path, "lanes": lanes}
projects = [project("acme-api", "acme-api", "/Users/dev/code/acme-api"),
            project("dashboard", "dashboard", "/Users/dev/code/dashboard"),
            project("balagan", "balagan", "/Users/dev/code/balagan")]
paths = {p["id"]: p["repoPath"] for p in projects}

AGENT = """ ✻ Claude Code

> Replace password login with passkeys. Keep the session cookie format
  the same so existing sessions stay valid.

⏺ I'll start with how login and sessions work today.

⏺ Read(src/auth/login.ts)
  ⎿  Read 142 lines

⏺ Search(pattern: "createSession", path: "src")
  ⎿  Found 6 files

⏺ Here's the plan:
  1. Add WebAuthn register and login endpoints
  2. Store credentials in a new passkey_credentials table
  3. Reuse createSession() so the cookie format doesn't change
  4. Keep password login working until every user has a passkey

⏺ Write(migrations/0042_passkey_credentials.sql)
  ⎿  Wrote 18 lines

⏺ Write(src/auth/passkeys.ts)
  ⎿  Wrote 131 lines

⏺ Update(src/auth/routes.ts)
  ⎿  Updated with 9 additions

⏺ Bash(npm test -- auth)
  ⎿  PASS  test/auth/passkeys.test.ts (14 tests)
     PASS  test/auth/session.test.ts (9 tests)
     PASS  test/auth/login.test.ts (21 tests)

⏺ Registration and login work end to end, and existing sessions still
  validate. Should I remove the old password-reset endpoints now, or keep
  them behind a flag for one release?

> """
SERVER = """$ npm run dev

> acme-api@3.8.0 dev
> tsx watch src/server.ts

[12:41:07] listening on http://localhost:4000
[12:41:22] POST /auth/passkeys/register/options 200 4ms
[12:41:23] POST /auth/passkeys/register 201 31ms
[12:41:30] POST /auth/passkeys/login/options 200 3ms
[12:41:31] POST /auth/passkeys/login 200 18ms
[12:41:31] GET  /me 200 2ms
"""
def surface(sid, wid, title, scroll, cwd):
    return {"cwd": cwd, "environment": {}, "id": sid, "kind": "terminal",
            "scrollbackSnapshot": scroll, "title": title, "workspaceID": wid}
def task(tid, pid, status, title, notes, tags, priority="medium", surfaces=None, layout=None):
    wid = "workspace-" + tid
    cwd = paths[pid]
    surfs = surfaces or [surface("agent", wid, "claude", "$ ", cwd)]
    lay = layout or {"tabs": {"_0": [{"surface": {"_0": s["id"]}} for s in surfs]}}
    ws = {"id": wid, "lastOpenedAt": "2026-10-01T16:00:00Z", "layout": lay,
          "selectedSurfaceID": surfs[0]["id"], "surfaces": surfs, "taskID": tid}
    return {"createdAt": "2026-10-01T15:00:00Z", "id": tid, "notes": notes, "priority": priority,
            "projectID": pid, "status": status, "tags": tags, "title": title,
            "updatedAt": "2026-10-01T16:00:00Z", "workspace": ws}

wid = "workspace-passkeys"
cwd = paths["acme-api"]
passkey_surfaces = [surface("agent", wid, "✳ Passkey registration flow", AGENT, cwd),
                    surface("server", wid, "npm run dev", SERVER, cwd),
                    surface("shell", wid, "zsh", "$ git status --short\n M src/auth/routes.ts\n?? migrations/0042_passkey_credentials.sql\n?? src/auth/passkeys.ts\n$ ", cwd)]
passkey_layout = {"tabs": {"_0": [
    {"split": {"axis": "horizontal", "children": [{"surface": {"_0": "agent"}}, {"surface": {"_0": "server"}}]}},
    {"surface": {"_0": "shell"}}]}}

tasks = [
    task("passkeys", "acme-api", "doing", "Migrate auth to passkeys",
         "Replace password login with WebAuthn passkeys.", ["auth"], "high", passkey_surfaces, passkey_layout),
    task("trace-table", "dashboard", "doing", "Virtualize the trace table",
         "Render only visible rows; the table stalls past 20k spans.", ["perf"]),
    task("webhook-flake", "acme-api", "doing", "Fix flaky webhook retry test",
         "Fails about 1 in 30 runs on CI.", ["tests"]),
    task("rate-limit", "acme-api", "todo", "Rate-limit the public API",
         "Token bucket per API key, 429 with Retry-After.", ["api"]),
    task("settings-dark", "dashboard", "parked", "Dark mode for settings",
         "Settings pages ignore the theme toggle.", ["ui"]),
    task("audit-log", "acme-api", "todo", "Audit log for admin actions",
         "Record who changed what, retained for 90 days.", ["security"]),
    task("csv-export", "dashboard", "done", "CSV export for saved queries",
         "Users want to pull query results into spreadsheets.", ["feature"]),
    task("swift-61", "balagan", "done", "Bump to Swift 6.1",
         "Fix the new strict-concurrency warnings.", ["build"]),
    task("onboarding", "dashboard", "done", "Onboarding checklist",
         "Three-step checklist on first login.", ["ui"]),
]

def snapshot(selected):
    d = copy.deepcopy(base)
    d["boardState"] = {"projects": projects, "tasks": tasks, "workspaces": [t["workspace"] for t in tasks]}
    ui = d["uiState"]
    for k in ["selectedTaskID", "selectedWorkspaceID", "selectedSurfaceID"]: ui.pop(k, None)
    if selected:
        ui.update(selectedTaskID=selected, selectedWorkspaceID="workspace-" + selected, selectedSurfaceID="agent")
    return d
json.dump(snapshot(None), open(f"{OUT}/board.json", "w"))
json.dump(snapshot("passkeys"), open(f"{OUT}/task.json", "w"))
projects[0]["repoPath"] = REPO
json.dump(snapshot("passkeys"), open(f"{OUT}/changes.json", "w"))

json.dump({
    "passkeys": {"state": "needs-input", "summary": "Passkey registration flow", "minutes": 3,
                 "response": "Registration and login work end to end. Should I remove the old password-reset endpoints now, or keep them behind a flag for one release?"},
    "trace-table": {"state": "running", "summary": "Windowed row rendering", "minutes": 8},
    "webhook-flake": {"state": "running", "summary": "Reproducing the retry race", "minutes": 2},
    "csv-export": {"state": "idle", "summary": "Streaming CSV export", "minutes": 14,
                   "response": "Done. The export streams rows instead of buffering them, so a 1M-row query stays under 40 MB. Added tests for quoting and Unicode."},
    "swift-61": {"state": "idle", "summary": "Strict concurrency fixes", "minutes": 62,
                 "response": "All 512 tests pass on Swift 6.1. Three Sendable warnings needed real fixes; the rest were annotations."},
}, open(f"{OUT}/activity.json", "w"))

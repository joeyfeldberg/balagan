#!/usr/bin/env bash
# Headless end-to-end smoke of the agent-hook → app-state path.
#
# Runs the real `balagan-agent hook <event>` binary against a real running app and asserts the
# task's aggregate agent state as the `balagan` CLI reports it — the same wire an agent's Claude
# hooks use in production (stdin payload → SessionReportEvent → session-report socket →
# applyReportedSessionCapture → `balagan state`). Also asserts the wrapper's hook log names each
# outcome, so "the hook never fired" is distinguishable from "it fired and was dropped/failed".
#
# `--ui-test-mode` means no display and no sandbox exception are needed. Everything (sockets, state,
# artifacts, hook log) is redirected into /tmp with short names: AF_UNIX paths are capped at ~104
# bytes, and a test must never touch the live app's ~/.balagan sockets or hook log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/${SWIFT_BUILD_CONFIGURATION:-debug}"

RUN_ID="$$"
RUN_DIR="/tmp/tb-hs-$RUN_ID"
CONTROL_SOCKET="/tmp/tb-hs-$RUN_ID.sock"
REPORT_SOCKET="/tmp/tb-hs-$RUN_ID-sr.sock"
STATE_PATH="/tmp/tb-hs-$RUN_ID.json"
HOOK_LOG="$RUN_DIR/agent-hooks.log"
APP_PID=""
FAILED=0

log() {
  printf 'hook-lifecycle-smoke: %s\n' "$*"
}

fail() {
  printf 'hook-lifecycle-smoke: FAIL: %s\n' "$*" >&2
  FAILED=1
  exit 1
}

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$CONTROL_SOCKET" "$REPORT_SOCKET" "$STATE_PATH"
  if [[ "$FAILED" -eq 0 ]]; then
    rm -rf "$RUN_DIR"
  else
    printf 'hook-lifecycle-smoke: artifacts kept in %s\n' "$RUN_DIR" >&2
  fi
}
trap cleanup EXIT
mkdir -p "$RUN_DIR"

if [[ "${BALAGAN_SKIP_BUILD:-0}" != "1" ]]; then
  log "building"
  (cd "$ROOT" && swift build >/dev/null) || fail "swift build failed"
fi

APP="$BUILD_DIR/BalaganApp"
CLI="$BUILD_DIR/balagan"
AGENT="$BUILD_DIR/balagan-agent"
for binary in "$APP" "$CLI" "$AGENT"; do
  [[ -x "$binary" ]] || fail "missing executable: $binary (run swift build)"
done

log "launching app (ui-test-mode, fixture multi-project-running)"
"$APP" \
  --ui-test-mode \
  --fixture multi-project-running \
  --control-socket "$CONTROL_SOCKET" \
  --session-report-socket "$REPORT_SOCKET" \
  --state-path "$STATE_PATH" \
  --artifact-dir "$RUN_DIR" \
  >"$RUN_DIR/app.log" 2>&1 &
APP_PID="$!"

for _ in $(seq 1 60); do
  [[ -f "$RUN_DIR/app-ready.json" ]] && break
  sleep 0.25
done
[[ -f "$RUN_DIR/app-ready.json" ]] || fail "app did not write app-ready.json; see $RUN_DIR/app.log"

# The fixture's real ids, as the app itself reports them — never hard-coded here.
json_string() {
  sed -n "s/.*\"$2\" : \"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
TASK_ID="$(json_string "$RUN_DIR/app-ready.json" selectedTaskId)"
WORKSPACE_ID="$(json_string "$RUN_DIR/app-ready.json" selectedWorkspaceId)"
SURFACE_ID="$(json_string "$RUN_DIR/app-ready.json" selectedSurfaceId)"
[[ -n "$TASK_ID" && -n "$WORKSPACE_ID" && -n "$SURFACE_ID" ]] \
  || fail "could not read task/workspace/surface ids from $RUN_DIR/app-ready.json"
log "routing to task=$TASK_ID workspace=$WORKSPACE_ID surface=$SURFACE_ID"

# Runs the wrapper exactly as Claude would: payload on stdin, routing in the environment. Asserts the
# hook contract itself — exit 0 and empty stdout (a hook's stdout is fed back into the agent).
send_hook() {
  local event="$1" payload="$2"
  local stdout_file="$RUN_DIR/hook-$event.out"
  local status=0
  printf '%s' "$payload" | env \
    BALAGAN_TASK_ID="$TASK_ID" \
    BALAGAN_WORKSPACE_ID="$WORKSPACE_ID" \
    BALAGAN_SURFACE_ID="$SURFACE_ID" \
    BALAGAN_SOCKET_PATH="$REPORT_SOCKET" \
    BALAGAN_HOOK_LOG="$HOOK_LOG" \
    "$AGENT" hook "$event" >"$stdout_file" 2>"$RUN_DIR/hook-$event.err" || status=$?
  [[ "$status" -eq 0 ]] || fail "hook $event exited $status (must always exit 0)"
  if [[ -s "$stdout_file" ]]; then
    fail "hook $event wrote to stdout: $(cat "$stdout_file")"
  fi
}

expect_state() {
  local event="$1" expected="$2" actual=""
  for _ in $(seq 1 20); do
    actual="$("$CLI" --socket "$CONTROL_SOCKET" state "$TASK_ID" 2>&1 || true)"
    [[ "$actual" == "$TASK_ID is $expected" ]] && break
    sleep 0.25
  done
  if [[ "$actual" != "$TASK_ID is $expected" ]]; then
    fail "after $event: expected '$TASK_ID is $expected', got '$actual'"
  fi
  log "after $event: $actual"
}

expect_log_line() {
  local pattern="$1"
  grep -q -F -- "$pattern" "$HOOK_LOG" \
    || fail "hook log missing a line matching '$pattern'; log is:$(printf '\n%s' "$(cat "$HOOK_LOG" 2>/dev/null)")"
}

# 1. A permission request blocks on the user.
send_hook permission-request '{"session_id":"hook-smoke-session","tool_name":"Bash","cwd":"/tmp"}'
expect_state permission-request needs-input

# 2. The tool completed, so the agent is working again.
send_hook post-tool '{"session_id":"hook-smoke-session","tool_name":"Bash","cwd":"/tmp"}'
expect_state post-tool running

# 3. A subagent's hook (agent_id present) must not move the parent surface — state stays running.
send_hook pre-tool '{"session_id":"hook-smoke-session","tool_name":"Read","agent_id":"subagent-1","cwd":"/tmp"}'
expect_state pre-tool running

# 4. Stop settles the agent.
send_hook stop '{"session_id":"hook-smoke-session","cwd":"/tmp"}'
expect_state stop idle

# 5. A hook with no routing environment is dropped, not silently lost.
printf '%s' '{"session_id":"hook-smoke-session"}' \
  | env -u BALAGAN_TASK_ID -u BALAGAN_WORKSPACE_ID -u BALAGAN_SURFACE_ID -u BALAGAN_SOCKET_PATH \
    BALAGAN_HOOK_LOG="$HOOK_LOG" "$AGENT" hook stop >"$RUN_DIR/hook-missing-env.out" 2>&1 \
  || fail "hook with missing env did not exit 0"
if [[ -s "$RUN_DIR/hook-missing-env.out" ]]; then
  fail "hook with missing env wrote output: $(cat "$RUN_DIR/hook-missing-env.out")"
fi

# 6. A dead socket is reported as a send failure, not as nothing at all.
printf '%s' '{"session_id":"hook-smoke-session"}' | env \
  BALAGAN_TASK_ID="$TASK_ID" \
  BALAGAN_WORKSPACE_ID="$WORKSPACE_ID" \
  BALAGAN_SURFACE_ID="$SURFACE_ID" \
  BALAGAN_SOCKET_PATH="/tmp/tb-hs-$RUN_ID-absent.sock" \
  BALAGAN_HOOK_LOG="$HOOK_LOG" \
  "$AGENT" hook stop >"$RUN_DIR/hook-dead-socket.out" 2>&1 \
  || fail "hook against a dead socket did not exit 0"
if [[ -s "$RUN_DIR/hook-dead-socket.out" ]]; then
  fail "hook against a dead socket wrote output: $(cat "$RUN_DIR/hook-dead-socket.out")"
fi

log "checking hook log $HOOK_LOG"
[[ -f "$HOOK_LOG" ]] || fail "no hook log written at $HOOK_LOG"
expect_log_line "event=permission-request lifecycle=needs-input task=$TASK_ID surface=$SURFACE_ID tool=Bash outcome=sent"
expect_log_line "event=post-tool lifecycle=running task=$TASK_ID surface=$SURFACE_ID tool=Bash outcome=sent"
expect_log_line "event=pre-tool lifecycle=- task=$TASK_ID surface=$SURFACE_ID tool=Read outcome=dropped: subagent"
expect_log_line "event=stop lifecycle=idle task=$TASK_ID surface=$SURFACE_ID tool=- outcome=sent"
expect_log_line "event=stop lifecycle=idle task=- surface=- tool=- outcome=dropped: missing-env"
expect_log_line "event=stop lifecycle=idle task=$TASK_ID surface=$SURFACE_ID tool=- outcome=send-failed: connect:"
if grep -q "hook-smoke-session" "$HOOK_LOG"; then
  fail "hook log leaked payload content (the session id from the hook payload)"
fi

HOOK_LINES="$(wc -l <"$HOOK_LOG" | tr -d ' ')"
[[ "$HOOK_LINES" -eq 6 ]] || fail "expected 6 hook log lines, got $HOOK_LINES"

log "PASS — 4 lifecycle hooks routed, 2 failure outcomes logged, $HOOK_LINES log lines"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT/UITestFixtures"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/.ui-artifacts}"

BALAGAN_SCHEME="${BALAGAN_SCHEME:-Balagan}"
BALAGAN_UI_TEST_SCHEME="${BALAGAN_UI_TEST_SCHEME:-BalaganUITests}"
BALAGAN_DESTINATION="${BALAGAN_DESTINATION:-platform=macOS}"
BALAGAN_BUILD_CONFIGURATION="${BALAGAN_BUILD_CONFIGURATION:-Debug}"
SWIFT_BUILD_CONFIGURATION="${SWIFT_BUILD_CONFIGURATION:-debug}"
BALAGAN_FREEZE_TIME="${BALAGAN_FREEZE_TIME:-2026-05-29T12:00:00Z}"

log() {
  printf 'balagan-harness: %s\n' "$*"
}

die() {
  printf 'balagan-harness: error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/balagan-harness.sh <command> [fixture]

Commands:
  build              Build the app target when one exists.
  test               Run unit/integration tests when targets exist.
  ui-test            Run deterministic UI smoke tests and XCUITest when available.
  ui-controls-smoke  Verify create/edit/status flow controls are exposed to UI tests.
  ui-flow-smoke      Verify scripted create/edit/status/tab flow persists through SQLite restore.
  ui-native-flow-smoke Drive create/edit/status/tab through macOS Accessibility and verify restore.
  ui-daily-driver-smoke Drive next-session daily workflows through macOS Accessibility.
  terminal-input-smoke Verify typed input reaches a live libghostty shell.
  terminal-manual-input-smoke Verify physical letter key events reach a live libghostty shell.
  terminal-visible-typing-smoke Verify physical key events are displayed in the visible libghostty buffer.
  terminal-control-keys-smoke Verify Ctrl+C and Ctrl+D reach a live libghostty shell.
  terminal-keyboard-shortcuts-smoke Verify Ghostty-like terminal keyboard shortcuts.
  terminal-navigation-smoke Verify a live libghostty shell survives task/project navigation.
  terminal-state-smoke Capture terminal startup output into SQLite and verify restore.
  terminal-restart-resume-smoke Verify selected workspace/surface restore and resume confirmation markers.
  agent-reopen-smoke  Verify a default agent tab captures and reopens with the resume command.
  hook-smoke          Verify session-start reports update persisted trusted resume capture.
  hook-lifecycle-smoke Verify agent lifecycle hooks move a task's state end to end (no display needed).
  agent-wrapper-smoke Verify balagan-agent wrapper emits session-start through the app socket.
  terminal-reload-prompt-smoke Verify restart resume metadata does not leak into the live prompt.
  terminal-close-open-prompt-smoke Verify typed ls plus close/open leaves a clean prompt and default shell.
  terminal-ended-autoclose-smoke Verify ended startup command terminals auto-close without keypress.
  ui-debug [fixture] Stage and launch the app in deterministic debug mode.
  normal-store-smoke Verify a normal SQLite restore with real processes disabled.
  first-run-smoke Verify a normal empty first run with a fresh SQLite database.
  live-backend-smoke Run a local libghostty backend smoke when Ghostty is installed.
  lint               Validate fixtures and shell script syntax.
  validate-fixtures  Validate all UITestFixtures/*.json files.
EOF
}

first_match() {
  local pattern="$1"
  local match
  shopt -s nullglob
  for match in "$ROOT"/$pattern; do
    if [[ -e "$match" ]]; then
      printf '%s\n' "$match"
      return 0
    fi
  done
  return 1
}

xcode_workspace() {
  if [[ -n "${BALAGAN_XCODE_WORKSPACE:-}" ]]; then
    printf '%s\n' "$BALAGAN_XCODE_WORKSPACE"
    return 0
  fi
  first_match "*.xcworkspace"
}

xcode_project() {
  if [[ -n "${BALAGAN_XCODE_PROJECT:-}" ]]; then
    printf '%s\n' "$BALAGAN_XCODE_PROJECT"
    return 0
  fi
  first_match "*.xcodeproj"
}

prepare_swift_environment() {
  local cache_root="$ROOT/.build/harness-cache"
  mkdir -p "$cache_root/clang" "$cache_root/swiftpm"

  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}"
}

fixture_path() {
  local fixture="$1"
  if [[ ! "$fixture" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "fixture names may only contain letters, numbers, underscores, and hyphens: $fixture"
  fi

  local path="$FIXTURES_DIR/$fixture.json"
  [[ -f "$path" ]] || die "fixture not found: $path"
  printf '%s\n' "$path"
}

validate_json_file() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$path" >/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$path" >/dev/null
  else
    log "skipping JSON syntax validation for $path; neither jq nor python3 is available"
  fi
}

validate_fixtures() {
  local files=()
  local path
  shopt -s nullglob
  files=("$FIXTURES_DIR"/*.json)
  [[ "${#files[@]}" -gt 0 ]] || die "no fixture JSON files found in $FIXTURES_DIR"

  for path in "${files[@]}"; do
    validate_json_file "$path"
    log "validated fixture $(basename "$path")"
  done
}

prepare_fixture_worktrees() {
  local fixture_file="$1"
  local path
  local paths=()

  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      paths+=("$path")
    done < <(jq -r '(.projects[]?.repoPath // empty), (.tasks[]?.repoPathOverride // empty)' "$fixture_file")
  elif command -v python3 >/dev/null 2>&1; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      paths+=("$path")
    done < <(python3 - "$fixture_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fixture:
    payload = json.load(fixture)

for project in payload.get("projects", []):
    path = project.get("repoPath")
    if path:
        print(path)

for task in payload.get("tasks", []):
    path = task.get("repoPathOverride")
    if path:
        print(path)
PY
)
  else
    log "skipping fixture worktree prep; neither jq nor python3 is available"
    return 0
  fi

  for path in "${paths[@]}"; do
    case "$path" in
      /tmp/balagan-fixtures/*)
        mkdir -p "$path"
        ;;
      *)
        log "skipping non-temporary fixture worktree path: $path"
        ;;
    esac
  done
}

sql_quote() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

make_run_dir() {
  local command="$1"
  local fixture="$2"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  local run_dir="$ARTIFACT_ROOT/$command/$stamp-$fixture"
  mkdir -p "$run_dir/screenshots"
  printf '%s\n' "$run_dir"
}

seed_fixture_database() {
  local fixture="$1"
  local fixture_file="$2"
  local run_dir="$3"
  local db="$run_dir/Balagan.sqlite"

  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf '%s\n' "sqlite3 is unavailable; database seeding skipped." >"$run_dir/Balagan.sqlite.unavailable.txt"
    printf '%s\n' "$db"
    return 0
  fi

  local q_fixture
  local q_fixture_file
  local q_freeze_time
  q_fixture="$(sql_quote "$fixture")"
  q_fixture_file="$(sql_quote "$fixture_file")"
  q_freeze_time="$(sql_quote "$BALAGAN_FREEZE_TIME")"

  sqlite3 "$db" >/dev/null <<SQL
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS harness_metadata (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);
DELETE FROM harness_metadata;
INSERT INTO harness_metadata(key, value) VALUES
  ('fixture_name', $q_fixture),
  ('fixture_path', $q_fixture_file),
  ('freeze_time', $q_freeze_time),
  ('real_processes_disabled', '1');
SQL

  printf '%s\n' "$db"
}

write_run_contract() {
  local command="$1"
  local fixture="$2"
  local fixture_file="$3"
  local db="$4"
  local run_dir="$5"

  cp "$fixture_file" "$run_dir/fixture.json"

  cat >"$run_dir/launch.env" <<EOF
BALAGAN_DISABLE_REAL_PROCESSES=1
BALAGAN_FAKE_TERMINAL_OUTPUT=$fixture
BALAGAN_FIXTURE_PATH=$fixture_file
BALAGAN_SQLITE_PATH=$db
BALAGAN_STATE_PATH=$run_dir/Balagan.state.json
BALAGAN_UI_TEST_ARTIFACT_DIR=$run_dir
BALAGAN_FREEZE_TIME=$BALAGAN_FREEZE_TIME
EOF

  cat >"$run_dir/launch-args.txt" <<EOF
--ui-test-mode
--fixture
$fixture
--fixture-path
$fixture_file
--database
$db
--state-path
$run_dir/Balagan.state.json
--artifact-dir
$run_dir
EOF

  printf '%s\n' "App logs will be captured here when the app target exists." >"$run_dir/app.log"
  printf '%s\n' "Accessibility tree dumps will be captured here when XCUITest exists." >"$run_dir/accessibility-tree.txt"

  cat >"$run_dir/README.txt" <<EOF
Balagan $command artifacts

Fixture: $fixture
Fixture JSON: $fixture_file
SQLite fixture database: $db
Artifacts: $run_dir

Real process launch is disabled for this run.
EOF
}

write_first_run_contract() {
  local db="$1"
  local run_dir="$2"

  cat >"$run_dir/launch.env" <<EOF
BALAGAN_DISABLE_REAL_PROCESSES=1
BALAGAN_SQLITE_PATH=$db
BALAGAN_UI_TEST_ARTIFACT_DIR=$run_dir
BALAGAN_FREEZE_TIME=$BALAGAN_FREEZE_TIME
EOF

  cat >"$run_dir/launch-args.txt" <<EOF
--database
$db
--artifact-dir
$run_dir
EOF

  printf '%s\n' "App logs are captured here." >"$run_dir/app.log"
  printf '%s\n' "Accessibility tree dumps are captured here." >"$run_dir/accessibility-tree.txt"

  cat >"$run_dir/README.txt" <<EOF
Balagan first-run-smoke artifacts

SQLite database: $db
Artifacts: $run_dir

This run launches normal app mode with a fresh SQLite database, no fixture input,
no JSON state path, and real process launch disabled.
EOF
}

discover_app() {
  if [[ -n "${BALAGAN_APP_PATH:-}" ]]; then
    [[ -d "$BALAGAN_APP_PATH" ]] || die "BALAGAN_APP_PATH does not exist or is not an app bundle: $BALAGAN_APP_PATH"
    printf '%s\n' "$BALAGAN_APP_PATH"
    return 0
  fi

  first_match "build/$BALAGAN_BUILD_CONFIGURATION/$BALAGAN_SCHEME.app" && return 0
  first_match ".build/$BALAGAN_BUILD_CONFIGURATION/$BALAGAN_SCHEME.app" && return 0

  return 1
}

discover_swiftpm_executable() {
  if [[ -n "${BALAGAN_EXECUTABLE_PATH:-}" ]]; then
    [[ -x "$BALAGAN_EXECUTABLE_PATH" ]] || die "BALAGAN_EXECUTABLE_PATH does not exist or is not executable: $BALAGAN_EXECUTABLE_PATH"
    printf '%s\n' "$BALAGAN_EXECUTABLE_PATH"
    return 0
  fi

  first_match ".build/*/$SWIFT_BUILD_CONFIGURATION/BalaganApp" && return 0
  first_match ".build/$SWIFT_BUILD_CONFIGURATION/BalaganApp" && return 0

  return 1
}

discover_swiftpm_ui_driver() {
  if [[ -n "${BALAGAN_UI_DRIVER_PATH:-}" ]]; then
    [[ -x "$BALAGAN_UI_DRIVER_PATH" ]] || die "BALAGAN_UI_DRIVER_PATH does not exist or is not executable: $BALAGAN_UI_DRIVER_PATH"
    printf '%s\n' "$BALAGAN_UI_DRIVER_PATH"
    return 0
  fi

  first_match ".build/*/$SWIFT_BUILD_CONFIGURATION/BalaganUIDriver" && return 0
  first_match ".build/$SWIFT_BUILD_CONFIGURATION/BalaganUIDriver" && return 0

  return 1
}

discover_swiftpm_agent_wrapper() {
  if [[ -n "${BALAGAN_AGENT_WRAPPER_PATH:-}" ]]; then
    [[ -x "$BALAGAN_AGENT_WRAPPER_PATH" ]] || die "BALAGAN_AGENT_WRAPPER_PATH does not exist or is not executable: $BALAGAN_AGENT_WRAPPER_PATH"
    printf '%s\n' "$BALAGAN_AGENT_WRAPPER_PATH"
    return 0
  fi

  first_match ".build/*/$SWIFT_BUILD_CONFIGURATION/balagan-agent" && return 0
  first_match ".build/$SWIFT_BUILD_CONFIGURATION/balagan-agent" && return 0

  return 1
}

stage_swiftpm_app_bundle() {
  local executable="$1"
  local run_dir="$2"
  local bundle="$run_dir/BalaganApp.app"
  local macos_dir="$bundle/Contents/MacOS"

  mkdir -p "$macos_dir"
  cp "$executable" "$macos_dir/BalaganApp"

  cat >"$bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>BalaganApp</string>
  <key>CFBundleIdentifier</key>
  <string>local.balagan.debug</string>
  <key>CFBundleName</key>
  <string>Balagan</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
EOF

  printf '%s\n' "$bundle"
}

wait_for_file() {
  local path="$1"
  local timeout_seconds="${2:-10}"
  local waited=0

  while [[ "$waited" -lt "$timeout_seconds" ]]; do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

wait_for_file_contains() {
  local path="$1"
  local expected="$2"
  local timeout_seconds="${3:-10}"
  local waited=0

  while [[ "$waited" -lt "$timeout_seconds" ]]; do
    if [[ -f "$path" ]] && grep -F "$expected" "$path" >/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  [[ -f "$path" ]] || die "expected file missing: $path"
  grep -F "$expected" "$path" >/dev/null || die "expected '$expected' in $path"
}

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"

  [[ -f "$path" ]] || die "expected file missing: $path"
  if grep -F "$unexpected" "$path" >/dev/null; then
    die "did not expect '$unexpected' in $path"
  fi
}

assert_json_ui_scale() {
  local path="$1"
  local expected="${2:-1}"

  [[ -f "$path" ]] || die "expected file missing: $path"
  python3 - "$path" "$expected" <<'PY' || die "expected uiScale $expected in $path"
import json
import math
import sys

path = sys.argv[1]
expected = float(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
actual = float(payload["uiAppearance"]["uiScale"])
if not math.isclose(actual, expected, rel_tol=0, abs_tol=0.0001):
    raise SystemExit(f"actual uiScale {actual} != expected {expected}")
PY
}

assert_ui_artifacts() {
  local run_dir="$1"
  local fixture="$2"

  assert_file_contains "$run_dir/accessibility-tree.txt" "Balagan"
  assert_file_contains "$run_dir/accessibility-tree.txt" "kanban-board"
  assert_file_contains "$run_dir/accessibility-tree.txt" "task-detail"
  assert_file_contains "$run_dir/accessibility-tree.txt" "settings-button"
  assert_file_contains "$run_dir/app-ready.json" "\"storage\""
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\""
  assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"fixture\""
  assert_file_contains "$run_dir/app-ready.json" "\"uiAppearance\""
  assert_json_ui_scale "$run_dir/app-ready.json" "${BALAGAN_INITIAL_UI_SCALE:-1}"

  if [[ "$fixture" != "empty-board" ]]; then
    assert_file_contains "$run_dir/accessibility-tree.txt" "task-card-"
    assert_file_contains "$run_dir/accessibility-tree.txt" "terminal-pane-"
  fi

  if [[ "$fixture" == "resumable-task" ]]; then
    assert_file_contains "$run_dir/accessibility-tree.txt" "resume-button-surface-codex-resume"
    assert_file_contains "$run_dir/resume-request.json" "codex resume codex-session-ui-fixture-001"
  fi

  [[ -f "$run_dir/screenshots/board-app.png" ]] || die "app-native screenshot missing: $run_dir/screenshots/board-app.png"
}

assert_database_snapshot() {
  local run_dir="$1"
  local db="$2"
  local fixture="$3"

  [[ -f "$db" ]] || die "app did not create SQLite database: $db"

  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf '%s\n' "sqlite3 is unavailable; database row validation skipped." >"$run_dir/Balagan.sqlite.validation-skipped.txt"
    return 0
  fi

  local row_count
  row_count="$(sqlite3 "$db" "SELECT count(*) FROM board_snapshots WHERE id = 'current' AND schema_version = 1;")"
  [[ "$row_count" == "1" ]] || die "expected current schema-versioned snapshot in $db"

  local payload="$run_dir/database-snapshot.json"
  sqlite3 "$db" "SELECT payload_json FROM board_snapshots WHERE id = 'current';" >"$payload"
  [[ -s "$payload" ]] || die "database snapshot payload was empty: $payload"
  assert_file_contains "$payload" "\"schemaVersion\" : 1"

  if [[ "$fixture" != "empty-board" ]]; then
    assert_file_contains "$payload" "\"tasks\""
    assert_file_contains "$payload" "\"workspaces\""
  fi
}

assert_ui_flow_controls() {
  local run_dir="$1"
  local contract_file="$ROOT/scripts/balagan-ui-control-contract.txt"
  local artifact="$run_dir/ui-controls.json"
  local source="$run_dir/accessibility-tree.txt"
  local identifier

  [[ -f "$contract_file" ]] || die "UI control contract missing: $contract_file"

  if [[ -f "$artifact" ]]; then
    source="$artifact"
    validate_json_file "$artifact"
  fi

  while IFS= read -r identifier; do
    [[ -n "$identifier" ]] || continue
    [[ "$identifier" == \#* ]] && continue
    assert_file_contains "$source" "$identifier"
  done <"$contract_file"
}

assert_contract_strings_in_file() {
  local contract_file="$1"
  local source="$2"
  local context="$3"
  local expected

  [[ -f "$contract_file" ]] || die "$context contract missing: $contract_file"
  [[ -f "$source" ]] || die "$context source missing: $source"

  while IFS= read -r expected; do
    [[ -n "$expected" ]] || continue
    [[ "$expected" == \#* ]] && continue
    assert_file_contains "$source" "$expected"
  done <"$contract_file"
}

assert_ui_flow_smoke_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-flow-smoke.json"
  local contract_file="$ROOT/scripts/balagan-ui-flow-smoke-contract.txt"

  [[ -f "$artifact" ]] || die "expected scripted UI flow artifact missing: $artifact. The app should write this after --run-ui-flow-smoke / BALAGAN_RUN_UI_FLOW_SMOKE=1; see $contract_file"
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "\"schemaVersion\""
  assert_file_contains "$artifact" "create-edit-status-tab"
  assert_contract_strings_in_file "$contract_file" "$artifact" "scripted UI flow artifact"
}

assert_ui_flow_restored_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-flow-observed-state.json"
  local contract_file="$ROOT/scripts/balagan-ui-flow-smoke-contract.txt"

  [[ -f "$artifact" ]] || die "expected restored UI flow observation missing: $artifact. On SQLite restore, the app should write ui-flow-observed-state.json so the harness can prove the scripted flow came from persisted state; see $contract_file"
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "\"dataSource\""
  assert_contract_strings_in_file "$contract_file" "$artifact" "restored UI flow observation"
}

assert_ui_native_flow_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-native-flow-driver.json"
  local contract_file="$ROOT/scripts/balagan-ui-flow-smoke-contract.txt"

  [[ -f "$artifact" ]] || die "expected native UI driver artifact missing: $artifact. If ui-native-flow-driver-error.txt exists, it contains the macOS Accessibility failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-create-edit-status-tab"
  assert_contract_strings_in_file "$contract_file" "$artifact" "native UI driver artifact"
}

assert_ui_daily_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-daily-driver.json"

  [[ -f "$artifact" ]] || die "expected daily native UI driver artifact missing: $artifact. If ui-daily-driver-error.txt exists, it contains the macOS Accessibility or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-daily-driver"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "\"statusMoveMethod\" : \"drag-drop\""
  assert_file_contains "$artifact" "\"onlyTerminalTabResult\" : \"empty-workspace-or-replacement-state\""
  assert_file_contains "$artifact" "\"contextMenuEdit\" : \"completed\""
  assert_file_contains "$artifact" "\"contextMenuDelete\" : \"completed\""
  assert_file_contains "$artifact" "\"projectFullRowClick\" : \"completed\""
  assert_file_contains "$artifact" "\"projectContextMenuEdit\" : \"completed\""
  assert_file_contains "$artifact" "\"projectDeleteConfirmationRequired\" : \"completed\""
  assert_file_contains "$artifact" "\"projectContextMenuDelete\" : \"completed\""
}

assert_terminal_input_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-input-driver.json"
  local typed_output="$run_dir/terminal-input-typed.txt"
  local output="$run_dir/terminal-input-output.txt"
  local before_switch_output="$run_dir/terminal-input-before-switch.txt"
  local after_switch_output="$run_dir/terminal-input-after-switch.txt"
  local second_tab_output="$run_dir/terminal-input-second-tab.txt"

  [[ -f "$artifact" ]] || die "expected terminal input native UI driver artifact missing: $artifact. If ui-terminal-input-driver-error.txt exists, it contains the macOS Accessibility or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-input"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "BALAGAN_TYPED_INPUT_OK"
  assert_file_contains "$artifact" "BALAGAN_TERMINAL_INPUT_OK"
  assert_file_contains "$artifact" "BALAGAN_FIRST_TAB_BEFORE_SWITCH_OK"
  assert_file_contains "$artifact" "BALAGAN_FIRST_TAB_AFTER_SWITCH_OK"
  assert_file_contains "$artifact" "BALAGAN_SECOND_TAB_OK"

  [[ -f "$typed_output" ]] || die "expected typed terminal marker file missing: $typed_output"
  assert_file_contains "$typed_output" "BALAGAN_TYPED_INPUT_OK"
  [[ -f "$before_switch_output" ]] || die "expected first terminal tab before-switch marker file missing: $before_switch_output"
  assert_file_contains "$before_switch_output" "BALAGAN_FIRST_TAB_BEFORE_SWITCH_OK"
  [[ -f "$after_switch_output" ]] || die "expected first terminal tab after-switch marker file missing: $after_switch_output"
  assert_file_contains "$after_switch_output" "BALAGAN_FIRST_TAB_AFTER_SWITCH_OK"
  [[ -f "$second_tab_output" ]] || die "expected second terminal tab marker file missing: $second_tab_output"
  assert_file_contains "$second_tab_output" "BALAGAN_SECOND_TAB_OK"
  [[ -f "$output" ]] || die "expected terminal input marker file missing: $output"
  assert_file_contains "$output" "BALAGAN_TERMINAL_INPUT_OK"
}

assert_terminal_manual_input_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-manual-input-driver.json"
  local marker

  [[ -f "$artifact" ]] || die "expected terminal manual input native UI driver artifact missing: $artifact. If ui-terminal-manual-input-driver-error.txt exists, it contains the macOS Accessibility or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-manual-input"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "physical-key-events"

  for marker in openMarkerPath secondTabMarkerPath switchedBackMarkerPath navigationMarkerPath; do
    local path
    path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$artifact" "$marker")"
    case "$path" in
      "$run_dir"/*) ;;
      *) die "expected manually typed terminal marker path for $marker to be under artifact directory $run_dir: $path" ;;
    esac
    [[ -f "$path" ]] || die "expected manually typed terminal marker file missing for $marker: $path"
  done
}

assert_terminal_visible_typing_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-visible-typing-driver.json"
  local first_visible="$run_dir/libghostty-terminal-visible-text-surface-harness-task-main.txt"
  local second_visible="$run_dir/libghostty-terminal-visible-text-tab-2.txt"

  [[ -f "$artifact" ]] || die "expected terminal visible typing native UI driver artifact missing: $artifact. If ui-terminal-visible-typing-driver-error.txt exists, it contains the macOS Accessibility, visible-text, or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-visible-typing"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "physical-key-events"
  assert_file_contains "$artifact" "renderFreshnessEvidence"

  [[ -f "$first_visible" ]] || die "expected first terminal visible text artifact missing: $first_visible"
  [[ -f "$second_visible" ]] || die "expected second terminal visible text artifact missing: $second_visible"

  local open_token
  local second_token
  local switched_back_token
  local navigation_token
  open_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["openVisibleToken"])' "$artifact")"
  second_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["secondTabVisibleToken"])' "$artifact")"
  switched_back_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["switchedBackVisibleToken"])' "$artifact")"
  navigation_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["navigationVisibleToken"])' "$artifact")"

  assert_file_contains "$first_visible" "$open_token"
  assert_file_contains "$second_visible" "$second_token"
  assert_file_contains "$first_visible" "$switched_back_token"
  assert_file_contains "$first_visible" "$navigation_token"

  python3 - "$artifact" "$run_dir" <<'PY'
import json
import os
import sys

artifact_path, run_dir = sys.argv[1], sys.argv[2]
with open(artifact_path, encoding="utf-8") as handle:
    payload = json.load(handle)

evidence = payload.get("renderFreshnessEvidence")
if not isinstance(evidence, list) or len(evidence) < 4:
    raise SystemExit("expected at least four renderFreshnessEvidence entries")

for entry in evidence:
    name = entry.get("name", "<unnamed>")
    changed = int(entry.get("changedPixels", 0))
    minimum = int(entry.get("minimumChangedPixels", 0))
    if changed < minimum:
        raise SystemExit(f"render evidence {name} changed {changed} pixels, expected at least {minimum}")
    for key in ("beforeScreenshotPath", "afterScreenshotPath"):
        path = entry.get(key)
        if not isinstance(path, str) or not path.startswith(run_dir + "/"):
            raise SystemExit(f"render evidence {name} has invalid {key}: {path}")
        if not os.path.exists(path):
            raise SystemExit(f"render evidence {name} missing {key}: {path}")
PY
}

assert_terminal_keyboard_shortcuts_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-keyboard-shortcuts-driver.json"
  local first_visible="$run_dir/libghostty-terminal-visible-text-surface-harness-task-main.txt"
  local second_visible="$run_dir/libghostty-terminal-visible-text-tab-2.txt"
  local third_visible="$run_dir/libghostty-terminal-visible-text-tab-4.txt"
  local remaining_split_visible="$run_dir/libghostty-terminal-visible-text-down-6.txt"

  [[ -f "$artifact" ]] || die "expected terminal keyboard shortcuts native UI driver artifact missing: $artifact. If ui-terminal-keyboard-shortcuts-driver-error.txt exists, it contains the macOS Accessibility, visible-text, or shortcut failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-keyboard-shortcuts"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "tabSwitchShortcuts"
  assert_file_contains "$artifact" "splitFocusShortcuts"
  assert_file_contains "$artifact" "zoomShortcut"
  assert_file_contains "$artifact" "fontZoomShortcuts"
  assert_file_contains "$artifact" "fontZoomEvidence"
  assert_file_contains "$artifact" "newTerminalInheritedFontSize"
  assert_file_contains "$artifact" "persistedFontSizeAfterFlow"
  assert_file_contains "$artifact" "copyPasteClearShortcuts"
  assert_file_contains "$artifact" "renderFreshnessEvidence"
  assert_file_contains "$run_dir/ui-terminal-keyboard-shortcuts-accessibility-final.txt" "identifier=terminal-tab-picker"
  assert_file_contains "$run_dir/ui-terminal-keyboard-shortcuts-accessibility-final.txt" "description=tab 4"
  assert_file_not_contains "$run_dir/ui-terminal-keyboard-shortcuts-accessibility-final.txt" "description=right 5"
  assert_file_not_contains "$run_dir/ui-terminal-keyboard-shortcuts-accessibility-final.txt" "description=down 6"

  [[ -f "$first_visible" ]] || die "expected first terminal visible text artifact missing: $first_visible"
  [[ -f "$second_visible" ]] || die "expected second terminal visible text artifact missing: $second_visible"
  [[ -f "$third_visible" ]] || die "expected third terminal visible text artifact missing: $third_visible"
  [[ -f "$remaining_split_visible" ]] || die "expected remaining split visible text artifact missing: $remaining_split_visible"

  local first_token
  local second_token
  local third_token
  local after_navigation_token
  first_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["firstVisibleToken"])' "$artifact")"
  second_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["secondVisibleToken"])' "$artifact")"
  third_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["thirdVisibleToken"])' "$artifact")"
  after_navigation_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["afterNavigationVisibleToken"])' "$artifact")"

  assert_file_contains "$first_visible" "$first_token"
  assert_file_contains "$remaining_split_visible" "$after_navigation_token"
  assert_file_contains "$second_visible" "$second_token"
  assert_file_contains "$third_visible" "$third_token"

  python3 - "$artifact" "$run_dir" <<'PY'
import json
import os
import sys

artifact_path, run_dir = sys.argv[1], sys.argv[2]
with open(artifact_path, encoding="utf-8") as handle:
    payload = json.load(handle)

evidence = payload.get("renderFreshnessEvidence")
if not isinstance(evidence, list) or len(evidence) < 4:
    raise SystemExit("expected at least four renderFreshnessEvidence entries")

for entry in evidence:
    changed = int(entry.get("changedPixels", 0))
    minimum = int(entry.get("minimumChangedPixels", 0))
    if changed < minimum:
        raise SystemExit(f"render evidence changed {changed} pixels, expected at least {minimum}")
    for key in ("beforeScreenshotPath", "afterScreenshotPath"):
        path = entry.get(key)
        if not isinstance(path, str) or not path.startswith(run_dir + "/"):
            raise SystemExit(f"render evidence has invalid {key}: {path}")
        if not os.path.exists(path):
            raise SystemExit(f"render evidence missing {key}: {path}")

font_zoom = payload.get("fontZoomEvidence")
if not isinstance(font_zoom, list) or len(font_zoom) != 5:
    raise SystemExit("expected five fontZoomEvidence entries")

if payload.get("newTerminalInheritedFontSize") != 14:
    raise SystemExit("expected new terminal to inherit font size 14")
if payload.get("persistedFontSizeAfterFlow") != 14:
    raise SystemExit("expected terminal font size 14 after flow")

for entry in font_zoom:
    name = entry.get("evidenceName", "<unnamed>")
    if not entry.get("handled"):
        raise SystemExit(f"font zoom evidence {name} was not handled")
    changed = int(entry.get("changedPixels", 0))
    minimum = int(entry.get("minimumChangedPixels", 0))
    if changed < minimum:
        raise SystemExit(f"font zoom evidence {name} changed {changed} pixels, expected at least {minimum}")
    changed_surfaces = entry.get("changedSurfaceIDs")
    if not isinstance(changed_surfaces, list) or "surface-harness-task-main" not in changed_surfaces:
        raise SystemExit(f"font zoom evidence {name} missing changed surface IDs")
    for key in ("beforeScreenshotPath", "afterScreenshotPath"):
        path = entry.get(key)
        if not isinstance(path, str) or not path.startswith(run_dir + "/"):
            raise SystemExit(f"font zoom evidence {name} has invalid {key}: {path}")
        if not os.path.exists(path):
            raise SystemExit(f"font zoom evidence {name} missing {key}: {path}")
PY
}

assert_terminal_navigation_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-navigation-driver.json"
  local before_navigation_output="$run_dir/terminal-navigation-before.txt"
  local after_navigation_output="$run_dir/terminal-navigation-after.txt"

  [[ -f "$artifact" ]] || die "expected terminal navigation native UI driver artifact missing: $artifact. If ui-terminal-navigation-driver-error.txt exists, it contains the macOS Accessibility or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-navigation-persistence"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "BALAGAN_NAVIGATION_BEFORE_OK"
  assert_file_contains "$artifact" "BALAGAN_NAVIGATION_STATE_OK"

  [[ -f "$before_navigation_output" ]] || die "expected terminal before-navigation marker file missing: $before_navigation_output"
  assert_file_contains "$before_navigation_output" "BALAGAN_NAVIGATION_BEFORE_OK"
  [[ -f "$after_navigation_output" ]] || die "expected terminal after-navigation state marker file missing: $after_navigation_output"
  assert_file_contains "$after_navigation_output" "BALAGAN_NAVIGATION_STATE_OK"
}

assert_terminal_restart_resume_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-restart-resume-driver.json"
  local resume_request="$run_dir/resume-request.json"

  [[ -f "$artifact" ]] || die "expected terminal restart/resume native UI driver artifact missing: $artifact. If ui-terminal-restart-resume-driver-error.txt exists, it contains the macOS Accessibility or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-restart-resume"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "\"initialSelectedSurfaceId\" : \"surface-codex-resume\""
  assert_file_contains "$artifact" "\"confirmedSurfaceId\" : \"surface-tmux-review\""
  assert_file_contains "$artifact" "\"confirmedResumeCommand\" : \"tmux attach -t task_task-resume-codex\""

  [[ -f "$resume_request" ]] || die "expected confirmed resume request artifact missing: $resume_request"
  validate_json_file "$resume_request"
  assert_file_contains "$resume_request" "\"surfaceID\" : \"surface-tmux-review\""
  assert_file_contains "$resume_request" "\"displayCommand\" : \"tmux attach -t task_task-resume-codex\""
}

assert_terminal_reload_prompt_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-reload-prompt-driver.json"
  local visible_text="$run_dir/libghostty-terminal-visible-text-surface-reload-prompt.txt"
  local resume_request="$run_dir/resume-request.json"

  [[ -f "$artifact" ]] || die "expected terminal reload prompt native UI driver artifact missing: $artifact. If ui-terminal-reload-prompt-driver-error.txt exists, it contains the macOS Accessibility, visible-text, or missing-control failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-reload-prompt"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "FAKE_CODEX_ARGS:resume:s018"

  [[ -f "$visible_text" ]] || die "expected reload prompt visible text artifact missing: $visible_text"
  assert_file_contains "$visible_text" "FAKE_CODEX_ARGS:resume:s018"
  assert_file_not_contains "$visible_text" "$ s018"
  assert_file_not_contains "$visible_text" "% s018"
  assert_file_not_contains "$visible_text" "> s018"

  [[ -f "$resume_request" ]] || die "expected reload prompt auto-resume request artifact missing: $resume_request"
  validate_json_file "$resume_request"
  assert_file_contains "$resume_request" "\"surfaceID\" : \"surface-reload-prompt\""
  assert_file_contains "$resume_request" "\"displayCommand\" : \"codex resume s018\""
}

assert_terminal_close_open_prompt_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-close-open-prompt-driver.json"
  local visible_text="$run_dir/libghostty-terminal-visible-text-tab-1.txt"

  [[ -f "$artifact" ]] || die "expected terminal close/open prompt native UI driver artifact missing: $artifact. If ui-terminal-close-open-prompt-driver-error.txt exists, it contains the macOS Accessibility, visible-text, shell, or prompt failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-close-open-prompt"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "\"typedCommand\" : \"ls\""
  assert_file_contains "$artifact" "\"reopenedSurfaceId\" : \"tab-1\""
  assert_file_contains "$artifact" "\"observedShell\""

  [[ -f "$visible_text" ]] || die "expected close/open prompt visible text artifact missing: $visible_text"
  assert_file_contains "$visible_text" "__BALAGAN_SHELL__"
  assert_file_not_contains "$visible_text" "$ s001"
  assert_file_not_contains "$visible_text" "$ s002"
  assert_file_not_contains "$visible_text" "$ s003"
  assert_file_not_contains "$visible_text" "% s001"
  assert_file_not_contains "$visible_text" "% s002"
  assert_file_not_contains "$visible_text" "% s003"
  assert_file_not_contains "$visible_text" "> s001"
  assert_file_not_contains "$visible_text" "> s002"
  assert_file_not_contains "$visible_text" "> s003"
}

assert_terminal_ended_autoclose_driver_artifact() {
  local run_dir="$1"
  local artifact="$run_dir/ui-terminal-ended-autoclose-driver.json"
  local autoclose_artifact="$run_dir/libghostty-terminal-ended-process-autoclose-surface-ended-autoclose.json"
  local visible_text="$run_dir/libghostty-terminal-visible-text-surface-ended-autoclose.txt"

  [[ -f "$artifact" ]] || die "expected terminal ended-process auto-close native UI driver artifact missing: $artifact. If ui-terminal-ended-autoclose-driver-error.txt exists, it contains the macOS Accessibility, visible-text, or auto-close failure."
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "native-accessibility-terminal-ended-autoclose"
  assert_file_contains "$artifact" "\"status\" : \"completed\""
  assert_file_contains "$artifact" "\"closedSurfaceId\" : \"surface-ended-autoclose\""
  assert_file_contains "$artifact" "\"workspaceState\" : \"empty\""

  [[ -f "$autoclose_artifact" ]] || die "expected ended-process auto-close artifact missing: $autoclose_artifact"
  validate_json_file "$autoclose_artifact"
  assert_file_contains "$autoclose_artifact" "\"status\" : \"auto-closed\""
  assert_file_contains "$autoclose_artifact" "\"reason\" : \"ended-process-prompt\""

  assert_file_contains "$run_dir/ui-terminal-ended-autoclose-accessibility-final.txt" "empty-terminal-workspace"
  assert_file_not_contains "$run_dir/ui-terminal-ended-autoclose-accessibility-final.txt" "terminal-pane-surface-ended-autoclose"

  if [[ -f "$visible_text" ]]; then
    assert_file_not_contains "$visible_text" "press any key"
    assert_file_not_contains "$visible_text" "Press any key"
    assert_file_not_contains "$visible_text" "close terminal"
    assert_file_not_contains "$visible_text" "close the terminal"
    assert_file_not_contains "$visible_text" "close window"
    assert_file_not_contains "$visible_text" "close the window"
  fi

  if grep -Riq "press any key" "$run_dir"; then
    die "ended-process prompt text leaked into artifacts under $run_dir"
  fi
}

assert_restart_resume_restore_artifacts() {
  local run_dir="$1"
  local auto_request="$run_dir/auto-resume-request.json"

  assert_file_contains "$run_dir/app-ready.json" "\"dataSource\" : \"sqlite\""
  assert_file_contains "$run_dir/app-ready.json" "\"selectedWorkspaceId\" : \"workspace-resume-codex\""
  assert_file_contains "$run_dir/app-ready.json" "\"selectedSurfaceId\" : \"surface-codex-resume\""
  assert_file_contains "$run_dir/accessibility-tree.txt" "selected-workspace-workspace-resume-codex"
  assert_file_contains "$run_dir/accessibility-tree.txt" "selected-surface-surface-codex-resume"
  assert_file_contains "$run_dir/accessibility-tree.txt" "terminal-pane-surface-codex-resume"
  assert_file_contains "$run_dir/accessibility-tree.txt" "terminal-pane-surface-tmux-review"
  assert_file_contains "$run_dir/accessibility-tree.txt" "resume-button-surface-tmux-review"

  [[ -f "$auto_request" ]] || die "expected trusted auto-resume request copy missing: $auto_request"
  validate_json_file "$auto_request"
  assert_file_contains "$auto_request" "\"surfaceID\" : \"surface-codex-resume\""
  assert_file_contains "$auto_request" "\"displayCommand\" : \"codex resume codex-session-ui-fixture-001\""
  assert_file_not_contains "$auto_request" "tmux attach -t task_task-resume-codex"
}

assert_native_ui_flow_database_snapshot() {
  local source="$1"
  local context="$2"

  assert_file_contains "$source" "Harness Project Edited"
  assert_file_contains "$source" "Harness Task Edited"
  assert_file_contains "$source" "\"status\" : \"doing\""
  assert_file_contains "$source" "Harness Tab Renamed"
  assert_file_not_contains "$source" "Harness Delete Tab"
}

assert_ui_flow_database_snapshot() {
  local source="$1"
  local context="$2"

  assert_file_contains "$source" "Harness Project Edited"
  assert_file_contains "$source" "Harness Task Edited"
  assert_file_contains "$source" "\"status\" : \"doing\""
  assert_file_contains "$source" "Harness Tab Renamed"
  assert_file_not_contains "$source" "Harness Delete Tab"
}

assert_daily_driver_database_snapshot() {
  local source="$1"
  local context="$2"

  assert_file_contains "$source" "Harness Other Project"
  assert_file_not_contains "$source" "Harness Project"
  assert_file_not_contains "$source" "Harness Daily Context Task Edited"
  assert_file_not_contains "$source" "Harness Task"
}

assert_terminal_state_capture_artifact() {
  local run_dir="$1"
  local phase="$2"
  local artifact="$run_dir/terminal-state-capture.json"
  local contract_file="$ROOT/scripts/balagan-terminal-state-smoke-contract.txt"

  [[ -f "$artifact" ]] || die "expected terminal state capture artifact missing: $artifact. The app should write this after --capture-terminal-state / BALAGAN_CAPTURE_TERMINAL_STATE=1; see $contract_file"
  validate_json_file "$artifact"
  assert_file_contains "$artifact" "\"phase\" : \"$phase\""
  if [[ "$phase" == "captured" ]]; then
    assert_file_contains "$artifact" "\"exitStatus\" : 0"
  fi
  assert_contract_strings_in_file "$contract_file" "$artifact" "terminal state capture artifact"
}

assert_first_run_artifacts() {
  local run_dir="$1"
  local db="$2"

  assert_file_contains "$run_dir/app-ready.json" "\"uiTestMode\" : false"
  assert_file_contains "$run_dir/app-ready.json" "\"disableRealProcesses\" : true"
  assert_file_contains "$run_dir/app-ready.json" "\"dataSource\" : \"empty\""
  assert_file_contains "$run_dir/app-ready.json" "\"projects\" : 0"
  assert_file_contains "$run_dir/app-ready.json" "\"tasks\" : 0"
  assert_file_contains "$run_dir/accessibility-tree.txt" "Balagan"
  assert_file_contains "$run_dir/accessibility-tree.txt" "kanban-board"
  assert_file_not_contains "$run_dir/accessibility-tree.txt" "task-card-"
  assert_database_snapshot "$run_dir" "$db" "empty-board"
}

capture_screenshot() {
  local run_dir="$1"
  local name="$2"
  local path="$run_dir/screenshots/$name.png"

  if [[ "${BALAGAN_CAPTURE_SCREENSHOTS:-1}" == "0" ]]; then
    printf '%s\n' "screenshot capture disabled by BALAGAN_CAPTURE_SCREENSHOTS=0" >"$run_dir/screenshots/$name.unavailable.txt"
    return 0
  fi

  if ! command -v screencapture >/dev/null 2>&1; then
    printf '%s\n' "screencapture is unavailable on this machine" >"$run_dir/screenshots/$name.unavailable.txt"
    return 0
  fi

  if screencapture -x "$path" >/dev/null 2>"$run_dir/screenshots/$name.stderr"; then
    log "captured screenshot: $path"
  else
    printf '%s\n' "screencapture failed; see $name.stderr" >"$run_dir/screenshots/$name.unavailable.txt"
  fi
}

run_swiftpm_ui_smoke() {
  local fixture="$1"
  local fixture_file="$2"
  local db="$3"
  local run_dir="$4"

  if ! run_build; then
    log "build failed; UI smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"
  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=1
  export BALAGAN_FREEZE_TIME

  log "running SwiftPM UI smoke with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "app did not write app-ready.json; see $run_dir/app.log"
  fi

  if [[ "$fixture" == "resumable-task" ]] && ! wait_for_file "$run_dir/resume-request.json" 5; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "resumable fixture did not write resume-request.json; see $run_dir/app.log"
  fi

  assert_ui_artifacts "$run_dir" "$fixture"
  assert_database_snapshot "$run_dir" "$db" "$fixture"

  sleep 1
  capture_screenshot "$run_dir" "board"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true

  local state_path="$run_dir/Balagan.state.json"
  [[ -f "$state_path" ]] || die "app did not write durable state snapshot: $state_path"

  local restore_dir="$run_dir/restore"
  mkdir -p "$restore_dir/screenshots"
  log "running SwiftPM restore smoke from $state_path"
  env -u BALAGAN_FIXTURE_PATH "$executable" \
    --ui-test-mode \
    --fixture restored-from-state \
    --state-path "$state_path" \
    --artifact-dir "$restore_dir" \
    >"$restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$restore_dir/app.pid"

  if ! wait_for_file "$restore_dir/app-ready.json" 10; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "restore launch did not write app-ready.json; see $restore_dir/app.log"
  fi

  if [[ "$fixture" == "resumable-task" ]] && ! wait_for_file "$restore_dir/resume-request.json" 5; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "restore resumable fixture did not write resume-request.json; see $restore_dir/app.log"
  fi

  assert_ui_artifacts "$restore_dir" "$fixture"

  sleep 1
  capture_screenshot "$restore_dir" "board"

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"
  log "running SwiftPM restore smoke from SQLite database $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH "$executable" \
    --ui-test-mode \
    --fixture restored-from-database \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local database_restore_pid="$!"
  printf '%s\n' "$database_restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$database_restore_pid" >/dev/null 2>&1 || true
    wait "$database_restore_pid" >/dev/null 2>&1 || true
    die "database restore launch did not write app-ready.json; see $database_restore_dir/app.log"
  fi

  if [[ "$fixture" == "resumable-task" ]] && ! wait_for_file "$database_restore_dir/resume-request.json" 5; then
    kill "$database_restore_pid" >/dev/null 2>&1 || true
    wait "$database_restore_pid" >/dev/null 2>&1 || true
    die "database restore resumable fixture did not write resume-request.json; see $database_restore_dir/app.log"
  fi

  assert_ui_artifacts "$database_restore_dir" "$fixture"
  assert_database_snapshot "$database_restore_dir" "$db" "$fixture"

  sleep 1
  capture_screenshot "$database_restore_dir" "board"

  kill "$database_restore_pid" >/dev/null 2>&1 || true
  wait "$database_restore_pid" >/dev/null 2>&1 || true

  log "UI smoke artifacts: $run_dir"
}

run_build() {
  local workspace=""
  local project=""

  workspace="$(xcode_workspace || true)"
  project="$(xcode_project || true)"

  if [[ -n "$workspace" || -n "$project" ]]; then
    command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required for the discovered Xcode target"
    if [[ -n "$workspace" ]]; then
      log "building Xcode workspace $workspace with scheme $BALAGAN_SCHEME"
      xcodebuild -workspace "$workspace" -scheme "$BALAGAN_SCHEME" -destination "$BALAGAN_DESTINATION" -configuration "$BALAGAN_BUILD_CONFIGURATION" build
      return $?
    else
      log "building Xcode project $project with scheme $BALAGAN_SCHEME"
      xcodebuild -project "$project" -scheme "$BALAGAN_SCHEME" -destination "$BALAGAN_DESTINATION" -configuration "$BALAGAN_BUILD_CONFIGURATION" build
      return $?
    fi
  fi

  if [[ -f "$ROOT/Package.swift" ]]; then
    command -v swift >/dev/null 2>&1 || die "swift is required for Package.swift builds"
    prepare_swift_environment
    log "building Swift package"
    swift build --configuration "$SWIFT_BUILD_CONFIGURATION" --scratch-path "$ROOT/.build" --cache-path "$ROOT/.build/harness-cache/swiftpm" --product BalaganApp
    swift build --configuration "$SWIFT_BUILD_CONFIGURATION" --scratch-path "$ROOT/.build" --cache-path "$ROOT/.build/harness-cache/swiftpm" --product BalaganUIDriver
    swift build --configuration "$SWIFT_BUILD_CONFIGURATION" --scratch-path "$ROOT/.build" --cache-path "$ROOT/.build/harness-cache/swiftpm" --product balagan-agent
    return $?
  fi

  log "no Package.swift, .xcodeproj, or .xcworkspace found; build placeholder skipped"
}

run_test() {
  local workspace=""
  local project=""

  workspace="$(xcode_workspace || true)"
  project="$(xcode_project || true)"

  if [[ -n "$workspace" || -n "$project" ]]; then
    command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required for the discovered Xcode test target"
    if [[ -n "$workspace" ]]; then
      log "testing Xcode workspace $workspace with scheme $BALAGAN_SCHEME"
      xcodebuild test -workspace "$workspace" -scheme "$BALAGAN_SCHEME" -destination "$BALAGAN_DESTINATION" -configuration "$BALAGAN_BUILD_CONFIGURATION"
      return $?
    else
      log "testing Xcode project $project with scheme $BALAGAN_SCHEME"
      xcodebuild test -project "$project" -scheme "$BALAGAN_SCHEME" -destination "$BALAGAN_DESTINATION" -configuration "$BALAGAN_BUILD_CONFIGURATION"
      return $?
    fi
  fi

  if [[ -f "$ROOT/Package.swift" ]]; then
    command -v swift >/dev/null 2>&1 || die "swift is required for Package.swift tests"
    prepare_swift_environment
    log "testing Swift package"
    swift test --scratch-path "$ROOT/.build" --cache-path "$ROOT/.build/harness-cache/swiftpm"
    return $?
  fi

  log "no Package.swift, .xcodeproj, or .xcworkspace found; test placeholder skipped"
}

run_ui_test() {
  local fixture="${1:-${FIXTURE:-multi-project-running}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"

  validate_fixtures

  local run_dir
  local db
  run_dir="$(make_run_dir ui-test "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract ui-test "$fixture" "$fixture_file" "$db" "$run_dir"

  local workspace=""
  local project=""
  workspace="$(xcode_workspace || true)"
  project="$(xcode_project || true)"

  if [[ -z "$workspace" && -z "$project" ]]; then
    log "no Xcode project/workspace found; running SwiftPM UI smoke instead of XCUITest"
    run_swiftpm_ui_smoke "$fixture" "$fixture_file" "$db" "$run_dir"
    log "UI test artifacts: $run_dir"
    return 0
  fi

  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required for UI tests"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  if [[ -n "$workspace" ]]; then
    log "running XCUITest workspace $workspace with scheme $BALAGAN_UI_TEST_SCHEME"
    xcodebuild test -workspace "$workspace" -scheme "$BALAGAN_UI_TEST_SCHEME" -destination "$BALAGAN_DESTINATION" -configuration "$BALAGAN_BUILD_CONFIGURATION" -resultBundlePath "$run_dir/BalaganUITests.xcresult"
  else
    log "running XCUITest project $project with scheme $BALAGAN_UI_TEST_SCHEME"
    xcodebuild test -project "$project" -scheme "$BALAGAN_UI_TEST_SCHEME" -destination "$BALAGAN_DESTINATION" -configuration "$BALAGAN_BUILD_CONFIGURATION" -resultBundlePath "$run_dir/BalaganUITests.xcresult"
  fi

  log "UI test artifacts: $run_dir"
}

run_ui_controls_smoke() {
  local fixture="${1:-${FIXTURE:-multi-project-running}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  local run_dir
  local db
  run_dir="$(make_run_dir ui-controls-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract ui-controls-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; UI controls smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"
  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running UI controls smoke with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_ui_artifacts "$run_dir" "$fixture" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_ui_flow_controls "$run_dir" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow settings \
      >"$run_dir/ui-settings-driver.log" 2>&1 || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true

  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  log "UI controls smoke artifacts: $run_dir"
}

run_ui_flow_smoke() {
  local fixture="${1:-${FIXTURE:-empty-board}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for ui-flow-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir ui-flow-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract ui-flow-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; UI flow smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_RUN_UI_FLOW_SMOKE=1
  export BALAGAN_FREEZE_TIME

  log "running scripted UI flow smoke with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    --run-ui-flow-smoke \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "scripted UI flow launch did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_ui_artifacts "$run_dir" "ui-flow-smoke" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_ui_flow_smoke_artifact "$run_dir" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "ui-flow-smoke" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_ui_flow_database_snapshot "$run_dir/database-snapshot.json" "SQLite scripted UI flow snapshot" || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"

  export BALAGAN_RUN_UI_FLOW_SMOKE=0
  log "running scripted UI flow SQLite restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$database_restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=0 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-ui-flow-from-sqlite \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local database_restore_pid="$!"
  printf '%s\n' "$database_restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$database_restore_pid" >/dev/null 2>&1 || true
    wait "$database_restore_pid" >/dev/null 2>&1 || true
    die "scripted UI flow SQLite restore did not write app-ready.json; see $database_restore_dir/app.log"
  fi

  assertion_status=0
  assert_ui_artifacts "$database_restore_dir" "ui-flow-smoke" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$database_restore_dir/app-ready.json" "\"dataSource\" : \"sqlite\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_ui_flow_restored_artifact "$database_restore_dir" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$database_restore_dir" "$db" "ui-flow-smoke" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_ui_flow_database_snapshot "$database_restore_dir/database-snapshot.json" "restored SQLite scripted UI flow snapshot" || assertion_status=$?
  fi

  kill "$database_restore_pid" >/dev/null 2>&1 || true
  wait "$database_restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  log "UI flow smoke artifacts: $run_dir"
}

run_ui_native_flow_smoke() {
  local fixture="${1:-${FIXTURE:-empty-board}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for ui-native-flow-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir ui-native-flow-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract ui-native-flow-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; native UI flow smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running native Accessibility UI flow smoke with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "native UI flow launch did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  "$ui_driver" \
    --pid "$app_pid" \
    --artifact-dir "$run_dir" \
    >"$run_dir/ui-native-flow-driver.log" 2>&1 || assertion_status=$?

  if [[ "$assertion_status" -eq 0 ]]; then
    sleep 1
    assert_ui_native_flow_driver_artifact "$run_dir" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "ui-native-flow-smoke" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_native_ui_flow_database_snapshot "$run_dir/database-snapshot.json" "native UI flow SQLite snapshot" || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-native-flow-driver-error.txt" ]]; then
      cat "$run_dir/ui-native-flow-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-native-flow-driver-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-create-edit-status-tab",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-native-flow-driver-error.txt",
  "logArtifact": "$run_dir/ui-native-flow-driver.log",
  "permissionRequirement": "Grant Accessibility permission to the launching shell or Codex host in System Settings > Privacy & Security > Accessibility."
}
EOF
    die "native UI flow smoke failed or was blocked; see $run_dir/ui-native-flow-driver-error.txt and $run_dir/ui-native-flow-driver.log"
  fi

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"

  log "running native UI flow SQLite restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$database_restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=0 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-native-ui-flow-from-sqlite \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local database_restore_pid="$!"
  printf '%s\n' "$database_restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$database_restore_pid" >/dev/null 2>&1 || true
    wait "$database_restore_pid" >/dev/null 2>&1 || true
    die "native UI flow SQLite restore did not write app-ready.json; see $database_restore_dir/app.log"
  fi

  assertion_status=0
  assert_file_contains "$database_restore_dir/app-ready.json" "\"dataSource\" : \"sqlite\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_ui_flow_restored_artifact "$database_restore_dir" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$database_restore_dir" "$db" "ui-native-flow-smoke" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_native_ui_flow_database_snapshot "$database_restore_dir/database-snapshot.json" "restored native UI flow SQLite snapshot" || assertion_status=$?
  fi

  kill "$database_restore_pid" >/dev/null 2>&1 || true
  wait "$database_restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  log "native UI flow smoke artifacts: $run_dir"
}

run_ui_daily_driver_smoke() {
  local fixture="${1:-${FIXTURE:-empty-board}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for ui-daily-driver-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir ui-daily-driver-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract ui-daily-driver-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; daily native UI driver smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running daily native Accessibility UI driver smoke with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "daily native UI driver launch did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  "$ui_driver" \
    --pid "$app_pid" \
    --artifact-dir "$run_dir" \
    --flow daily-driver \
    >"$run_dir/ui-daily-driver.log" 2>&1 || assertion_status=$?

  if [[ "$assertion_status" -eq 0 ]]; then
    sleep 1
    assert_ui_daily_driver_artifact "$run_dir" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "ui-daily-driver-smoke" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_daily_driver_database_snapshot "$run_dir/database-snapshot.json" "daily native UI driver SQLite snapshot" || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-daily-driver-error.txt" ]]; then
      cat "$run_dir/ui-daily-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-daily-driver-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-daily-driver",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-daily-driver-error.txt",
  "logArtifact": "$run_dir/ui-daily-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-daily-driver-accessibility-dump.txt",
  "permissionRequirement": "Grant Accessibility permission to the launching shell or Codex host in System Settings > Privacy & Security > Accessibility."
}
EOF
    die "daily native UI driver smoke failed or was blocked; see $run_dir/ui-daily-driver-error.txt, $run_dir/ui-daily-driver.log, and $run_dir/ui-daily-driver-accessibility-dump.txt"
  fi

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"

  log "running daily native UI driver SQLite restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$database_restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=0 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-daily-driver-from-sqlite \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local database_restore_pid="$!"
  printf '%s\n' "$database_restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$database_restore_pid" >/dev/null 2>&1 || true
    wait "$database_restore_pid" >/dev/null 2>&1 || true
    die "daily native UI driver SQLite restore did not write app-ready.json; see $database_restore_dir/app.log"
  fi

  assertion_status=0
  assert_file_contains "$database_restore_dir/app-ready.json" "\"dataSource\" : \"sqlite\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$database_restore_dir" "$db" "ui-daily-driver-smoke" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_daily_driver_database_snapshot "$database_restore_dir/database-snapshot.json" "restored daily native UI driver SQLite snapshot" || assertion_status=$?
  fi

  kill "$database_restore_pid" >/dev/null 2>&1 || true
  wait "$database_restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  log "daily native UI driver smoke artifacts: $run_dir"
}

run_terminal_state_smoke() {
  local fixture="${1:-${FIXTURE:-multi-project-running}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"
  prepare_fixture_worktrees "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for terminal-state-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-state-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-state-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal state smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_CAPTURE_TERMINAL_STATE=1
  export BALAGAN_FREEZE_TIME

  log "running terminal state capture smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    --capture-terminal-state \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal state capture launch did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_ui_artifacts "$run_dir" "$fixture" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_state_capture_artifact "$run_dir" "captured" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "$fixture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_contract_strings_in_file "$ROOT/scripts/balagan-terminal-state-smoke-contract.txt" "$run_dir/database-snapshot.json" "terminal state SQLite snapshot" || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"

  log "running terminal state SQLite restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH -u BALAGAN_CAPTURE_TERMINAL_STATE \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$database_restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=0 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --fixture restored-terminal-state-from-sqlite \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local database_restore_pid="$!"
  printf '%s\n' "$database_restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$database_restore_pid" >/dev/null 2>&1 || true
    wait "$database_restore_pid" >/dev/null 2>&1 || true
    die "terminal state SQLite restore did not write app-ready.json; see $database_restore_dir/app.log"
  fi

  assertion_status=0
  assert_file_contains "$database_restore_dir/app-ready.json" "\"dataSource\" : \"sqlite\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_state_capture_artifact "$database_restore_dir" "observed" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$database_restore_dir" "$db" "$fixture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_contract_strings_in_file "$ROOT/scripts/balagan-terminal-state-smoke-contract.txt" "$database_restore_dir/database-snapshot.json" "restored terminal state SQLite snapshot" || assertion_status=$?
  fi

  kill "$database_restore_pid" >/dev/null 2>&1 || true
  wait "$database_restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  log "terminal state smoke artifacts: $run_dir"
}

run_terminal_restart_resume_smoke() {
  local fixture="resumable-task"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for terminal-restart-resume-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-restart-resume-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-restart-resume-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal restart/resume smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=1
  export BALAGAN_FREEZE_TIME

  log "seeding restart/resume SQLite state with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local seed_pid="$!"
  printf '%s\n' "$seed_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$seed_pid" >/dev/null 2>&1 || true
    wait "$seed_pid" >/dev/null 2>&1 || true
    die "restart/resume seed launch did not write app-ready.json; see $run_dir/app.log"
  fi
  if ! wait_for_file "$run_dir/resume-request.json" 5; then
    kill "$seed_pid" >/dev/null 2>&1 || true
    wait "$seed_pid" >/dev/null 2>&1 || true
    die "restart/resume seed launch did not write trusted resume-request.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_ui_artifacts "$run_dir" "$fixture" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "$fixture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "\"selectedWorkspaceID\" : \"workspace-resume-codex\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "\"selectedSurfaceID\" : \"surface-codex-resume\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "surface-tmux-review" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "restart-resume-seed"

  kill "$seed_pid" >/dev/null 2>&1 || true
  wait "$seed_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"

  log "running restart/resume SQLite restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$database_restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=1 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-restart-resume-from-sqlite \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "restart/resume SQLite restore did not write app-ready.json; see $database_restore_dir/app.log"
  fi
  if ! wait_for_file "$database_restore_dir/resume-request.json" 5; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "restart/resume SQLite restore did not write trusted resume-request.json; see $database_restore_dir/app.log"
  fi
  cp "$database_restore_dir/resume-request.json" "$database_restore_dir/auto-resume-request.json"

  assertion_status=0
  assert_ui_artifacts "$database_restore_dir" "$fixture" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$database_restore_dir" "$db" "$fixture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_restart_resume_restore_artifacts "$database_restore_dir" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$restore_pid" \
      --artifact-dir "$database_restore_dir" \
      --flow terminal-restart-resume \
      >"$database_restore_dir/ui-terminal-restart-resume-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_restart_resume_driver_artifact "$database_restore_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$database_restore_dir" "restart-resume-restored"

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$database_restore_dir/ui-terminal-restart-resume-driver-error.txt" ]]; then
      cat "$database_restore_dir/ui-terminal-restart-resume-driver-error.txt" >&2
    fi
    cat >"$database_restore_dir/ui-terminal-restart-resume-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-restart-resume",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$database_restore_dir/ui-terminal-restart-resume-driver-error.txt",
  "logArtifact": "$database_restore_dir/ui-terminal-restart-resume-driver.log",
  "accessibilityDumpArtifact": "$database_restore_dir/ui-terminal-restart-resume-accessibility-dump.txt",
  "autoResumeArtifact": "$database_restore_dir/auto-resume-request.json",
  "confirmedResumeArtifact": "$database_restore_dir/resume-request.json"
}
EOF
    die "terminal restart/resume smoke failed; see $database_restore_dir/ui-terminal-restart-resume-driver-error.txt, $database_restore_dir/ui-terminal-restart-resume-driver.log, and $database_restore_dir/ui-terminal-restart-resume-accessibility-dump.txt"
  fi

  log "terminal restart/resume smoke artifacts: $run_dir"
}

# The lifecycle half of the hook path (`PermissionRequest`/`PostToolUse`/`PreToolUse`/`Stop` moving a
# task's agent state), driven through the real `balagan-agent hook` binary. It needs neither a
# fixture database nor the UI driver, so it lives in its own self-contained script.
run_hook_lifecycle_smoke() {
  "$ROOT/scripts/hook-lifecycle-smoke.sh" "$@"
}

run_hook_smoke() {
  local fixture="multi-project-running"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"
  prepare_fixture_worktrees "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for hook-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir hook-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract hook-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; hook smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  local run_name="${run_dir##*/}"
  local socket_path="/tmp/balagan-hook-$run_name-$$.sock"
  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_SOCKET_PATH="$socket_path"
  export BALAGAN_FREEZE_TIME

  log "launching hook smoke app with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    --session-report-socket "$socket_path" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "hook smoke app did not write app-ready.json; see $run_dir/app.log"
  fi
  if ! wait_for_file "$run_dir/session-report-socket.json" 5; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "hook smoke app did not write session-report-socket.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  "$ui_driver" \
    --send-session-report \
    --socket-path "$socket_path" \
    --artifact-dir "$run_dir" \
    --task-id task-fake-terminal \
    --workspace-id workspace-fake-terminal \
    --surface-id surface-fake-terminal-main \
    --agent-name codex \
    --session-id fake-session-123 \
    --cwd /tmp/balagan-fixtures/balagan \
    --status running \
    --command codex \
    --executable-path /opt/homebrew/bin/codex \
    >"$run_dir/session-report-sender.log" 2>&1 || assertion_status=$?

  if [[ "$assertion_status" -eq 0 ]] && ! wait_for_file "$run_dir/session-report-last.json" 5; then
    assertion_status=1
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-sent.json" "\"sessionID\" : \"fake-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"status\" : \"applied\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"resumeCommand\" : \"codex resume fake-session-123\"" || assertion_status=$?
  fi

  sleep 1
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"source\" : \"agent-hook\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"autoResume\" : true" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"trust\" : \"trusted\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"sessionID\" : \"fake-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "$fixture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "\"source\" : \"agent-hook\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "\"sessionID\" : \"fake-session-123\"" || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || die "hook smoke failed; see $run_dir/session-report-sender.log, $run_dir/session-report-last.json, and $run_dir/app.log"

  local restore_dir="$run_dir/database-restore"
  mkdir -p "$restore_dir/screenshots"

  log "running hook smoke SQLite restore from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=1 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-hook-smoke-from-sqlite \
    --database "$db" \
    --artifact-dir "$restore_dir" \
    >"$restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$restore_dir/app.pid"

  if ! wait_for_file "$restore_dir/app-ready.json" 10; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "hook smoke SQLite restore did not write app-ready.json; see $restore_dir/app.log"
  fi
  if ! wait_for_file "$restore_dir/resume-request.json" 5; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "hook smoke SQLite restore did not write resume-request.json; see $restore_dir/app.log"
  fi

  assertion_status=0
  assert_file_contains "$restore_dir/resume-request.json" "\"displayCommand\" : \"codex resume fake-session-123\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$restore_dir/resume-request.json" "\"requiresConfirmation\" : false" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$restore_dir" "$db" "$fixture" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$restore_dir" "hook-smoke-restored"

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || die "hook smoke restore failed; see $restore_dir/resume-request.json and $restore_dir/app.log"

  log "hook smoke artifacts: $run_dir"
}

run_agent_wrapper_smoke() {
  local fixture="multi-project-running"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"
  prepare_fixture_worktrees "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for agent-wrapper-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir agent-wrapper-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract agent-wrapper-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; agent wrapper smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local wrapper=""
  wrapper="$(discover_swiftpm_agent_wrapper || true)"
  [[ -n "$wrapper" ]] || die "SwiftPM balagan-agent executable not found after build"

  local fake_bin="$run_dir/fake-bin"
  local fake_claude="$fake_bin/claude"
  local fake_codex="$fake_bin/codex"
  mkdir -p "$fake_bin"
  cat >"$fake_claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${BALAGAN_FAKE_AGENT_ARGV_PATH:?}"
printf 'fake claude ran\n' >"${BALAGAN_FAKE_AGENT_RAN_PATH:?}"
EOF
  chmod +x "$fake_claude"
  cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${BALAGAN_FAKE_CODEX_ARGV_PATH:?}"
printf 'fake codex ran\n' >"${BALAGAN_FAKE_CODEX_RAN_PATH:?}"
printf '%s\n' "$$" >"${BALAGAN_FAKE_CODEX_PID_PATH:?}"
printf 'fake codex terminal output\n'
codex_home="${BALAGAN_CODEX_CAPTURE_HOME:?}"
mkdir -p "$codex_home/.codex"
db="$codex_home/.codex/state_5.sqlite"
created_at_ms="$(($(date +%s) * 1000 + 5000))"
sqlite3 "$db" "CREATE TABLE IF NOT EXISTS threads (id TEXT, rollout_path TEXT, created_at_ms INTEGER, cwd TEXT);"
sqlite3 "$db" "DELETE FROM threads;"
sqlite3 "$db" "INSERT INTO threads VALUES ('fake-codex-session-123', '/tmp/fake-codex-rollout.jsonl', $created_at_ms, '$PWD');"
EOF
  chmod +x "$fake_codex"

  local run_name="${run_dir##*/}"
  local socket_path="/tmp/balagan-agent-wrapper-$run_name-$$.sock"
  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_SOCKET_PATH="$socket_path"
  export BALAGAN_FREEZE_TIME

  log "launching agent wrapper smoke app with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    --session-report-socket "$socket_path" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "agent wrapper smoke app did not write app-ready.json; see $run_dir/app.log"
  fi
  if ! wait_for_file "$run_dir/session-report-socket.json" 5; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "agent wrapper smoke app did not write session-report-socket.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  BALAGAN_TASK_ID=task-fake-terminal \
    BALAGAN_WORKSPACE_ID=workspace-fake-terminal \
    BALAGAN_SURFACE_ID=surface-fake-terminal-main \
    BALAGAN_SOCKET_PATH="$socket_path" \
    BALAGAN_CLAUDE_EXECUTABLE="$fake_claude" \
    BALAGAN_FAKE_AGENT_ARGV_PATH="$run_dir/fake-claude-argv.txt" \
    BALAGAN_FAKE_AGENT_RAN_PATH="$run_dir/fake-claude-ran.txt" \
    "$wrapper" claude --model sonnet \
    >"$run_dir/balagan-agent.log" 2>&1 || assertion_status=$?

  if [[ "$assertion_status" -eq 0 ]] && ! wait_for_file "$run_dir/session-report-last.json" 5; then
    assertion_status=1
  fi
  local session_id=""
  if [[ "$assertion_status" -eq 0 ]]; then
    session_id="$(awk 'previous == "--session-id" { print; exit } { previous=$0 }' "$run_dir/fake-claude-argv.txt")"
    [[ -n "$session_id" ]] || assertion_status=1
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/fake-claude-ran.txt" "fake claude ran" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"status\" : \"applied\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"resumeCommand\" : \"claude --resume $session_id\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    PATH="$fake_bin:$PATH" \
      BALAGAN_TASK_ID=task-fake-terminal \
      BALAGAN_WORKSPACE_ID=workspace-fake-terminal \
      BALAGAN_SURFACE_ID=surface-fake-terminal-main \
      BALAGAN_SOCKET_PATH="$socket_path" \
      BALAGAN_CODEX_CAPTURE_HOME="$run_dir/fake-codex-home" \
      BALAGAN_FAKE_CODEX_ARGV_PATH="$run_dir/fake-codex-argv.txt" \
      BALAGAN_FAKE_CODEX_RAN_PATH="$run_dir/fake-codex-ran.txt" \
      BALAGAN_FAKE_CODEX_PID_PATH="$run_dir/fake-codex-pid.txt" \
      "$wrapper" codex --model gpt-5 \
      >"$run_dir/balagan-agent-codex.log" 2>&1 &
    local codex_wrapper_pid="$!"
    printf '%s\n' "$codex_wrapper_pid" >"$run_dir/balagan-agent-codex.pid"
    wait "$codex_wrapper_pid" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/fake-codex-ran.txt" "fake codex ran" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/balagan-agent-codex.log" "fake codex terminal output" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_not_contains "$run_dir/balagan-agent-codex.log" "Manual capture required" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_not_contains "$run_dir/balagan-agent-codex.log" "Codex wrapper will attempt local state capture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    local fake_codex_pid=""
    fake_codex_pid="$(tr -d '\n' <"$run_dir/fake-codex-pid.txt")"
    [[ "$fake_codex_pid" == "$codex_wrapper_pid" ]] || assertion_status=1
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    wait_for_file_contains "$run_dir/session-report-last.json" "\"agentName\" : \"codex\"" 5 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"agentName\" : \"codex\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"status\" : \"applied\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"resumeCommand\" : \"codex resume fake-codex-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    sleep 1
    assert_file_contains "$run_dir/Balagan.state.json" "\"sessionID\" : \"fake-codex-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    BALAGAN_TASK_ID=task-fake-terminal \
      BALAGAN_WORKSPACE_ID=workspace-fake-terminal \
      BALAGAN_SURFACE_ID=surface-fake-terminal-main \
      BALAGAN_SOCKET_PATH="$socket_path" \
      BALAGAN_CLAUDE_EXECUTABLE="$fake_claude" \
      BALAGAN_FAKE_AGENT_ARGV_PATH="$run_dir/fake-claude-restore-argv.txt" \
      BALAGAN_FAKE_AGENT_RAN_PATH="$run_dir/fake-claude-restore-ran.txt" \
      "$wrapper" claude --resume "$session_id" \
      >"$run_dir/balagan-agent-claude-restore.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/session-report-last.json" "\"resumeCommand\" : \"claude --resume $session_id\"" || assertion_status=$?
  fi

  sleep 1
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"source\" : \"agent-hook\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"autoResume\" : true" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"agentName\" : \"claude\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"sessionID\" : \"$session_id\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "$fixture" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "\"agentName\" : \"claude\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/database-snapshot.json" "\"sessionID\" : \"$session_id\"" || assertion_status=$?
  fi
  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || die "agent wrapper smoke failed; see $run_dir/balagan-agent.log, $run_dir/balagan-agent-codex.log, $run_dir/session-report-last.json, and $run_dir/app.log"

  local restore_dir="$run_dir/database-restore"
  mkdir -p "$restore_dir/screenshots"

  log "running agent wrapper smoke SQLite restore from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=1 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-agent-wrapper-smoke-from-sqlite \
    --database "$db" \
    --artifact-dir "$restore_dir" \
    >"$restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$restore_dir/app.pid"

  if ! wait_for_file "$restore_dir/app-ready.json" 10; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "agent wrapper smoke SQLite restore did not write app-ready.json; see $restore_dir/app.log"
  fi
  if ! wait_for_file "$restore_dir/resume-request.json" 5; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "agent wrapper smoke SQLite restore did not write resume-request.json; see $restore_dir/app.log"
  fi

  assertion_status=0
  assert_file_contains "$restore_dir/resume-request.json" "\"displayCommand\" : \"claude --resume $session_id\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$restore_dir/resume-request.json" "\"requiresConfirmation\" : false" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$restore_dir" "$db" "$fixture" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$restore_dir" "agent-wrapper-smoke-restored"

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || die "agent wrapper smoke restore failed; see $restore_dir/resume-request.json and $restore_dir/app.log"

  log "agent wrapper smoke artifacts: $run_dir"
}

run_agent_reopen_smoke() {
  local fixture="multi-project-running"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"
  prepare_fixture_worktrees "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for agent-reopen-smoke because it verifies the persisted SQLite snapshot payload"

  local run_dir
  local db
  run_dir="$(make_run_dir agent-reopen-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract agent-reopen-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; agent reopen smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local wrapper=""
  wrapper="$(discover_swiftpm_agent_wrapper || true)"
  [[ -n "$wrapper" ]] || die "SwiftPM balagan-agent executable not found after build"

  local fake_bin="$run_dir/fake-bin"
  local fake_codex="$fake_bin/codex"
  mkdir -p "$fake_bin"
  cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${BALAGAN_FAKE_CODEX_ARGV_PATH:?}"
printf 'fake codex ran\n' >"${BALAGAN_FAKE_CODEX_RAN_PATH:?}"
printf 'fake codex terminal output\n'
codex_home="${BALAGAN_CODEX_CAPTURE_HOME:?}"
mkdir -p "$codex_home/.codex"
db="$codex_home/.codex/state_5.sqlite"
created_at_ms="$(($(date +%s) * 1000 + 5000))"
sqlite3 "$db" "CREATE TABLE IF NOT EXISTS threads (id TEXT, rollout_path TEXT, created_at_ms INTEGER, cwd TEXT);"
sqlite3 "$db" "DELETE FROM threads;"
sqlite3 "$db" "INSERT INTO threads VALUES ('fake-reopen-codex-session-123', '/tmp/fake-reopen-codex-rollout.jsonl', $created_at_ms, '$PWD');"
EOF
  chmod +x "$fake_codex"

  local run_name="${run_dir##*/}"
  local socket_path="/tmp/balagan-agent-reopen-$run_name-$$.sock"

  log "launching agent reopen smoke app with fixture $fixture"
  PATH="$fake_bin:$PATH" \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_FIXTURE_PATH="$fixture_file" \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_STATE_PATH="$run_dir/Balagan.state.json" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir" \
    BALAGAN_SOCKET_PATH="$socket_path" \
    BALAGAN_AGENT_WRAPPER_PATH="$wrapper" \
    BALAGAN_CODEX_CAPTURE_HOME="$run_dir/fake-codex-home" \
    BALAGAN_FAKE_CODEX_ARGV_PATH="$run_dir/fake-codex-argv.txt" \
    BALAGAN_FAKE_CODEX_RAN_PATH="$run_dir/fake-codex-ran.txt" \
    BALAGAN_RUN_AGENT_REOPEN_CAPTURE_SMOKE=1 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    --session-report-socket "$socket_path" \
    --agent-wrapper-path "$wrapper" \
    --run-agent-reopen-capture-smoke \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  local assertion_status=0
  if ! wait_for_file "$run_dir/agent-reopen-capture-smoke.json" 20; then
    assertion_status=1
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/agent-reopen-capture-smoke.json" "\"status\" : \"captured\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/agent-reopen-capture-smoke.json" "balagan-agent' codex" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/agent-reopen-capture-smoke.json" "\"bindingSource\" : \"agent-hook\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/agent-reopen-capture-smoke.json" "\"autoResume\" : true" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/agent-reopen-capture-smoke.json" "\"sessionID\" : \"fake-reopen-codex-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/agent-reopen-capture-smoke.json" "\"restoreCommand\" : \"codex resume fake-reopen-codex-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_not_contains "$run_dir/agent-reopen-capture-smoke.json" "\"restoreCommand\" : \"'$wrapper' codex\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/fake-codex-ran.txt" "fake codex ran" || assertion_status=$?
  fi
  sleep 1
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"source\" : \"agent-hook\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"autoResume\" : true" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/Balagan.state.json" "\"sessionID\" : \"fake-reopen-codex-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$run_dir" "$db" "$fixture" || assertion_status=$?
  fi

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || die "agent reopen smoke failed; see $run_dir/agent-reopen-capture-smoke.json and $run_dir/app.log"

  local restore_dir="$run_dir/database-restore"
  mkdir -p "$restore_dir/screenshots"

  log "running agent reopen SQLite restore from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH -u BALAGAN_RUN_AGENT_REOPEN_CAPTURE_SMOKE \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=1 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --ui-test-mode \
    --fixture restored-agent-reopen-from-sqlite \
    --database "$db" \
    --artifact-dir "$restore_dir" \
    >"$restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$restore_dir/app.pid"

  if ! wait_for_file "$restore_dir/resume-request.json" 10; then
    assertion_status=1
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$restore_dir/resume-request.json" "\"displayCommand\" : \"codex resume fake-reopen-codex-session-123\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$restore_dir/resume-request.json" "\"requiresConfirmation\" : false" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_not_contains "$restore_dir/resume-request.json" "balagan-agent codex" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_database_snapshot "$restore_dir" "$db" "$fixture" || assertion_status=$?
  fi

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || die "agent reopen restore failed; see $restore_dir/resume-request.json and $restore_dir/app.log"

  log "agent reopen smoke artifacts: $run_dir"
}

run_terminal_reload_prompt_smoke() {
  local fixture="reload-prompt-resume"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required for terminal-reload-prompt-smoke because it verifies the persisted SQLite snapshot payload"

  mkdir -p /tmp/balagan-harness-smoke/fake-bin /tmp/balagan-fixtures/reload-prompt
  cat > /tmp/balagan-harness-smoke/fake-bin/codex <<'EOF'
#!/usr/bin/env bash
for _ in 1 2 3 4 5; do
  printf 'FAKE_CODEX_ARGS:%s:%s\n' "${1:-}" "${2:-}"
  sleep 0.2
done
exec /bin/sh
EOF
  chmod +x /tmp/balagan-harness-smoke/fake-bin/codex

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-reload-prompt-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-reload-prompt-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal reload prompt smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=1
  export BALAGAN_FREEZE_TIME

  log "seeding reload prompt SQLite state with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local seed_pid="$!"
  printf '%s\n' "$seed_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$seed_pid" >/dev/null 2>&1 || true
    wait "$seed_pid" >/dev/null 2>&1 || true
    die "reload prompt seed launch did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_database_snapshot "$run_dir" "$db" "$fixture" || assertion_status=$?

  kill "$seed_pid" >/dev/null 2>&1 || true
  wait "$seed_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  local database_restore_dir="$run_dir/database-restore"
  mkdir -p "$database_restore_dir/screenshots"

  log "running live reload prompt restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH -u BALAGAN_DISABLE_REAL_PROCESSES \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$database_restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=1 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --fixture restored-reload-prompt-from-sqlite \
    --database "$db" \
    --artifact-dir "$database_restore_dir" \
    >"$database_restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$database_restore_dir/app.pid"

  if ! wait_for_file "$database_restore_dir/app-ready.json" 10; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "reload prompt SQLite restore did not write app-ready.json; see $database_restore_dir/app.log"
  fi

  assertion_status=0
  assert_file_contains "$database_restore_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$restore_pid" \
      --artifact-dir "$database_restore_dir" \
      --flow terminal-reload-prompt \
      >"$database_restore_dir/ui-terminal-reload-prompt-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_reload_prompt_driver_artifact "$database_restore_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$database_restore_dir" "terminal-reload-prompt"

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$database_restore_dir/ui-terminal-reload-prompt-driver-error.txt" ]]; then
      cat "$database_restore_dir/ui-terminal-reload-prompt-driver-error.txt" >&2
    fi
    cat >"$database_restore_dir/ui-terminal-reload-prompt-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-reload-prompt",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$database_restore_dir/ui-terminal-reload-prompt-driver-error.txt",
  "logArtifact": "$database_restore_dir/ui-terminal-reload-prompt-driver.log",
  "accessibilityDumpArtifact": "$database_restore_dir/ui-terminal-reload-prompt-accessibility-dump.txt",
  "visibleTextArtifact": "$database_restore_dir/libghostty-terminal-visible-text-surface-reload-prompt.txt"
}
EOF
    die "terminal reload prompt smoke failed; see $database_restore_dir/ui-terminal-reload-prompt-driver-error.txt, $database_restore_dir/ui-terminal-reload-prompt-driver.log, and $database_restore_dir/ui-terminal-reload-prompt-accessibility-dump.txt"
  fi

  log "terminal reload prompt smoke artifacts: $run_dir"
}

run_ui_debug() {
  local fixture="${1:-${FIXTURE:-multi-project-running}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  local run_dir
  local db
  run_dir="$(make_run_dir ui-debug "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract ui-debug "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; UI debug launch skipped"
    log "prepared deterministic UI debug artifacts: $run_dir"
    return 1
  fi

  local app=""
  app="$(discover_app || true)"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FAKE_TERMINAL_OUTPUT="$fixture"
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  if [[ -n "$app" ]]; then
    log "launching $app in UI debug mode with fixture $fixture"
    open -na "$app" --args \
      --ui-test-mode \
      --fixture "$fixture" \
      --fixture-path "$fixture_file" \
      --database "$db" \
      --state-path "$run_dir/Balagan.state.json" \
      --artifact-dir "$run_dir"

    log "UI debug artifacts: $run_dir"
    return 0
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  if [[ -n "$executable" ]]; then
    local bundled_app
    bundled_app="$(stage_swiftpm_app_bundle "$executable" "$run_dir")"

    log "launching SwiftPM app bundle $bundled_app in UI debug mode with fixture $fixture"
    open -na "$bundled_app" --args \
      --ui-test-mode \
      --fixture "$fixture" \
      --fixture-path "$fixture_file" \
      --database "$db" \
      --state-path "$run_dir/Balagan.state.json" \
      --artifact-dir "$run_dir"
    printf '%s\n' "launched via LaunchServices" >"$run_dir/app.pid"

    log "UI debug artifacts: $run_dir"
    return 0
  fi

  log "no .app bundle or SwiftPM executable found; run make build first or set BALAGAN_APP_PATH"
  log "prepared deterministic UI debug artifacts: $run_dir"
}

run_normal_store_smoke() {
  local fixture="${1:-${FIXTURE:-multi-project-running}}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  local run_dir
  local db
  run_dir="$(make_run_dir normal-store-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract normal-store-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; normal store smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local seed_dir="$run_dir/seed"
  mkdir -p "$seed_dir/screenshots"

  export BALAGAN_DISABLE_REAL_PROCESSES=1
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$seed_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "seeding SQLite store with fixture $fixture"
  "$executable" \
    --ui-test-mode \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --artifact-dir "$seed_dir" \
    >"$seed_dir/app.log" 2>&1 &
  local seed_pid="$!"
  printf '%s\n' "$seed_pid" >"$seed_dir/app.pid"

  if ! wait_for_file "$seed_dir/app-ready.json" 10; then
    kill "$seed_pid" >/dev/null 2>&1 || true
    wait "$seed_pid" >/dev/null 2>&1 || true
    die "seed launch did not write app-ready.json; see $seed_dir/app.log"
  fi

  assert_ui_artifacts "$seed_dir" "$fixture"
  assert_database_snapshot "$seed_dir" "$db" "$fixture"

  kill "$seed_pid" >/dev/null 2>&1 || true
  wait "$seed_pid" >/dev/null 2>&1 || true

  local restore_dir="$run_dir/normal-restore"
  mkdir -p "$restore_dir/screenshots"

  log "running normal SQLite restore smoke from $db"
  env -u BALAGAN_FIXTURE_PATH -u BALAGAN_STATE_PATH \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$restore_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=0 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --fixture restored-from-sqlite \
    --database "$db" \
    --artifact-dir "$restore_dir" \
    >"$restore_dir/app.log" 2>&1 &
  local restore_pid="$!"
  printf '%s\n' "$restore_pid" >"$restore_dir/app.pid"

  if ! wait_for_file "$restore_dir/app-ready.json" 10; then
    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
    die "normal SQLite restore did not write app-ready.json; see $restore_dir/app.log"
  fi

  assert_ui_artifacts "$restore_dir" "$fixture"
  assert_database_snapshot "$restore_dir" "$db" "$fixture"
  assert_file_contains "$restore_dir/app-ready.json" "\"uiTestMode\" : false"
  assert_file_contains "$restore_dir/app-ready.json" "\"disableRealProcesses\" : true"
  assert_file_contains "$restore_dir/app-ready.json" "\"dataSource\" : \"sqlite\""
  [[ ! -f "$restore_dir/Balagan.state.json" ]] || die "normal SQLite restore should not require Balagan.state.json"

  sleep 1
  capture_screenshot "$restore_dir" "board"

  kill "$restore_pid" >/dev/null 2>&1 || true
  wait "$restore_pid" >/dev/null 2>&1 || true

  log "normal store smoke artifacts: $run_dir"
}

run_first_run_smoke() {
  local run_dir
  local db
  run_dir="$(make_run_dir first-run-smoke first-run)"
  db="$run_dir/Balagan.sqlite"
  write_first_run_contract "$db" "$run_dir"

  if ! run_build; then
    log "build failed; first-run smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  log "running normal first-run smoke with fresh SQLite database $db"
  env -u BALAGAN_FIXTURE_PATH \
    -u BALAGAN_STATE_PATH \
    -u BALAGAN_FAKE_TERMINAL_OUTPUT \
    -u BALAGAN_RUN_UI_FLOW_SMOKE \
    -u BALAGAN_CAPTURE_TERMINAL_STATE \
    BALAGAN_DISABLE_REAL_PROCESSES=1 \
    BALAGAN_SQLITE_PATH="$db" \
    BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir" \
    BALAGAN_RECORD_SELECTED_RESUME=0 \
    BALAGAN_FREEZE_TIME="$BALAGAN_FREEZE_TIME" \
    "$executable" \
    --database "$db" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "first-run launch did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_first_run_artifacts "$run_dir" "$db" || assertion_status=$?

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  [[ "$assertion_status" -eq 0 ]] || return "$assertion_status"

  log "first-run smoke artifacts: $run_dir"
}

run_live_backend_smoke() {
  local fixture="${1:-multi-project-running}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  local run_dir
  local db
  run_dir="$(make_run_dir live-backend-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract live-backend-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; live backend smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live libghostty backend smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "app did not write app-ready.json; see $run_dir/app.log"
  fi

  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\""
  assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\""

  local host_artifact="$run_dir/libghostty-terminal-surface-fake-terminal-main.json"
  if ! wait_for_file "$host_artifact" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "libghostty host did not write $host_artifact; see $run_dir/app.log"
  fi

  assert_file_contains "$host_artifact" "\"status\" : \"mounted\""

  sleep 1
  capture_screenshot "$run_dir" "board"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true

  log "live backend smoke artifacts: $run_dir"
}

run_terminal_input_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-input-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-input-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal input smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live terminal input smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal input app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-input \
      >"$run_dir/ui-terminal-input-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_input_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-input"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-input-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-input-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-input-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-input",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-input-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-input-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-input-accessibility-dump.txt",
  "beforeSwitchMarkerArtifact": "$run_dir/terminal-input-before-switch.txt",
  "afterSwitchMarkerArtifact": "$run_dir/terminal-input-after-switch.txt",
  "secondTabMarkerArtifact": "$run_dir/terminal-input-second-tab.txt",
  "stateMarkerArtifact": "$run_dir/terminal-input-output.txt"
}
EOF
    die "terminal input smoke failed; see $run_dir/ui-terminal-input-driver-error.txt, $run_dir/ui-terminal-input-driver.log, and $run_dir/ui-terminal-input-accessibility-dump.txt"
  fi

  log "terminal input smoke artifacts: $run_dir"
}

run_terminal_manual_input_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-manual-input-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-manual-input-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal manual input smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live terminal manual input smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal manual input app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-manual-input \
      >"$run_dir/ui-terminal-manual-input-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_manual_input_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-manual-input"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-manual-input-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-manual-input-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-manual-input-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-manual-input",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-manual-input-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-manual-input-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-manual-input-accessibility-dump.txt"
}
EOF
    die "terminal manual input smoke failed; see $run_dir/ui-terminal-manual-input-driver-error.txt, $run_dir/ui-terminal-manual-input-driver.log, and $run_dir/ui-terminal-manual-input-accessibility-dump.txt"
  fi

  log "terminal manual input smoke artifacts: $run_dir"
}

run_terminal_visible_typing_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-visible-typing-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-visible-typing-smoke "$fixture" "$fixture_file" "$db" "$run_dir"
  local fake_bin="$run_dir/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
exec /bin/sh
EOF
  chmod +x "$fake_bin/codex"

  if ! run_build; then
    log "build failed; terminal visible typing smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME
  export PATH="$fake_bin:$PATH"

  log "running live terminal visible typing smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal visible typing app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-visible-typing \
      >"$run_dir/ui-terminal-visible-typing-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_visible_typing_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-visible-typing"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-visible-typing-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-visible-typing-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-visible-typing-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-visible-typing",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-visible-typing-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-visible-typing-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-visible-typing-accessibility-dump.txt",
  "firstVisibleTextArtifact": "$run_dir/libghostty-terminal-visible-text-surface-harness-task-main.txt",
  "secondVisibleTextArtifact": "$run_dir/libghostty-terminal-visible-text-tab-2.txt"
}
EOF
    die "terminal visible typing smoke failed; see $run_dir/ui-terminal-visible-typing-driver-error.txt, $run_dir/ui-terminal-visible-typing-driver.log, and $run_dir/ui-terminal-visible-typing-accessibility-dump.txt"
  fi

  log "terminal visible typing smoke artifacts: $run_dir"
}

run_terminal_control_keys_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-control-keys-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-control-keys-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal control keys smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live terminal control keys smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal control keys app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-control-keys \
      >"$run_dir/ui-terminal-control-keys-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/ui-terminal-control-keys-driver.json" "\"status\" : \"completed\"" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/terminal-control-interrupt.txt" "BALAGAN_CTRL_C_OK" || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/libghostty-terminal-ended-process-autoclose-tab-2.json" "\"surfaceID\" : \"tab-2\"" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-control-keys"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-control-keys-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-control-keys-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-control-keys-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-control-keys",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-control-keys-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-control-keys-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-control-keys-accessibility-dump.txt",
  "readyMarkerArtifact": "$run_dir/terminal-control-ready.txt",
  "interruptMarkerArtifact": "$run_dir/terminal-control-interrupt.txt",
  "autoCloseArtifact": "$run_dir/libghostty-terminal-ended-process-autoclose-tab-2.json"
}
EOF
    die "terminal control keys smoke failed; see $run_dir/ui-terminal-control-keys-driver-error.txt, $run_dir/ui-terminal-control-keys-driver.log, and $run_dir/ui-terminal-control-keys-accessibility-dump.txt"
  fi

  log "terminal control keys smoke artifacts: $run_dir"
}

run_terminal_close_open_prompt_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-close-open-prompt-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-close-open-prompt-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal close/open prompt smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_EXPECTED_SHELL="${BALAGAN_EXPECTED_SHELL:-${SHELL:-}}"
  export BALAGAN_FREEZE_TIME

  log "running live terminal close/open prompt smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal close/open prompt app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-close-open-prompt \
      >"$run_dir/ui-terminal-close-open-prompt-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_close_open_prompt_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-close-open-prompt"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-close-open-prompt-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-close-open-prompt-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-close-open-prompt-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-close-open-prompt",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-close-open-prompt-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-close-open-prompt-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-close-open-prompt-accessibility-dump.txt",
  "visibleTextArtifact": "$run_dir/libghostty-terminal-visible-text-tab-1.txt"
}
EOF
    die "terminal close/open prompt smoke failed; see $run_dir/ui-terminal-close-open-prompt-driver-error.txt, $run_dir/ui-terminal-close-open-prompt-driver.log, and $run_dir/ui-terminal-close-open-prompt-accessibility-dump.txt"
  fi

  log "terminal close/open prompt smoke artifacts: $run_dir"
}

run_terminal_ended_autoclose_smoke() {
  local fixture="ended-process-autoclose"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-fixtures/ended-autoclose

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-ended-autoclose-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-ended-autoclose-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal ended-process auto-close smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live terminal ended-process auto-close smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal ended-process auto-close app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-ended-autoclose \
      >"$run_dir/ui-terminal-ended-autoclose-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_ended_autoclose_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-ended-autoclose"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-ended-autoclose-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-ended-autoclose-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-ended-autoclose-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-ended-autoclose",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-ended-autoclose-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-ended-autoclose-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-ended-autoclose-accessibility-dump.txt",
  "autoCloseArtifact": "$run_dir/libghostty-terminal-ended-process-autoclose-surface-ended-autoclose.json",
  "visibleTextArtifact": "$run_dir/libghostty-terminal-visible-text-surface-ended-autoclose.txt"
}
EOF
    die "terminal ended-process auto-close smoke failed; see $run_dir/ui-terminal-ended-autoclose-driver-error.txt, $run_dir/ui-terminal-ended-autoclose-driver.log, and $run_dir/ui-terminal-ended-autoclose-accessibility-dump.txt"
  fi

  log "terminal ended-process auto-close smoke artifacts: $run_dir"
}

run_terminal_keyboard_shortcuts_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-keyboard-shortcuts-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-keyboard-shortcuts-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal keyboard shortcuts smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live terminal keyboard shortcuts smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal keyboard shortcuts app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-keyboard-shortcuts \
      >"$run_dir/ui-terminal-keyboard-shortcuts-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_keyboard_shortcuts_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-keyboard-shortcuts"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true

  local restore_dir="$run_dir/font-zoom-restore"
  mkdir -p "$restore_dir/screenshots"
  if [[ "$assertion_status" -eq 0 ]]; then
    log "running terminal keyboard shortcuts font zoom SQLite restore from $db"
    env -u BALAGAN_FIXTURE_PATH \
      "$executable" \
      --fixture restored-terminal-keyboard-shortcuts \
      --database "$db" \
      --state-path "$restore_dir/Balagan.state.json" \
      --artifact-dir "$restore_dir" \
      >"$restore_dir/app.log" 2>&1 &
    local restore_pid="$!"
    printf '%s\n' "$restore_pid" >"$restore_dir/app.pid"

    if wait_for_file "$restore_dir/app-ready.json" 10; then
      assert_file_contains "$restore_dir/app-ready.json" "\"fontSize\" : 14" || assertion_status=$?
      capture_screenshot "$restore_dir" "terminal-keyboard-shortcuts-font-zoom-restore"
    else
      assertion_status=1
    fi

    kill "$restore_pid" >/dev/null 2>&1 || true
    wait "$restore_pid" >/dev/null 2>&1 || true
  fi

  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-keyboard-shortcuts-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-keyboard-shortcuts-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-keyboard-shortcuts-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-keyboard-shortcuts",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-keyboard-shortcuts-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-keyboard-shortcuts-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-keyboard-shortcuts-accessibility-dump.txt"
}
EOF
    die "terminal keyboard shortcuts smoke failed; see $run_dir/ui-terminal-keyboard-shortcuts-driver-error.txt, $run_dir/ui-terminal-keyboard-shortcuts-driver.log, and $run_dir/ui-terminal-keyboard-shortcuts-accessibility-dump.txt"
  fi

  log "terminal keyboard shortcuts smoke artifacts: $run_dir"
}

run_terminal_navigation_smoke() {
  local fixture="${1:-empty-board}"
  local fixture_file
  fixture_file="$(fixture_path "$fixture")"
  validate_json_file "$fixture_file"

  mkdir -p /tmp/balagan-harness-smoke

  local run_dir
  local db
  run_dir="$(make_run_dir terminal-navigation-smoke "$fixture")"
  db="$(seed_fixture_database "$fixture" "$fixture_file" "$run_dir")"
  write_run_contract terminal-navigation-smoke "$fixture" "$fixture_file" "$db" "$run_dir"

  if ! run_build; then
    log "build failed; terminal navigation smoke skipped"
    return 1
  fi

  local executable=""
  executable="$(discover_swiftpm_executable || true)"
  [[ -n "$executable" ]] || die "SwiftPM executable not found after build"

  local ui_driver=""
  ui_driver="$(discover_swiftpm_ui_driver || true)"
  [[ -n "$ui_driver" ]] || die "SwiftPM UI driver not found after build"

  unset BALAGAN_DISABLE_REAL_PROCESSES
  export BALAGAN_FIXTURE_PATH="$fixture_file"
  export BALAGAN_SQLITE_PATH="$db"
  export BALAGAN_STATE_PATH="$run_dir/Balagan.state.json"
  export BALAGAN_UI_TEST_ARTIFACT_DIR="$run_dir"
  export BALAGAN_RECORD_SELECTED_RESUME=0
  export BALAGAN_FREEZE_TIME

  log "running live terminal navigation persistence smoke with fixture $fixture"
  "$executable" \
    --fixture "$fixture" \
    --fixture-path "$fixture_file" \
    --database "$db" \
    --state-path "$run_dir/Balagan.state.json" \
    --artifact-dir "$run_dir" \
    >"$run_dir/app.log" 2>&1 &
  local app_pid="$!"
  printf '%s\n' "$app_pid" >"$run_dir/app.pid"

  if ! wait_for_file "$run_dir/app-ready.json" 10; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
    die "terminal navigation app did not write app-ready.json; see $run_dir/app.log"
  fi

  local assertion_status=0
  assert_file_contains "$run_dir/app-ready.json" "\"terminalBackend\"" || assertion_status=$?
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_file_contains "$run_dir/app-ready.json" "\"kind\" : \"libghostty\"" || assertion_status=$?
  fi

  if [[ "$assertion_status" -eq 0 ]]; then
    "$ui_driver" \
      --pid "$app_pid" \
      --artifact-dir "$run_dir" \
      --flow terminal-navigation \
      >"$run_dir/ui-terminal-navigation-driver.log" 2>&1 || assertion_status=$?
  fi
  if [[ "$assertion_status" -eq 0 ]]; then
    assert_terminal_navigation_driver_artifact "$run_dir" || assertion_status=$?
  fi

  sleep 1
  capture_screenshot "$run_dir" "terminal-navigation"

  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" >/dev/null 2>&1 || true
  if [[ "$assertion_status" -ne 0 ]]; then
    if [[ -f "$run_dir/ui-terminal-navigation-driver-error.txt" ]]; then
      cat "$run_dir/ui-terminal-navigation-driver-error.txt" >&2
    fi
    cat >"$run_dir/ui-terminal-navigation-failure.json" <<EOF
{
  "schemaVersion": 1,
  "flow": "native-accessibility-terminal-navigation-persistence",
  "status": "failed",
  "driverExitStatus": $assertion_status,
  "errorArtifact": "$run_dir/ui-terminal-navigation-driver-error.txt",
  "logArtifact": "$run_dir/ui-terminal-navigation-driver.log",
  "accessibilityDumpArtifact": "$run_dir/ui-terminal-navigation-accessibility-dump.txt",
  "beforeNavigationMarkerArtifact": "$run_dir/terminal-navigation-before.txt",
  "afterNavigationStateArtifact": "$run_dir/terminal-navigation-after.txt"
}
EOF
    die "terminal navigation smoke failed; see $run_dir/ui-terminal-navigation-driver-error.txt, $run_dir/ui-terminal-navigation-driver.log, and $run_dir/ui-terminal-navigation-accessibility-dump.txt"
  fi

  log "terminal navigation smoke artifacts: $run_dir"
}

run_lint() {
  validate_fixtures
  bash -n "$ROOT"/scripts/*.sh
  log "shell syntax validated"
}

command="${1:-}"
shift || true

case "$command" in
  build)
    run_build "$@"
    ;;
  test)
    run_test "$@"
    ;;
  ui-test)
    run_ui_test "$@"
    ;;
  ui-controls-smoke)
    run_ui_controls_smoke "$@"
    ;;
  ui-flow-smoke)
    run_ui_flow_smoke "$@"
    ;;
  ui-native-flow-smoke)
    run_ui_native_flow_smoke "$@"
    ;;
  ui-daily-driver-smoke)
    run_ui_daily_driver_smoke "$@"
    ;;
  terminal-input-smoke)
    run_terminal_input_smoke "$@"
    ;;
  terminal-manual-input-smoke)
    run_terminal_manual_input_smoke "$@"
    ;;
  terminal-visible-typing-smoke)
    run_terminal_visible_typing_smoke "$@"
    ;;
  terminal-control-keys-smoke)
    run_terminal_control_keys_smoke "$@"
    ;;
  terminal-close-open-prompt-smoke)
    run_terminal_close_open_prompt_smoke "$@"
    ;;
  terminal-ended-autoclose-smoke)
    run_terminal_ended_autoclose_smoke "$@"
    ;;
  terminal-keyboard-shortcuts-smoke)
    run_terminal_keyboard_shortcuts_smoke "$@"
    ;;
  terminal-navigation-smoke)
    run_terminal_navigation_smoke "$@"
    ;;
  terminal-state-smoke)
    run_terminal_state_smoke "$@"
    ;;
  terminal-restart-resume-smoke)
    run_terminal_restart_resume_smoke "$@"
    ;;
  agent-reopen-smoke)
    run_agent_reopen_smoke "$@"
    ;;
  hook-smoke)
    run_hook_smoke "$@"
    ;;
  hook-lifecycle-smoke)
    run_hook_lifecycle_smoke "$@"
    ;;
  agent-wrapper-smoke)
    run_agent_wrapper_smoke "$@"
    ;;
  terminal-reload-prompt-smoke)
    run_terminal_reload_prompt_smoke "$@"
    ;;
  ui-debug)
    run_ui_debug "$@"
    ;;
  normal-store-smoke)
    run_normal_store_smoke "$@"
    ;;
  first-run-smoke)
    run_first_run_smoke "$@"
    ;;
  live-backend-smoke)
    run_live_backend_smoke "$@"
    ;;
  lint)
    run_lint "$@"
    ;;
  validate-fixtures)
    validate_fixtures "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    [[ -n "$command" ]] || exit 1
    die "unknown command: $command"
    ;;
esac

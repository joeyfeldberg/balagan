#!/bin/zsh
# Regenerates the README screenshots in docs/images from a demo board (headless, in-process snapshots).
# Run from the repo root after `swift build`, outside any sandbox that blocks the window server.
set -e
APP=.build/debug/BalaganApp
W=/tmp/tbshots; rm -rf $W; mkdir -p $W
IMAGES=docs/images

# Launches the app on a state file and waits for its in-process snapshot.
snap() {
  local name=$1 state=$2; shift 2
  cp $state $W/$name-state.json
  env "$@" $APP --ui-test-mode --state-path $W/$name-state.json \
    --control-socket /tmp/tbs-$name.sock --artifact-dir $W/$name >$W/$name.log 2>&1 &
  local pid=$!
  for i in $(seq 1 80); do [ -f $W/$name/screenshots/board-app.png ] && break; sleep 0.25; done
  sleep 1.5; kill $pid 2>/dev/null || true
}

# Any valid snapshot works as the base; the default fixture writes one.
snap base /dev/null
python3 docs/screenshots/fixtures.py $W/base-state.json $W $W/acme-api
zsh docs/screenshots/sample-repo.sh $W/acme-api

ACTIVITY=(BALAGAN_FIXTURE_AGENT_STATES=1 BALAGAN_FIXTURE_AGENT_STATES_FILE=$W/activity.json
  BALAGAN_FIXTURE_USAGE=1 BALAGAN_FIXTURE_PORTS=1 BALAGAN_FIXTURE_TOKENS=1)
snap board $W/board.json $ACTIVITY
snap task $W/task.json $ACTIVITY
snap changes $W/changes.json $ACTIVITY BALAGAN_SHOW_CHANGES=1 BALAGAN_CHANGES_FILE=src/auth/routes.ts
snap palette $W/task.json $ACTIVITY BALAGAN_SHOW_COMMAND_PALETTE=1

for name in board task changes palette; do
  out=$name; [ $name = task ] && out=workspace
  sips -Z 1600 $W/$name/screenshots/board-app.png --out $IMAGES/$out.png >/dev/null
done
# Close-ups from the 2960×1800 board: the Doing column's cards, and the sidebar.
swift docs/screenshots/crop.swift $W/board/screenshots/board-app.png $IMAGES/cards.png 1118 200 600 800
swift docs/screenshots/crop.swift $W/board/screenshots/board-app.png $IMAGES/sidebar.png 0 0 482 920
sips -Z 256 Sources/BalaganApp/Resources/AppIcon.png --out $IMAGES/icon.png >/dev/null
echo "wrote $IMAGES"

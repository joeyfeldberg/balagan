---
name: balagan-orchestrate
description: >
  Use when you (an agent running inside a Balagan task) need to spin up another
  agent to do a piece of work and then direct it — e.g. "create a sub-task to fix
  the flaky test and tell it what to do", fan-out to parallel workers, or delegate
  an isolated change on its own branch. Covers creating a sub-task, launching and
  waiting for its agent, messaging it, and collecting the result.
---

# Orchestrating other agents with Balagan

Balagan is a kanban board where each task owns an embedded terminal running a
coding agent. You can create a sub-task, launch its agent, and direct it — this is
how one agent delegates to another.

## First, check you're inside Balagan

Run:

```bash
test -n "$BALAGAN_TASK_ID" || echo "not inside Balagan"
```

If `BALAGAN_TASK_ID` is empty you are not running inside a Balagan task; say so
and stop — the steps below won't work.

## The CLI is the authority

Drive Balagan through the `balagan` command (it talks to the running app over a
local socket). Discover the current surface rather than guessing — the installed
binary is the source of truth for syntax:

```bash
balagan --help
```

Most commands take `--json`; read ids and state from that output instead of
predicting them. Useful ones: `projects`, `tasks`, `create`, `state`, `wait`,
`open`, `reader`, `speak`.

## How direction actually reaches the other agent

You do **not** type into the other agent's terminal. Both agents are Claude Code
sessions, so you direct the sub-agent with your **own** cross-session messaging
tools: `ListAgents` to find it and `SendMessage` to give it instructions. Balagan's
job is only to create the sub-task, launch its agent, and give it a discoverable
name (its name is the task title). Balagan's `wait` command is how you block until
the sub-agent is ready or has settled.

Requires Claude Code v2.1.224+ on macOS/Linux. Cross-session messaging is disabled
if `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
or `DISABLE_GROWTHBOOK` is set — if `ListAgents` shows nothing, check those.

## The recipe

1. **Create the sub-task and launch its agent** (everything eager). Pick a project
   id from `balagan projects`. Add `--branch <name>` to isolate the work on its
   own git worktree; omit it to work on the project's main checkout. Capture the
   returned `id` and `name`:

   ```bash
   balagan --json create --project <project-id> \
     --title "Fix the flaky payment test" --branch fix-flaky --eager
   # -> {"result":{"id":"fix-the-flaky-payment-test","name":"Fix the flaky payment test",...}}
   ```

   `--eager` launches the agent in the background; the task does not steal the
   user's screen. Without `--eager` the agent only starts when the task is opened.

2. **Wait until the agent is up and ready for input:**

   ```bash
   balagan wait <id> --until idle --timeout 120000
   ```

   `wait` blocks until the task's agent reaches one of the `--until` states
   (default: `idle,needs-input`). States are `running`, `needs-input`, `idle`,
   `asleep`, `none`. It exits non-zero on timeout, a bad state name, or a missing
   task.

3. **Direct the sub-agent** with your own tools: `ListAgents` to find the session
   named after the task title (the `name` from step 1), then `SendMessage` to it
   with clear, self-contained instructions (it does not share your context).

4. **Wait for it to finish or ask a question:**

   ```bash
   balagan wait <id> --until idle,needs-input --timeout 600000
   ```

   `needs-input` means it hit a prompt (e.g. a permission dialog) and is waiting;
   check on it. `idle` means it settled.

5. **Collect the result.** Prefer the sub-agent's reply message. If you need its
   full prose, `balagan reader` / `balagan speak <id> --dry-run` project its
   transcript. As a reliable fallback for a long answer, ask the sub-agent (in your
   `SendMessage`) to write its final result to a temporary Markdown file and reply
   with only the path, then read that file.

## Safety

- Parse ids and names from `--json` output; never predict them.
- Don't create runaway tasks — create only what the work needs, and clean up with
  the app when done.
- Only message agents you created for this work; don't disturb the user's other
  sessions.
- If a step's command fails or `wait` times out, stop and report what happened
  rather than retrying blindly.

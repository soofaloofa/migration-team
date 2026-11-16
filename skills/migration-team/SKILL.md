---
name: migration-team
description: Plans a migration with an architect, then runs an autonomous team of test writers, issue finders, and fixers for hours or days until the migration is complete. Input is the migration task, or `resume <run-id>`, or `status [run-id]`.
---

You are the **lead**. You set the migration up with the user, then hand over
to a long-running driver script. You do not do the migration work yourself,
and you do not stay in the loop: the driver runs headless agent sessions on
its own and keeps all state on disk.

How the team works: the legacy system is the oracle. Test writers record its
real behavior as fidelity tests. Issue finders replay them against the new
system and file issues grouped by root cause. Fixers each take one issue in
their own git worktree. A merge gate lets a fix in only if it builds, passes
its tests, and regresses nothing. Details: `README.md`.

## Inputs

- No arguments: do not start anything and do not guess a task. List the runs
  in `.migration/*/` (run ID plus the status line from `progress.md`, or
  "set up, not started") and ask whether to resume one, check status, or
  start a new migration. If there are no runs, ask for the task, the legacy
  path (if legacy is another repo) and an optional brief.
- Unrecognized `--flags`: stop and ask rather than treating them as part of
  the task.
- `<task>`: start a new migration (below). Run it from the **target** repo.
  Optional `--legacy <path>` (legacy system's repo, when it is not this one)
  and `--base <branch>` (start from existing work instead of the default
  branch). If the legacy system is in another repo and `--legacy` is missing,
  ask for the path. Optional `--brief <path>`: a markdown file of facts the
  architect should treat as authoritative (see `examples/prf/brief.md`).
- `resume <run-id>`: skip to Step 5.
- `status [run-id]`: read `.migration/<run-id>/progress.md` (latest run if
  omitted), report it, and stop.

## Step 1: Preflight

Check, and stop with a clear message if any fails: inside a git repo with a
clean working tree; the `--legacy` path exists and is a git repo; `claude` and `caffeinate` (macOS) or `systemd-inhibit`
on PATH; `~/.claude/agents/` has `migration-architect.md`, `test-writer.md`,
`issue-finder.md`, `fixer.md`. The scripts live in `scripts/` next to this
file: resolve its absolute path as `$SCRIPTS`.

## Step 2: Set up the run

- **Run ID**: `<slug>-<YYYYMMDD-HHMMSS>`, slug is a kebab-case summary of at
  most 4 words.
- **Base branch**: `--base` if given, else
  `git symbolic-ref --short refs/remotes/origin/HEAD`, else the current
  branch. Never go looking for earlier attempts or other branches to build
  on; start from existing work only when `--base` or the brief says to.

```bash
RUN_DIR=".migration/<run-id>"
mkdir -p "$RUN_DIR/logs"
EXCL="$(git rev-parse --git-path info/exclude)"
grep -qx '.migration/' "$EXCL" 2>/dev/null || echo '.migration/' >> "$EXCL"
git worktree add -b "migration/<run-id>" "$RUN_DIR/wt/integration" <base>
```

If `--brief` was given, copy it to `$RUN_DIR/brief.md`.

## Step 3: Architect

Spawn the `migration-architect` agent with this run context and wait for it:

```
Run context
- Task: {task}
- Base branch: {base}
- Run ID: {run-id}
- Run dir: .migration/{run-id}
- Integration worktree: .migration/{run-id}/wt/integration (branch migration/{run-id})
- Legacy checkout: {legacy path, or "same repo"} (commit {sha})
- Brief: .migration/{run-id}/brief.md (or "none")
```

It must leave `plan.md`, `areas.txt`, `config.env`, `tests/FORMAT.md` and
`tests/run.sh` in the run dir. If any is missing, or it reported a blocker,
show the user and stop.

## Step 4: Confirm with the user

This is the only human checkpoint. Summarize `plan.md` (scope, area count,
target design in a few lines). Show `config.env`. Then smoke-test the
setup yourself in `wt/integration`: run `BUILD_CMD` and the fidelity runner
once; the runner must exit 0 and write valid `PASS`/`FAIL` lines.

Ask the user (AskUserQuestion) to confirm or change:

- Plan, scope, out-of-scope list and divergences: OK to proceed? These
  decide what "correct" means for the whole run, so surface them plainly.
- `PARALLELISM` (default 4) and `MAX_HOURS` (default 72).
- Permissions: the default runs headless agents with
  `--permission-mode acceptEdits` and an allowlist of
  `Bash,Read,Edit,Write,Glob,Grep`, which lets them run any shell command.
  Say so plainly. Offer `--yolo` (skips all prompts) only if they ask for
  it. Recommend running on a machine or container without access to
  production credentials.

Write any changes into `config.env`.

## Step 5: Launch

Refuse if `.migration/<run-id>/state/driver.pid` names a live process.
Start the driver detached so it outlives this session, keeping the Mac awake:

```bash
nohup caffeinate -i bash "$SCRIPTS/run.sh" <run-id> \
  > ".migration/<run-id>/logs/driver.log" 2>&1 &
```

Then tell the user, briefly:

- Watch: `cat .migration/<run-id>/progress.md`, `tail -f .migration/<run-id>/logs/driver.log`
- Stop gracefully: `touch .migration/<run-id>/STOP`
- Resume after a crash or reboot: `/migration-team resume <run-id>`
- Result: branch `migration/<run-id>`, final report in `REPORT.md`. Nothing is
  pushed or merged into the base branch; review it yourself.
- Issues the team could not fix land in `issues/blocked/`.

Do not poll or wait. You are done once the driver is running.

#!/usr/bin/env bash
# Autonomous migration driver. Run from the repo root.
#   run.sh <run-id> [--dry-run] [--yolo]
# Loops rounds of: test writers -> run suite -> issue finder -> fixers (+ merge gate)
# until the migration is complete, STOP exists, or a limit is hit.
# All state is on disk under .migration/<run-id>/, so rerunning resumes.
#   --dry-run  print what would run, change nothing
#   --yolo     run agents with --dangerously-skip-permissions
set -uo pipefail

RUN_ID="${1:?usage: run.sh <run-id> [--dry-run] [--yolo]}"; shift
DRY_RUN=0; YOLO=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --yolo) YOLO=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$REPO" || exit 2

STARTED=$(date +%s)
LEDGER="$RUN_DIR/ledger.jsonl"
RESULTS="$RUN_DIR/state/results-round.txt"
BASELINE="$RUN_DIR/state/baseline-pass.txt"
ROUND=0

# ---------- agents ----------

# run_agent <role> <cwd> <logfile> <prompt>
# Fresh headless session per call. Retries after a pause when the account is rate limited.
run_agent() {
  local role=$1 cwd=$2 logf=$3 prompt=$4 try rc
  local flags=(-p --agent "$role" --output-format json --max-budget-usd "$AGENT_BUDGET_USD" --add-dir "$RUN_DIR")
  [ "$LEGACY_DIR" != "$INT" ] && flags+=(--add-dir "$LEGACY_DIR")
  if [ "$YOLO" = 1 ]; then
    flags+=(--dangerously-skip-permissions)
  else
    flags+=(--permission-mode "$PERMISSION_MODE" --allowedTools "$ALLOWED_TOOLS")
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] (cd $cwd && claude ${flags[*]} <<< prompt)  # $role"; return 0
  fi
  for try in 1 2 3; do
    (cd "$cwd" && printf '%s' "$prompt" | claude "${flags[@]}") > "$logf" 2>&1 &
    local pid=$! wd
    ( sleep $((AGENT_TIMEOUT_MIN * 60)); pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) &
    wd=$!
    wait "$pid"; rc=$?
    pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null
    [ $rc -ge 128 ] && echo "agent session killed (timeout ${AGENT_TIMEOUT_MIN}m?)" >> "$logf"
    if [ $rc -ne 0 ] && grep -qiE 'rate.?limit|usage limit|overloaded|429' "$logf"; then
      log "$role hit a limit; sleeping ${RATE_LIMIT_SLEEP}s (try $try/3)"
      sleep "$RATE_LIMIT_SLEEP"; continue
    fi
    return $rc
  done
  return 1
}

# run_parallel <fn> <items...>: run fn on each item, PARALLELISM at a time.
run_parallel() {
  local fn=$1 n=0 item limit="${PAR:-$PARALLELISM}"; shift
  for item in "$@"; do
    "$fn" "$item" &
    n=$((n + 1))
    if [ "$n" -ge "$limit" ]; then wait; n=0; fi
  done
  wait
}

# ---------- recovery ----------

recover() {
  local f d b
  for f in "$RUN_DIR"/issues/claimed/*.md; do [ -e "$f" ] && mv "$f" "$RUN_DIR/issues/open/"; done
  rm -rf "$RUN_DIR"/state/*.lock
  for d in "$RUN_DIR"/wt/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = integration ] && continue
    git worktree remove --force "$d" 2>/dev/null || rm -rf "$d"
  done
  git worktree prune
  for b in $(git for-each-ref --format='%(refname:short)' "refs/heads/fix/$RUN_ID/"); do git branch -D -q "$b"; done
  if [ ! -d "$INT" ]; then
    git worktree add -q "$INT" "$INTBR" || { echo "cannot create integration worktree" >&2; exit 2; }
    setup_worktree "$INT"
  fi
}

# ---------- legacy system lifecycle ----------
# Test writers observe the real legacy system. If it needs to be running, the driver
# starts it before the writer phase and stops it after, so nothing is left up for days.

legacy_up() {
  [ -n "${LEGACY_START_CMD:-}" ] || return 0
  log "starting legacy system"
  (cd "$LEGACY_DIR" && exec bash -c "$LEGACY_START_CMD") > "$LOGS/legacy.log" 2>&1 &
  echo $! > "$RUN_DIR/state/legacy.pid"
  disown $! 2>/dev/null   # so run_parallel's bare `wait` does not block on it
  local i=0
  while [ $((i * 2)) -lt "$LEGACY_READY_TIMEOUT" ]; do
    (cd "$LEGACY_DIR" && bash -c "${LEGACY_READY_CMD:-true}") >/dev/null 2>&1 && return 0
    sleep 2; i=$((i + 1))
  done
  log "legacy system not ready after ${LEGACY_READY_TIMEOUT}s; see $LOGS/legacy.log"
  legacy_down; return 1
}

legacy_down() {
  [ -n "${LEGACY_START_CMD:-}" ] || return 0
  [ -n "${LEGACY_STOP_CMD:-}" ] && (cd "$LEGACY_DIR" && bash -c "$LEGACY_STOP_CMD") >> "$LOGS/legacy.log" 2>&1
  local pid; pid=$(cat "$RUN_DIR/state/legacy.pid" 2>/dev/null)
  if [ -n "$pid" ]; then pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; rm -f "$RUN_DIR/state/legacy.pid"; fi
  return 0
}

# ---------- test writers ----------

areas() { grep -v '^[[:space:]]*\(#\|$\)' "$RUN_DIR/areas.txt" 2>/dev/null; }
area_passes() { ls "$RUN_DIR/state/areas/$1".* 2>/dev/null | wc -l | tr -d ' '; }

pending_areas() {
  local a target=$((1 + COVERAGE_PASSES))
  for a in $(areas); do
    [ "$(area_passes "$a")" -lt "$target" ] && echo "$a"
  done
}

write_area() {
  local a=$1 pass=$(( $(area_passes "$1") + 1 ))
  local prompt="Write fidelity tests for area '$a' (pass $pass of $((1 + COVERAGE_PASSES))).
Run dir: $RUN_DIR
Read $RUN_DIR/plan.md and $RUN_DIR/tests/FORMAT.md first.
Tests go in $RUN_DIR/tests/$a/ only.
Legacy system checkout (your current directory): $LEGACY_DIR${LEGACY_URL:+
Legacy system URL: $LEGACY_URL (the driver started it; it is shared with other writers, so use names unique to your area/tests and clean up what you create)}
Do not modify tracked files in any repo.
$( [ "$pass" -gt 1 ] && echo "Earlier passes already wrote tests for this area. Read them, then add tests for behavior they miss: edge cases, error paths, ordering, limits, encodings." )"
  if run_agent test-writer "$LEGACY_DIR" "$LOGS/r$ROUND-test-writer-$a.log" "$prompt"; then
    touch "$RUN_DIR/state/areas/$a.$(date +%s)-$$"
  else
    local f="$RUN_DIR/state/attempts/area-$a"
    local n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
    if [ "$n" -ge 3 ]; then
      log "test-writer for $a failed $n times; skipping this pass"
      touch "$RUN_DIR/state/areas/$a.$(date +%s)-$$"; echo 0 > "$f"
    fi
  fi
}

# ---------- issue finder ----------

covered_ids() {
  local d f
  for d in open claimed blocked; do
    for f in "$RUN_DIR"/issues/$d/*.md; do [ -e "$f" ] && issue_tests "$f"; done
  done | LC_ALL=C sort -u
}

find_issues() {
  local uncovered="$RUN_DIR/state/uncovered.txt" t
  LC_ALL=C comm -23 <(fail_ids "$RESULTS") <(covered_ids) > "$uncovered"
  [ -s "$uncovered" ] || return 0
  log "$(wc -l < "$uncovered" | tr -d ' ') failing tests have no issue; running issue-finder"
  run_agent issue-finder "$INT" "$LOGS/r$ROUND-issue-finder.log" \
"File issues for failing fidelity tests.
Run dir: $RUN_DIR
Suite results: $RESULTS (logs next to it: $RESULTS.log, $RESULTS.build.log)
Failing tests with no issue yet: $uncovered
Open/claimed/blocked issues are in $RUN_DIR/issues/. Do not duplicate them.
Integration checkout (read-only for you): $INT
Legacy source (read-only reference): $LEGACY_DIR"
  # Backstop: anything still uncovered gets a plain one-test issue.
  LC_ALL=C comm -23 <(fail_ids "$RESULTS") <(covered_ids) > "$uncovered"
  while read -r t; do
    [ -z "$t" ] && continue
    printf -- '---\nid: auto-%s\ntests: %s\narea: unknown\n---\n# Test %s fails\nAuto-filed. Reproduce with the fidelity suite and find the root cause.\n' \
      "$(echo "$t" | tr -c 'A-Za-z0-9\n' '-')" "$t" "$t" \
      > "$RUN_DIR/issues/open/auto-$(echo "$t" | tr -c 'A-Za-z0-9\n' '-').md"
  done < "$uncovered"
}

# ---------- fixers ----------

fixer_prompt() { # id attempt
  local id=$1 attempt=$2
  cat <<EOF
Fix issue $id (attempt $attempt of $MAX_FIX_ATTEMPTS).
Issue file: $RUN_DIR/issues/claimed/$id.md
Plan: $RUN_DIR/plan.md
Fidelity tests (READ-ONLY, any change is rejected): $RUN_DIR/tests/
Your worktree (current directory): $RUN_DIR/wt/$id on branch fix/$RUN_ID/$id
Integration branch: $INTBR
Legacy source (read-only reference for the behavior you are porting): $LEGACY_DIR
This repo's own AGENTS.md/CLAUDE.md rules apply to your change: read them, and add the repo-native unit tests it requires.
Commit message prefix: [$(sed -n 's/^area:[[:space:]]*//p' "$RUN_DIR/issues/claimed/$id.md" | head -1)]
Build: $BUILD_CMD
Run the suite: FIDELITY_DIR=$RUN_DIR/tests RESULTS_FILE=/tmp/$RUN_ID-$id.txt bash -c '$FIDELITY_CMD'
$( [ "$attempt" -gt 1 ] || [ -s "$LOGS/gate-$id.log" ] && echo "The merge gate rejected the previous attempt. Read its log first: $LOGS/gate-$id.log" )
Commit your fix on this branch. Do not merge; the gate does that.
EOF
}

work_issue() {
  local id=$1
  local claimed="$RUN_DIR/issues/claimed/$id.md" wt="$RUN_DIR/wt/$id" br="fix/$RUN_ID/$id"
  mv "$RUN_DIR/issues/open/$id.md" "$claimed" 2>/dev/null || return 0   # another worker took it
  rm -f "$LOGS/gate-$id.log"

  lock_acquire worktree && { git worktree add -q -b "$br" "$wt" "$INTBR" 2>>"$LOGS/driver-git.log"; lock_release worktree; }
  if [ ! -d "$wt" ] || ! setup_worktree "$wt"; then
    log "could not create worktree for $id"; rm -rf "$wt"; git worktree prune
    mv "$claimed" "$RUN_DIR/issues/open/"; return 0
  fi

  local attempt=0 ok=0
  while [ "$attempt" -lt "$MAX_FIX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    run_agent fixer "$wt" "$LOGS/r$ROUND-fixer-$id-$attempt.log" "$(fixer_prompt "$id" "$attempt")"
    if bash "$SCRIPT_DIR/gate.sh" "$RUN_ID" "$id" > "$LOGS/r$ROUND-gate-$id-$attempt.out" 2>&1; then ok=1; break; fi
  done

  lock_acquire worktree && {
    git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git branch -D -q "$br" 2>/dev/null
    lock_release worktree
  }

  if [ "$ok" = 1 ]; then
    rm -f "$RUN_DIR/state/attempts/$id"; log "resolved $id"
  else
    local n=$(( $(cat "$RUN_DIR/state/attempts/$id" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$RUN_DIR/state/attempts/$id"
    printf '\n## Round %s attempt failed (%s of %s)\n```\n%s\n```\n' "$ROUND" "$n" "$MAX_ISSUE_ATTEMPTS" \
      "$(tail -30 "$LOGS/gate-$id.log" 2>/dev/null)" >> "$claimed"
    if [ "$n" -ge "$MAX_ISSUE_ATTEMPTS" ]; then
      mv "$claimed" "$RUN_DIR/issues/blocked/"; log "blocked $id after $n failed rounds"
    else
      mv "$claimed" "$RUN_DIR/issues/open/"; log "reopened $id (failed round $n of $MAX_ISSUE_ATTEMPTS)"
    fi
  fi
}

# ---------- bookkeeping ----------

record() { # writes ledger line + progress.md; sets globals PASS FAIL OPEN BLOCKED RESOLVED PENDING
  PASS=$(grep -c '^PASS ' "$RESULTS"); FAIL=$(grep -c '^FAIL ' "$RESULTS")
  OPEN=$(( $(count_md "$RUN_DIR/issues/open") + $(count_md "$RUN_DIR/issues/claimed") ))
  BLOCKED=$(count_md "$RUN_DIR/issues/blocked"); RESOLVED=$(count_md "$RUN_DIR/issues/resolved")
  PENDING=$(pending_areas | wc -l | tr -d ' ')
  [ -n "${STATUS:-}" ] || printf '{"round":%s,"ts":"%s","pass":%s,"fail":%s,"open":%s,"blocked":%s,"resolved":%s,"areas_pending":%s}\n' \
    "$ROUND" "$(date -u +%FT%TZ)" "$PASS" "$FAIL" "$OPEN" "$BLOCKED" "$RESOLVED" "$PENDING" >> "$LEDGER"
  {
    echo "# Migration $RUN_ID"
    echo; echo "Status: ${STATUS:-running}. Round $ROUND, $(( ($(date +%s) - STARTED) / 60 )) min this session."
    echo "Integration branch: \`$INTBR\`"
    echo; echo "| pass | fail | open issues | blocked | resolved | areas pending |"
    echo "| --- | --- | --- | --- | --- | --- |"
    echo "| $PASS | $FAIL | $OPEN | $BLOCKED | $RESOLVED | $PENDING |"
    if [ "$BLOCKED" -gt 0 ]; then echo; echo "## Blocked issues (need a human)"; ls "$RUN_DIR"/issues/blocked/ | sed 's/^/- /'; fi
    echo; echo "## Recent rounds"; tail -15 "$LEDGER" | sed 's/^/    /'
  } > "$RUN_DIR/progress.md"
}

finish() { # <status> [exit code]
  STATUS="$1"; legacy_down; record
  cp "$RUN_DIR/progress.md" "$RUN_DIR/REPORT.md"
  log "finished: $STATUS"; rm -f "$RUN_DIR/state/driver.pid"; exit "${2:-0}"
}

# ---------- main ----------

if [ "$DRY_RUN" = 1 ]; then
  echo "run: $RUN_ID  repo: $REPO"
  echo "parallelism: $PARALLELISM  max hours: $MAX_HOURS  build: ${BUILD_CMD:-<none>}"
  echo "pending areas: $(pending_areas | tr '\n' ' ')"
  echo "open issues: $(count_md "$RUN_DIR/issues/open")  blocked: $(count_md "$RUN_DIR/issues/blocked")"
  for a in $(pending_areas | head -1); do write_area "$a"; done
  exit 0
fi

if [ -f "$RUN_DIR/state/driver.pid" ] && kill -0 "$(cat "$RUN_DIR/state/driver.pid")" 2>/dev/null; then
  echo "driver already running (pid $(cat "$RUN_DIR/state/driver.pid"))" >&2; exit 1
fi
echo $$ > "$RUN_DIR/state/driver.pid"
trap 'log "interrupted"; legacy_down; kill $(jobs -p) 2>/dev/null; rm -f "$RUN_DIR/state/driver.pid"; exit 130' INT TERM

recover
log "driver started for $RUN_ID (pid $$)"

CLEAN=0; STALLED=0; BEST=-1
while :; do
  [ -e "$RUN_DIR/STOP" ] && finish "stopped by user (STOP file)"
  [ $(( ($(date +%s) - STARTED) / 3600 )) -ge "$MAX_HOURS" ] && finish "stopped: MAX_HOURS reached" 1
  [ "$ROUND" -ge "$MAX_ROUNDS" ] && finish "stopped: MAX_ROUNDS reached" 1
  ROUND=$((ROUND + 1)); log "round $ROUND"

  # A. test writers extend the oracle.
  # shellcheck disable=SC2046
  if [ -n "$(pending_areas)" ]; then
    if legacy_up; then PAR=$WRITER_PARALLELISM run_parallel write_area $(pending_areas); fi
    legacy_down
  fi

  # B. replay the suite on the integration branch; file issues for new failures.
  if ! build_and_suite "$INT" "$RESULTS"; then
    log "fidelity harness error, see $RESULTS.log"; : > "$RESULTS"
    STALLED=$((STALLED + 1))
  fi
  find_issues
  record
  log "pass=$PASS fail=$FAIL open=$OPEN blocked=$BLOCKED resolved=$RESOLVED pending_areas=$PENDING"

  # Complete: every area covered, tests exist, all green, nothing open. Two clean rounds in a row.
  if [ "$PENDING" -eq 0 ] && [ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ] && [ "$OPEN" -eq 0 ]; then
    CLEAN=$((CLEAN + 1))
    if [ "$CLEAN" -ge 2 ]; then
      [ "$BLOCKED" -gt 0 ] && finish "complete, but $BLOCKED blocked issues need a human" || finish "complete"
    fi
    continue
  fi
  CLEAN=0

  # C. fixers, one issue each, in worktrees; the gate merges.
  mkdir -p "$RUN_DIR/state/tests-golden"
  rsync -a --delete "$RUN_DIR/tests/" "$RUN_DIR/state/tests-golden/"
  hash_tests > "$RUN_DIR/state/tests.hash"
  ids=$(ls "$RUN_DIR"/issues/open/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//')
  # shellcheck disable=SC2086
  [ -n "$ids" ] && run_parallel work_issue $ids

  # Stall guard: progress = tests passing + issues closed + area passes done.
  score=$(( $(grep -c '^PASS ' "$RESULTS") + $(count_md "$RUN_DIR/issues/resolved") + $(count_md "$RUN_DIR/issues/blocked") + $(ls "$RUN_DIR"/state/areas | wc -l) ))
  if [ "$score" -gt "$BEST" ]; then BEST=$score; STALLED=0; else STALLED=$((STALLED + 1)); fi
  [ "$STALLED" -ge "$STALL_ROUNDS" ] && finish "stopped: no progress for $STALL_ROUNDS rounds" 1
done

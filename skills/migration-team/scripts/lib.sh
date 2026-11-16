#!/usr/bin/env bash
# Shared helpers for run.sh and gate.sh. Source this file; do not execute it.
# Requires RUN_ID in the environment. Works with bash 3.2 (macOS default).

export REPO="${REPO:-$(git rev-parse --show-toplevel)}"
export RUN_DIR="$REPO/.migration/$RUN_ID"
export INT="$RUN_DIR/wt/integration"
export INTBR="migration/$RUN_ID"
export LOGS="$RUN_DIR/logs"

[ -f "$RUN_DIR/config.env" ] || { echo "no config.env in $RUN_DIR" >&2; exit 2; }

set -a
# shellcheck disable=SC1091
. "$RUN_DIR/config.env"
set +a

: "${PARALLELISM:=4}"
: "${MAX_FIX_ATTEMPTS:=3}"     # fixer sessions per issue per round
: "${MAX_ISSUE_ATTEMPTS:=3}"   # failed rounds before an issue is parked as blocked
: "${COVERAGE_PASSES:=2}"      # extra test-writer passes per area after the first
: "${STALL_ROUNDS:=5}"         # rounds without progress before stopping
: "${MAX_HOURS:=72}"
: "${MAX_ROUNDS:=1000}"
: "${AGENT_BUDGET_USD:=5}"
: "${PERMISSION_MODE:=acceptEdits}"
: "${ALLOWED_TOOLS:=Bash,Read,Edit,Write,Glob,Grep}"
: "${RATE_LIMIT_SLEEP:=1800}"
: "${AGENT_TIMEOUT_MIN:=90}"       # kill an agent session that runs longer than this
: "${WRITER_PARALLELISM:=1}"      # test writers share one legacy instance; raise only if it is isolated per test
: "${LEGACY_DIR:=$INT}"           # legacy source checkout; set when the legacy system lives in another repo
: "${LEGACY_READY_TIMEOUT:=300}"

mkdir -p "$LOGS" "$RUN_DIR"/state/areas "$RUN_DIR"/state/attempts \
  "$RUN_DIR"/issues/open "$RUN_DIR"/issues/claimed "$RUN_DIR"/issues/resolved \
  "$RUN_DIR"/issues/blocked "$RUN_DIR"/tests

# setup_worktree <dir>: install deps / link caches into a fresh worktree (WORKTREE_SETUP_CMD).
setup_worktree() {
  [ -n "${WORKTREE_SETUP_CMD:-}" ] || return 0
  (cd "$1" && MAIN_REPO="$REPO" bash -c "$WORKTREE_SETUP_CMD") >> "$LOGS/worktree-setup.log" 2>&1
}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; }

# Hash of every file under tests/. Fixers must not change it.
hash_tests() {
  (cd "$RUN_DIR/tests" && find . -type f | LC_ALL=C sort | while read -r f; do sha < "$f"; echo "$f"; done | sha | cut -d' ' -f1)
}

count_md() { ls "$1"/*.md 2>/dev/null | wc -l | tr -d ' '; }

# lock_acquire <name> [tries]; spins 2s per try. Stale locks are cleared by run.sh at startup.
lock_acquire() {
  local d="$RUN_DIR/state/$1.lock" i=0 max="${2:-1800}"
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt "$max" ] && return 1
    sleep 2
  done
  echo $$ > "$d/pid"
}
lock_release() { rm -rf "$RUN_DIR/state/$1.lock"; }

# build_and_suite <dir> <results-file>
# Builds, then runs the fidelity suite in <dir>. The results file gets one
# "PASS <id>" or "FAIL <id>" line per test. A broken build yields "FAIL __build__".
# Returns 0 if the harness ran (even with failing tests), nonzero on harness error.
build_and_suite() {
  local dir=$1 out=$2
  : > "$out"
  if [ -n "${BUILD_CMD:-}" ] && ! (cd "$dir" && bash -c "$BUILD_CMD") > "$out.build.log" 2>&1; then
    echo "FAIL __build__" > "$out"
    return 0
  fi
  (cd "$dir" && FIDELITY_DIR="$RUN_DIR/tests" RESULTS_FILE="$out" bash -c "$FIDELITY_CMD") > "$out.log" 2>&1
}

pass_ids() { grep '^PASS ' "$1" | cut -d' ' -f2- | LC_ALL=C sort -u; }
fail_ids() { grep '^FAIL ' "$1" | cut -d' ' -f2- | LC_ALL=C sort -u; }

# Test ids named by an issue's "tests:" line (space separated).
issue_tests() { sed -n 's/^tests:[[:space:]]*//p' "$1" | head -1 | tr ' ' '\n' | grep -v '^$'; }

#!/usr/bin/env bash
# Merge gate. Usage: gate.sh <run-id> <issue-id>   (run from the repo root)
# A fixer's branch merges into migration/<run-id> only if it:
#   - rebases cleanly onto the integration branch
#   - builds
#   - does not change tests/
#   - passes every test the issue names
#   - regresses no test that passed on the integration branch
#   - passes GATE_EXTRA_CMD (lint, security scan, ...) if set
# Exit 0 = merged and issue resolved. Exit 1 = rejected; reason is in logs/gate-<issue>.log.
set -uo pipefail

RUN_ID="${1:?usage: gate.sh <run-id> <issue-id>}"
ISSUE="${2:?usage: gate.sh <run-id> <issue-id>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

WT="$RUN_DIR/wt/$ISSUE"
BR="fix/$RUN_ID/$ISSUE"
GLOG="$LOGS/gate-$ISSUE.log"
CLAIMED="$RUN_DIR/issues/claimed/$ISSUE.md"
RESULTS="$RUN_DIR/state/results-gate-$ISSUE.txt"
BASELINE="$RUN_DIR/state/baseline-pass.txt"

: > "$GLOG"
exec > >(tee -a "$GLOG") 2>&1

reject() { echo "GATE REJECTED: $*"; exit 1; }

[ -d "$WT" ] || reject "worktree $WT missing"
lock_acquire gate || reject "could not get the gate lock"
trap 'lock_release gate' EXIT

cd "$WT" || reject "cannot cd to $WT"

# Keep leftovers instead of losing them.
if [ -n "$(git status --porcelain)" ]; then
  git add -A && git commit -qm "Fix $ISSUE: remaining changes"
fi

[ "$(git rev-list --count "$INTBR..HEAD")" -gt 0 ] || reject "no commits on $BR; the fix is empty"

if [ "$(hash_tests)" != "$(cat "$RUN_DIR/state/tests.hash" 2>/dev/null)" ]; then
  rsync -a --delete "$RUN_DIR/state/tests-golden/" "$RUN_DIR/tests/"   # undo the tampering
  reject "tests/ was modified (now restored). Fixers must not edit fidelity tests; fix the system instead"
fi

if ! git rebase "$INTBR" >/dev/null 2>&1; then
  git rebase --abort >/dev/null 2>&1
  reject "rebase onto $INTBR conflicts. Run 'git rebase $INTBR', resolve conflicts, keep the fix, and commit"
fi

build_and_suite "$WT" "$RESULTS" || reject "fidelity harness error; see $RESULTS.log"
if grep -qx 'FAIL __build__' "$RESULTS"; then
  echo "--- build output ---"; tail -60 "$RESULTS.build.log"
  reject "build failed"
fi

# Issue's own tests must now pass.
still_failing=""
for t in $(issue_tests "$CLAIMED"); do
  grep -qx "PASS $t" "$RESULTS" || still_failing="$still_failing $t"
done
[ -z "$still_failing" ] || reject "tests named by the issue still not passing:$still_failing"

# No regressions against what the integration branch passes today.
if [ -s "$BASELINE" ]; then
  regressed="$(LC_ALL=C comm -23 "$BASELINE" <(pass_ids "$RESULTS") | tr '\n' ' ')"
  [ -z "$regressed" ] || reject "regressions (passed before, not now): $regressed"
fi

if [ -n "${GATE_EXTRA_CMD:-}" ]; then
  bash -c "$GATE_EXTRA_CMD" >"$RESULTS.extra.log" 2>&1 || { tail -40 "$RESULTS.extra.log"; reject "GATE_EXTRA_CMD failed"; }
fi

(cd "$INT" && git merge --ff-only "$BR" >/dev/null 2>&1) || reject "fast-forward merge into $INTBR failed"

pass_ids "$RESULTS" > "$BASELINE"
mv "$CLAIMED" "$RUN_DIR/issues/resolved/$ISSUE.md"
echo "GATE PASSED: $ISSUE merged into $INTBR"

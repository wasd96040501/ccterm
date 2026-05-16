#!/usr/bin/env bash
# wait-for-pr.sh — block until a GitHub PR reaches a terminal state.
#
# Designed to be run with `run_in_background` so Claude does not have to
# sleep-and-poll in the foreground (which burns prompt cache and loses
# state when the conversation is compressed).
#
# Terminal states (any one → return):
#   READY                      All checks passed, no review block, mergeable.
#   CHECKS_FAILED              At least one required-ish check ended badly.
#   CONFLICT                   PR has merge conflicts; CI signal is moot.
#   REVIEW_CHANGES_REQUESTED   Reviewer asked for changes; needs human action.
#   MERGED                     Already merged.
#   CLOSED                     Closed without merging.
#   TIMEOUT                    Hit max wall-clock budget.
#   NO_CHECKS                  No checks ever appeared within grace window.
#
# Stdout: one human summary line, then a JSON object on the next line.
# Exit codes: 0 READY|MERGED, 3 TIMEOUT, 4 CONFLICT, 5 CHECKS_FAILED,
#             6 REVIEW_CHANGES_REQUESTED, 7 CLOSED, 8 NO_CHECKS, 2 USAGE.
#
# Usage:
#   scripts/wait-for-pr.sh <pr-number>     # explicit
#   scripts/wait-for-pr.sh                 # auto-detect from current branch
#
# Env knobs:
#   WAIT_PR_TIMEOUT   max seconds to wait (default 1800 = 30min)
#   WAIT_PR_INTERVAL  poll interval seconds (default 20)
#   WAIT_PR_GRACE     seconds to allow before NO_CHECKS verdict (default 180)

set -uo pipefail

PR="${1:-}"
TIMEOUT_SEC="${WAIT_PR_TIMEOUT:-1800}"
INTERVAL_SEC="${WAIT_PR_INTERVAL:-20}"
GRACE_SEC="${WAIT_PR_GRACE:-180}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found in PATH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found in PATH" >&2
  exit 2
fi

if [[ -z "$PR" ]]; then
  PR=$(gh pr view --json number -q .number 2>/dev/null || true)
  if [[ -z "$PR" ]]; then
    echo "usage: $0 <pr-number>  (no PR found for current branch either)" >&2
    exit 2
  fi
fi

START=$(date +%s)

# Pending check status values from GitHub's GraphQL CheckStatusState +
# legacy Status API. Anything outside this set is treated as terminal.
PENDING_PATTERN='QUEUED|IN_PROGRESS|PENDING|WAITING|REQUESTED'
# Conclusion values that mean the check did not pass.
FAIL_PATTERN='FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE|STALE'

emit() {
  local terminal="$1"
  local exit_code="$2"
  local json="$3"
  local now elapsed summary
  now=$(date +%s)
  elapsed=$((now - START))
  summary=$(jq -nc \
    --arg terminal "$terminal" \
    --argjson elapsed "$elapsed" \
    --argjson pr "$PR" \
    --argjson view "$json" \
    '{
      terminal: $terminal,
      pr: $pr,
      elapsed_sec: $elapsed,
      state: $view.state,
      mergeable: $view.mergeable,
      mergeStateStatus: $view.mergeStateStatus,
      reviewDecision: ($view.reviewDecision // null),
      isDraft: $view.isDraft,
      checks: (
        ($view.statusCheckRollup // []) as $r |
        {
          total: ($r | length),
          passed:  [$r[] | select((.conclusion // "") == "SUCCESS")] | length,
          failed:  [$r[] | select((.conclusion // "") | test("^(FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE|STALE)$"))] | length,
          pending: [$r[] | select((.status // "") | test("^(QUEUED|IN_PROGRESS|PENDING|WAITING|REQUESTED)$"))] | length,
          neutral: [$r[] | select((.conclusion // "") | test("^(NEUTRAL|SKIPPED)$"))] | length
        }
      ),
      url: $view.url,
      title: $view.title
    }')
  # Human-friendly first line, then JSON.
  echo "[wait-for-pr] PR #$PR → $terminal (elapsed ${elapsed}s) — $(jq -r .url <<<"$json")"
  echo "$summary"
  exit "$exit_code"
}

FIRST_SEEN_CHECKS=0

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if (( ELAPSED >= TIMEOUT_SEC )); then
    LAST_JSON="${LAST_JSON:-{}}"
    emit "TIMEOUT" 3 "$LAST_JSON"
  fi

  if ! JSON=$(gh pr view "$PR" --json number,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,url,title 2>/dev/null); then
    sleep "$INTERVAL_SEC"
    continue
  fi
  LAST_JSON="$JSON"

  STATE=$(jq -r '.state' <<<"$JSON")
  MERGEABLE=$(jq -r '.mergeable' <<<"$JSON")
  MERGE_STATE=$(jq -r '.mergeStateStatus' <<<"$JSON")
  REVIEW=$(jq -r '.reviewDecision // ""' <<<"$JSON")
  TOTAL=$(jq '.statusCheckRollup | length' <<<"$JSON")
  PENDING=$(jq "[.statusCheckRollup[]? | select((.status // \"\") | test(\"^($PENDING_PATTERN)\$\"))] | length" <<<"$JSON")
  FAILED=$(jq "[.statusCheckRollup[]? | select((.conclusion // \"\") | test(\"^($FAIL_PATTERN)\$\"))] | length" <<<"$JSON")

  # 1. Already closed/merged — terminal regardless of CI.
  if [[ "$STATE" == "MERGED" ]]; then emit "MERGED" 0 "$JSON"; fi
  if [[ "$STATE" == "CLOSED" ]]; then emit "CLOSED" 7 "$JSON"; fi

  # 2. Conflict — CI signal becomes meaningless. Return early so the
  #    caller can resolve conflicts instead of waiting for green checks.
  if [[ "$MERGEABLE" == "CONFLICTING" || "$MERGE_STATE" == "DIRTY" ]]; then
    emit "CONFLICT" 4 "$JSON"
  fi

  # 3. Any check failed — caller needs to fix or retry; no point waiting
  #    for the rest, since required failures already block merge.
  if (( FAILED > 0 )); then
    emit "CHECKS_FAILED" 5 "$JSON"
  fi

  # 4. Checks not started yet — wait, but bail out after GRACE_SEC so we
  #    don't hang forever on a repo with no CI configured.
  if (( TOTAL == 0 )); then
    if (( ELAPSED >= GRACE_SEC )); then
      emit "NO_CHECKS" 8 "$JSON"
    fi
    sleep "$INTERVAL_SEC"
    continue
  fi
  FIRST_SEEN_CHECKS=1

  # 5. All checks settled (none pending, none failed) → look at review.
  if (( PENDING == 0 )); then
    if [[ "$REVIEW" == "CHANGES_REQUESTED" ]]; then
      emit "REVIEW_CHANGES_REQUESTED" 6 "$JSON"
    fi
    emit "READY" 0 "$JSON"
  fi

  sleep "$INTERVAL_SEC"
done

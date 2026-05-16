#!/usr/bin/env bash
# wait-for-workflow.sh — block until a GitHub Actions run reaches a terminal
# state. Designed for the dev-test loop where you trigger the debug workflow
# and wait on its outcome:
#
#   gh workflow run test-debug.yml -f filter=cctermUITests/Foo
#   scripts/wait-for-workflow.sh --workflow test-debug.yml   # blocks
#
# Run with `run_in_background: true` so Claude does not foreground-poll
# (which burns prompt cache and loses state on compression).
#
# Terminal states:
#   SUCCESS    Run completed with conclusion=success.
#   FAILURE    Run completed with any non-success conclusion (failure,
#              cancelled, timed_out, action_required, stale, startup_failure,
#              neutral, skipped).
#   TIMEOUT    Wall-clock budget elapsed before the run terminated.
#   NOT_FOUND  No matching run appeared within the grace window.
#
# Stdout: one human summary line, then a JSON object on the next line.
# Exit codes: 0 SUCCESS, 3 TIMEOUT, 5 FAILURE, 8 NOT_FOUND, 2 USAGE.
#
# Usage:
#   scripts/wait-for-workflow.sh <run-id>
#   scripts/wait-for-workflow.sh --workflow <file.yml> [--branch <branch>]
#
# --workflow mode picks the most recent run for the workflow on the given
# branch (default: current git branch). Call immediately after
# `gh workflow run` so the discovered run is the one you just triggered.
#
# Env knobs:
#   WAIT_WF_TIMEOUT   max seconds (default 1800 = 30min)
#   WAIT_WF_INTERVAL  poll interval seconds (default 15)
#   WAIT_WF_GRACE     grace seconds to discover the run (default 90)

set -uo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found in PATH" >&2; exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found in PATH" >&2; exit 2
fi

TIMEOUT_SEC="${WAIT_WF_TIMEOUT:-1800}"
INTERVAL_SEC="${WAIT_WF_INTERVAL:-15}"
GRACE_SEC="${WAIT_WF_GRACE:-90}"

RUN_ID=""
WORKFLOW=""
BRANCH=""

usage() {
  cat >&2 <<'EOF'
usage: wait-for-workflow.sh <run-id>
       wait-for-workflow.sh --workflow <file.yml> [--branch <branch>]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workflow) WORKFLOW="${2:-}"; shift 2 ;;
    --branch)   BRANCH="${2:-}";   shift 2 ;;
    -h|--help)  usage ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        RUN_ID="$1"; shift
      else
        echo "error: unknown arg '$1'" >&2
        usage
      fi
      ;;
  esac
done

if [ -z "$RUN_ID" ] && [ -z "$WORKFLOW" ]; then usage; fi

if [ -z "$RUN_ID" ] && [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -z "$BRANCH" ]; then
    echo "error: not in a git repo and no --branch given" >&2
    exit 2
  fi
fi

START=$(date +%s)
# Runs created more than 60s before script start are considered stale (the
# caller almost certainly meant the run they just triggered, not an older one).
# BSD date syntax — this script targets macOS.
THRESHOLD=$(date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
            date -u -d '-60 seconds' +"%Y-%m-%dT%H:%M:%SZ")

emit() {
  local terminal="$1" exit_code="$2" json="$3"
  local now elapsed summary url
  now=$(date +%s); elapsed=$((now - START))
  summary=$(jq -nc \
    --arg terminal "$terminal" \
    --argjson elapsed "$elapsed" \
    --argjson view "$json" \
    '{
      terminal: $terminal,
      elapsed_sec: $elapsed,
      run_id: ($view.databaseId // null),
      workflow: ($view.workflowName // null),
      status: ($view.status // null),
      conclusion: ($view.conclusion // null),
      branch: ($view.headBranch // null),
      url: ($view.url // null),
      title: ($view.displayTitle // null)
    }')
  url=$(jq -r '.url // ""' <<<"$json")
  echo "[wait-for-workflow] $terminal (elapsed ${elapsed}s) — ${url}"
  echo "$summary"
  exit "$exit_code"
}

# --- Discover the run if --workflow mode ---
if [ -z "$RUN_ID" ]; then
  while :; do
    NOW=$(date +%s); ELAPSED=$((NOW - START))
    JSON=$(gh run list \
      --workflow "$WORKFLOW" \
      --branch "$BRANCH" \
      --limit 1 \
      --json databaseId,workflowName,status,conclusion,headBranch,url,displayTitle,createdAt 2>/dev/null \
      | jq -c '.[0] // null')
    if [ "$JSON" != "null" ] && [ -n "$JSON" ]; then
      CREATED=$(jq -r '.createdAt' <<<"$JSON")
      # Lexicographic compare works for ISO 8601 UTC.
      if [[ "$CREATED" > "$THRESHOLD" ]]; then
        RUN_ID=$(jq -r '.databaseId' <<<"$JSON")
        echo "[wait-for-workflow] discovered run $RUN_ID for $WORKFLOW on $BRANCH (created $CREATED)" >&2
        break
      fi
    fi
    if (( ELAPSED >= GRACE_SEC )); then
      emit "NOT_FOUND" 8 "{}"
    fi
    sleep 3
  done
fi

# --- Poll the run ---
LAST_JSON="{}"
while :; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))
  if (( ELAPSED >= TIMEOUT_SEC )); then
    emit "TIMEOUT" 3 "$LAST_JSON"
  fi
  if ! JSON=$(gh run view "$RUN_ID" --json databaseId,workflowName,status,conclusion,headBranch,url,displayTitle 2>/dev/null); then
    sleep "$INTERVAL_SEC"
    continue
  fi
  LAST_JSON="$JSON"
  STATUS=$(jq -r '.status' <<<"$JSON")
  CONCL=$(jq -r '.conclusion // ""' <<<"$JSON")
  if [ "$STATUS" = "completed" ]; then
    case "$CONCL" in
      success) emit "SUCCESS" 0 "$JSON" ;;
      *)       emit "FAILURE" 5 "$JSON" ;;
    esac
  fi
  sleep "$INTERVAL_SEC"
done

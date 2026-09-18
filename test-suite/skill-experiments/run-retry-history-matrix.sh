#!/usr/bin/env bash
# Run the remaining validated retry-history samples in one foreground terminal.
# Usage: ./test-suite/skill-experiments/run-retry-history-matrix.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
experiment="port-widget"
graph="test-suite/skill-experiments/port-widget/compiled/ordered-speculative-manual/sog.json"
runs_root="$repo_root/test-suite/skill-experiments/$experiment/runs"

is_valid_sample() {
  local mode="$1"
  local run_id="$2"
  local workspace="$runs_root/workspaces/$run_id"
  local trace="$runs_root/control/$run_id/sog-trace.jsonl"
  [ -f "$trace" ] && [ -d "$workspace" ] || return 1
  jq -e 'select(.event.type == "process_finished") | .event.exit_code' "$trace" \
    | grep -qx '0' || return 1
  if jq -e 'select(.event.type == "process_finished") | select(.event.exit_code != 0)' "$trace" \
      | grep -q .; then
    return 1
  fi
  if [ "$mode" != baseline ] && ! rg -q '"reason":"goal=G006"' "$trace"; then
    return 1
  fi
  (
    cd "$workspace"
    node scripts/check-port-widget.js >/dev/null
    python3 scripts/audit_widget_coverage.py color-menu >/dev/null
  )
}

run_sample() {
  local mode="$1"
  local sample="$2"
  local base_id="retry-history-${mode}-${sample}-20260918"
  local run_id="$base_id"
  local previous
  local previous_id
  for previous in "$runs_root"/control/"$base_id"*; do
    [ -d "$previous" ] || continue
    previous_id="$(basename "$previous")"
    if is_valid_sample "$mode" "$previous_id"; then
      printf '\n===== %s already valid; skipping =====\n' "$previous_id"
      return 0
    fi
  done
  # A failed launch creates its workspace before Pi starts. Preserve that
  # evidence and choose a fresh id when this script is resumed.
  if [ -e "$runs_root/workspaces/$run_id" ] || [ -e "$runs_root/control/$run_id" ]; then
    run_id="${run_id}-retry-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  local workspace="$runs_root/workspaces/$run_id"

  printf '\n===== %s =====\n' "$run_id"
  case "$mode" in
    baseline)
      env \
        SOG_DISABLE_WORKFLOW=1 \
        SOG_GRAPH_PATH="$graph" \
        SOG_RUN_ID="$run_id" \
        SKILL_EXPERIMENT="$experiment" \
        make -C "$repo_root" experiment-pi-fuse-ordered-speculative
      ;;
    clean|read-prefix)
      env \
        SOG_GRAPH_PATH="$graph" \
        SOG_RUN_ID="$run_id" \
        SOG_SPECULATIVE_RETRY_HISTORY="$mode" \
        SKILL_EXPERIMENT="$experiment" \
        make -C "$repo_root" experiment-pi-fuse-ordered-speculative
      ;;
    *)
      printf 'unknown retry-history mode: %s\n' "$mode" >&2
      return 2
      ;;
  esac

  (
    cd "$workspace"
    node scripts/check-port-widget.js
    python3 scripts/audit_widget_coverage.py color-menu
  )
  python3 "$repo_root/test-suite/skill-experiments/analyze-goal-trace.py" \
    "$runs_root/control/$run_id/sog-trace.jsonl"
}

# r2 baseline and clean are already valid. r2 read-prefix needs a fresh valid
# sample; r3 repeats all three strategies.
run_sample read-prefix r2f
run_sample baseline r3
run_sample clean r3
run_sample read-prefix r3

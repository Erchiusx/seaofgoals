#!/usr/bin/env bash
# Run qsv retry-history samples in one foreground terminal.
# Usage: ./test-suite/skill-experiments/run-qsv-retry-history-matrix.sh [r1|r2|r3]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
experiment="mcp-release-prep-qsv-real"
graph="test-suite/skill-experiments/mcp-release-prep-qsv-real/compiled/ordered-speculative-manual/sog.json"
runs_root="$repo_root/test-suite/skill-experiments/$experiment/runs"
skill_path="/home/erchius/datasets/SSL/docs/testsets/mcp-release-prep/SKILL.md"
fixture_root="$repo_root/test-suite/skill-experiments/$experiment/fixture"
fixture_prepare_log="$runs_root/fixture-prepare.log"
round="${1:-r1}"

case "$round" in r1|r2|r3) ;; *) printf 'round must be r1, r2, or r3\n' >&2; exit 2 ;; esac
test -f "$skill_path" || { printf 'missing qsv skill source: %s\n' "$skill_path" >&2; exit 2; }
if [ ! -f "$fixture_root/.claude/skills/package.json" ]; then
  mkdir -p "$runs_root"
  printf 'Preparing missing qsv fixture; output: %s\n' "$fixture_prepare_log"
  if ! "$repo_root/test-suite/skill-experiments/$experiment/prepare-fixture.sh" \
    </dev/null >"$fixture_prepare_log" 2>&1; then
    tail -n 80 "$fixture_prepare_log" >&2
    exit 1
  fi
fi

is_valid_sample() {
  local run_id="$1"
  local workspace="$runs_root/workspaces/$run_id"
  local trace="$runs_root/control/$run_id/sog-trace.jsonl"
  test -s "$workspace/.claude/skills/qsv-mcp-server-17.0.1.mcpb" || return 1
  test -f "$trace" || return 1
  jq -e -s 'any(.[]; .event.type == "process_finished" and .event.exit_code == 0)' "$trace" | grep -qx true
}

run_sample() {
  local mode="$1"
  local base_run_id="qsv-retry-history-${mode}-${round}-20260918"
  local run_id
  for control_dir in "$runs_root/control/$base_run_id"*; do
    [ -d "$control_dir" ] || continue
    run_id="$(basename "$control_dir")"
    if is_valid_sample "$run_id"; then
      printf '\n===== %s (already valid; skipping) =====\n' "$run_id"
      python3 "$repo_root/test-suite/skill-experiments/analyze-goal-trace.py" \
        "$runs_root/control/$run_id/sog-trace.jsonl"
      return
    fi
  done
  run_id="$base_run_id"
  if [ -e "$runs_root/workspaces/$run_id" ] || [ -e "$runs_root/control/$run_id" ]; then
    run_id="${run_id}-retry-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  local workspace="$runs_root/workspaces/$run_id"

  printf '\n===== %s =====\n' "$run_id"
  case "$mode" in
    baseline)
      env SOG_DISABLE_WORKFLOW=1 SOG_GRAPH_PATH="$graph" SOG_SKILL_PATH="$skill_path" SOG_RUN_ID="$run_id" SKILL_EXPERIMENT="$experiment" \
        make -C "$repo_root" experiment-pi-fuse-ordered-speculative
      ;;
    clean|read-prefix)
      env SOG_GRAPH_PATH="$graph" SOG_SKILL_PATH="$skill_path" SOG_RUN_ID="$run_id" SOG_SPECULATIVE_RETRY_HISTORY="$mode" SKILL_EXPERIMENT="$experiment" \
        make -C "$repo_root" experiment-pi-fuse-ordered-speculative
      ;;
  esac

  test -s "$workspace/.claude/skills/qsv-mcp-server-17.0.1.mcpb"
  (
    cd "$workspace"
    node -e '
      const fs = require("fs");
      for (const path of ["package.json", "manifest.json", ".claude-plugin/plugin.json"]) {
        const value = JSON.parse(fs.readFileSync(`.claude/skills/${path}`, "utf8"));
        if (value.version !== "17.0.1") throw new Error(`${path}: expected 17.0.1, got ${value.version}`);
      }
    '
  )
  python3 "$repo_root/test-suite/skill-experiments/analyze-goal-trace.py" \
    "$runs_root/control/$run_id/sog-trace.jsonl"
}

run_sample baseline
run_sample clean
run_sample read-prefix

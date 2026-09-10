#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <experiment-name>" >&2
  exit 2
fi

experiment_name="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
experiment_dir="$repo_root/test-suite/skill-experiments/$experiment_name"

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    echo "uuidgen is not available and /proc/sys/kernel/random/uuid is not readable" >&2
    exit 2
  fi
}

if [ ! -d "$experiment_dir" ]; then
  echo "unknown experiment: $experiment_name" >&2
  exit 2
fi

if [ ! -f "$experiment_dir/sog.json" ]; then
  echo "missing compiled goal spec: $experiment_dir/sog.json" >&2
  echo "run 'make build-sog' from the repository root first." >&2
  exit 2
fi

skill_env_name="$(printf '%s_SKILL' "$experiment_name" | tr '[:lower:]-' '[:upper:]_')"
default_skill_path="/home/erchius/datasets/SSL/docs/testsets/$experiment_name/SKILL.md"
skill_path="${!skill_env_name:-$default_skill_path}"
if [ ! -f "$skill_path" ]; then
  echo "missing skill source: $skill_path" >&2
  exit 2
fi
export SOG_SKILL_TEXT
SOG_SKILL_TEXT="$(<"$skill_path")"

if [ "${SOG_DISABLE_WORKFLOW:-}" = "1" ] || [ "${SOG_DISABLE_WORKFLOW:-}" = "true" ]; then
  unset SOG_SERIAL_GOALS_TEXT SOG_SERIAL_GOALS
else
  export SOG_SERIAL_GOALS_TEXT
  SOG_SERIAL_GOALS_TEXT="$(<"$experiment_dir/sog.json")"
fi
export SOG_SCHEDULER="${SOG_SCHEDULER:-serial}"
if [ "$SOG_SCHEDULER" = "concurrent" ]; then
  export SOG_SANDBOX="${SOG_SANDBOX:-bwrap}"
fi
workflow_suffix="--$SOG_SCHEDULER-sog"
if [ "${SOG_PRELOAD_GOAL_CONTEXT:-}" = "1" ] || [ "${SOG_PRELOAD_GOAL_CONTEXT:-}" = "true" ]; then
  workflow_suffix="$workflow_suffix--preload-context"
fi

export SOG_CONFIG_FILE="${SOG_CONFIG_FILE:-$repo_root/seaofgoals.config.json}"
export SOG_AGENT_RUNNER="${SOG_AGENT_RUNNER:-harness}"
export SOG_EXPERIMENT_DRIVER="${SOG_EXPERIMENT_DRIVER:-docker}"
export SOG_MODEL="${SOG_MODEL:-gpt-5.5}"
export SOG_HARNESS_LIFECYCLE="${SOG_HARNESS_LIFECYCLE:-1}"
export SOG_PROMPT_CACHE_KEY="${SOG_PROMPT_CACHE_KEY:-sog:$experiment_name:$SOG_MODEL:$SOG_AGENT_RUNNER:$SOG_SCHEDULER:lifecycle-$SOG_HARNESS_LIFECYCLE}"
export SOG_PROMPT_CACHE_RETENTION="${SOG_PROMPT_CACHE_RETENTION:-24h}"
export SOG_CODEX_HOME_HOST="${SOG_CODEX_HOME_HOST:-${CODEX_HOME:-$HOME/.codex}}"
export SOG_CODEX_HOME="${SOG_CODEX_HOME:-/codex-home}"
export SOG_PI_SDK_RUNNER="${SOG_PI_SDK_RUNNER:-$repo_root/pi/sog-sdk-runner.mjs}"
if [ "$SOG_EXPERIMENT_DRIVER" = "docker" ]; then
  export SOG_CONFIG="${SOG_CONFIG:-/seaofgoals.config.json}"
else
  export SOG_CONFIG="${SOG_CONFIG:-$SOG_CONFIG_FILE}"
fi

if [ -z "${OPENAI_API_KEY:-}" ] && [ -f "$HOME/.secrets/rise" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.secrets/rise"
fi

if [ -z "${OPENAI_API_KEY:-}" ] && [ -f "$HOME/.secrets/openai" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.secrets/openai"
fi

if [ "$SOG_AGENT_RUNNER" != "codex" ] && [ "$SOG_AGENT_RUNNER" != "pi" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "OPENAI_API_KEY is not set, and $HOME/.secrets/openai did not set it." >&2
  exit 2
fi
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"

cd "$repo_root"
cabal build ${SOG_CABAL_FLAGS:-} test:SeaOfGoals-agent-runner
export SOG_EXECUTABLE
SOG_EXECUTABLE="$(cabal list-bin ${SOG_CABAL_FLAGS:-} test:SeaOfGoals-agent-runner)"
export SOG_RUNNER_UID="${SOG_RUNNER_UID:-$(id -u)}"
export SOG_RUNNER_GID="${SOG_RUNNER_GID:-$(id -g)}"

runs_dir="$experiment_dir/runs"
workspaces_dir="$runs_dir/workspaces"
controls_dir="$runs_dir/control"
run_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="${SOG_RUN_ID:-$(new_uuid)--$run_timestamp--$experiment_name$workflow_suffix}"
workspace_dir="$workspaces_dir/$run_id"
control_dir="$controls_dir/$run_id"

mkdir -p "$workspaces_dir" "$controls_dir"

if [ -e "$runs_dir/current" ] && [ ! -L "$runs_dir/current" ]; then
  migrated_id="$(new_uuid)--$run_timestamp--$experiment_name--migrated-current"
  mv "$runs_dir/current" "$workspaces_dir/$migrated_id"
fi

if [ -e "$workspace_dir" ]; then
  echo "run workspace already exists: $workspace_dir" >&2
  exit 2
fi

mkdir -p "$workspace_dir"
mkdir -p "$control_dir"
ln -sfn "workspaces/$run_id" "$runs_dir/current.next"
mv -Tf "$runs_dir/current.next" "$runs_dir/current"
ln -sfn "control/$run_id" "$runs_dir/control-current.next"
mv -Tf "$runs_dir/control-current.next" "$runs_dir/control-current"

echo "Experiment workspace: $workspace_dir"
echo "Current workspace symlink: $runs_dir/current -> workspaces/$run_id"
echo "Experiment control: $control_dir"
echo "Current control symlink: $runs_dir/control-current -> control/$run_id"

if [ "$SOG_EXPERIMENT_DRIVER" = "host" ]; then
  rm -rf "$workspace_dir"/*
  cp -a "$experiment_dir/fixture/." "$workspace_dir/"
  export SOG_CONTROL_ROOT="$control_dir"
  export SOG_TRACE_PATH="$control_dir/sog-trace.jsonl"
  export SOG_CODEX_HOME="${SOG_CODEX_HOME_HOST}"
  cd "$workspace_dir"
  "$SOG_EXECUTABLE" "$(<"$experiment_dir/prompt.txt")"
  exit 0
fi

cd "$experiment_dir"
export SOG_CONTROL_ROOT="/sog-control"
export SOG_TRACE_PATH="/sog-control/sog-trace.jsonl"
cleanup() {
  SOG_EXECUTABLE="$SOG_EXECUTABLE" docker compose down >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose up --build --abort-on-container-exit --exit-code-from runner runner

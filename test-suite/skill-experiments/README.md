# Skill Experiments

These experiments run selected raw `SKILL.md` instructions through the SeaOfGoals harness and record subgoal/tool/effect traces.

Each experiment has:

- `fixture/`: read-only seed workspace.
- `prompt.txt`: harness task prompt.
- `docker-compose.yml`: dependency and runner environment.
- `runs/workspaces/<run-id>/`: cached workspace from one run.
- `runs/control/<run-id>/`: trace, Codex history, and scheduler state for one run.
- `runs/current`: symlink to the active run workspace, ignored by git.
- `runs/control-current`: symlink to the active run control directory, ignored by git.

The launcher creates run ids as `uuid--UTC-time--experiment-name`, for example `2f4...--20260811T120000Z--mysql2postgres`. Set `SOG_RUN_ID=...` to choose a name explicitly.

The runner mounts only `runs/current` at `/workspace`; it does not mount the parent `runs/` directory, so the agent cannot inspect previous run outputs through the workspace mount. Trace and scheduler control state are mounted separately at `/sog-control` for the harness and are not under `/workspace`. Each run updates only the `runs/current` and `runs/control-current` symlink targets and keeps older workspaces under `runs/workspaces/` plus older control state under `runs/control/`.

Run from the repository root:

```bash
make experiment-mysql2postgres
make experiment-test-with-postgres
make experiment-concurrent SKILL_EXPERIMENT=nextjs-performance
make experiment-codex SKILL_EXPERIMENT=nextjs-performance
```

`make experiment-concurrent SKILL_EXPERIMENT=...` sets
`SOG_SCHEDULER=concurrent`. In this mode, every ready goal runs in its own
workspace copy under `runs/control-current/concurrent/goals/`; accepted results
are merged back into the run workspace. The copy-tree merge baseline detects
file write/write conflicts and replans the serially later goal. The FUSE event
mode records workspace reads/writes from the mounted workspace and uses those
events for conflict checks.

`docker-development` is kept as a fixture candidate but is not part of the
current test set, because it would require reasoning about Docker access from
inside the runner environment.

The runner sources `$HOME/.secrets/openai` automatically when `OPENAI_API_KEY` is not already set.

Set `SOG_AGENT_RUNNER=codex` or use `make experiment-codex
SKILL_EXPERIMENT=...` to execute each SeaOfGoals task node by launching
`codex exec` inside the bwrap workspace sandbox. `make experiment-codex`
uses `SOG_EXPERIMENT_DRIVER=host` by default, so it prepares the run workspace
on the host and avoids the Docker runner layer. This mode uses the Codex
account from `CODEX_HOME`/`$HOME/.codex` and does not require `OPENAI_API_KEY`
in the Haskell harness. The trace records process-level start/finish events
and workspace diffs rather than model API tool-call turns.

To run the Codex-backed concurrent scheduler:

```bash
SOG_SCHEDULER=concurrent make experiment-codex SKILL_EXPERIMENT=nextjs-performance
```

Each run creates a fresh workspace under `<experiment>/runs/workspaces/` and
updates `<experiment>/runs/current` to point at it. It also creates a matching
control directory under `<experiment>/runs/control/` and updates
`<experiment>/runs/control-current`. If a merge conflict is detected, the
scheduler keeps the serially earlier result, updates the DAG, and reruns the
serially later goal. The trace records `merge_conflict`,
`merge_accept`, and `dag_snapshot` events so the recovery path can be inspected
after the run.

SeaOfGoals loads `seaofgoals.config.json` from the current directory by
default. Set `SOG_CONFIG=/path/to/config.json` to use another config file. The
current default concurrent chase parallelism is 4.

Set `SOG_SANDBOX=bwrap` to run the harness `shell` tool inside a bwrap view.
The model still runs through the host harness process, but shell commands see
the current run workspace at `/workspace`, with cache/home/tmp writes redirected
under the control directory instead of `/workspace`.

Set `SOG_WORKFLOW_SPEC=/path/to/workflow.json` to make the runner follow a static CFG exported from an SCFG-style analysis. The JSON shape is intentionally small:

```json
{
  "name": "skill-name",
  "nodes": [{"id": "N001", "title": "Configure", "body": "optional detail"}],
  "edges": [{"source": "N001", "target": "N002", "rationale": "optional"}]
}
```

The runner also accepts `skill_name`, `instructions`, and `src`/`dst` aliases to match `scfg-package` exports.

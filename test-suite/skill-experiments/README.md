# Skill Experiments

These experiments run selected raw `SKILL.md` instructions through the SeaOfGoals harness and record subgoal/tool/effect traces.

Each experiment has:

- `fixture/`: read-only seed workspace.
- `prompt.txt`: harness task prompt.
- `docker-compose.yml`: dependency and runner environment.
- `runs/workspaces/<run-id>/`: cached workspace from one run.
- `runs/current`: symlink to the active run workspace, ignored by git.

The launcher creates run ids as `uuid--UTC-time--experiment-name`, for example `2f4...--20260811T120000Z--mysql2postgres`. Set `SOG_RUN_ID=...` to choose a name explicitly.

The runner mounts only `runs/current` at `/workspace`; it does not mount the parent `runs/` directory, so the agent cannot inspect previous run outputs through the workspace mount. Each run updates only the `runs/current` symlink target and keeps older workspaces under `runs/workspaces/`.

Run from the repository root:

```bash
make experiment-mysql2postgres
make experiment-test-with-postgres
```

`docker-development` is kept as a fixture candidate but is not part of the
current test set, because it would require reasoning about Docker access from
inside the runner environment.

The runner sources `$HOME/.secrets/openai` automatically when `OPENAI_API_KEY` is not already set.

Set `SOG_WORKFLOW_SPEC=/path/to/workflow.json` to make the runner follow a static CFG exported from an SCFG-style analysis. The JSON shape is intentionally small:

```json
{
  "name": "skill-name",
  "nodes": [{"id": "N001", "title": "Configure", "body": "optional detail"}],
  "edges": [{"source": "N001", "target": "N002", "rationale": "optional"}]
}
```

The runner also accepts `skill_name`, `instructions`, and `src`/`dst` aliases to match `scfg-package` exports.

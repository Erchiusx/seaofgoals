# test-with-postgres Experiment

Runs the `test-with-postgres` skill against a small Go test fixture with PostgreSQL supplied by Docker Compose.

The fixture is mounted read-only at `/seed`. Each run copies it into `runs/current`, and the agent writes only inside that run workspace.

Run from the repository root:

```bash
make experiment-test-with-postgres
```

The trace is written to:

```text
test-suite/skill-experiments/test-with-postgres/runs/control-current/sog-trace.jsonl
```

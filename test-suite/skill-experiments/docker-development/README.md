# docker-development Experiment

Runs the `docker-development` skill against a deliberately weak Node.js Dockerfile and compose setup.

This experiment does not mount the Docker socket and does not run Docker inside the runner. It measures static inspection, file editing, and effect tracing.

Run from the repository root:

```bash
make experiment-docker-development
```

The trace is written to:

```text
test-suite/skill-experiments/docker-development/runs/current/sog-trace.jsonl
```

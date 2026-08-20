# docker-development Experiment

This experiment is currently paused and is not part of the active test set.

The fixture was intended to run the `docker-development` skill against a
deliberately weak Node.js Dockerfile and compose setup. We are not using it for
the current serial/DAG experiments because it depends on Docker-oriented
behavior from inside the runner environment.

Manual run target, if this candidate is restored later:

```bash
make experiment-docker-development
```

The trace is written to:

```text
test-suite/skill-experiments/docker-development/runs/current/sog-trace.jsonl
```

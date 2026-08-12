# mysql2postgres Experiment

This experiment runs the SeaOfGoals harness in a Docker Compose runner with a local PostgreSQL dependency.

The runner does not run Docker itself. It receives:

- the built `SeaOfGoals` executable mounted read-only,
- a small Java/Spring/MyBatis fixture mounted read-only at `/seed`,
- a per-run copy mounted at `/workspace`,
- the `mysql2postgres` skill text mounted at `/skill/SKILL.md`,
- PostgreSQL exposed as the Compose service `postgres`.

## Build The Harness

From the repository root:

```bash
cabal build test:SeaOfGoals-agent-runner
```

Find the executable path:

```bash
cabal list-bin test:SeaOfGoals-agent-runner
```

## Run

```bash
export OPENAI_API_KEY=...
export SOG_EXECUTABLE="$(cabal list-bin test:SeaOfGoals-agent-runner)"
# Optional if your skill corpus lives elsewhere:
# export MYSQL2POSTGRES_SKILL=/path/to/mysql2postgres/SKILL.md
cd experiments/mysql2postgres
docker compose up --build runner
```

Each run starts by replacing `runs/current` with a fresh copy of `fixture`.
The trace is written inside the run workspace as:

```text
experiments/mysql2postgres/runs/current/sog-trace.jsonl
```

## Why Compose

Compose provides a clean PostgreSQL service without Docker-in-Docker. The agent's tools run inside the runner container and only touch the copied run workspace plus the local PostgreSQL service.

## Useful Resources To Detect

- `fs:application.yml`
- `fs:src/main/resources/mapper/DemoMapper.xml`
- `fs:src/main/java/com/example/demo/dal/mysql/DemoEntityDO.java`
- `fs:migrations/001_mysql_schema.sql`
- `db:postgres/schema`
- `artifact:sog-trace.jsonl`

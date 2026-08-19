# SeaOfGoals Agent Notes

## Module Size

Keep modules small enough for a human maintainer to read and modify directly.

Prefer adding a narrow module with one clear responsibility over expanding an
existing module into a mixed abstraction. Good boundaries in this project are:

- compile-time skill graph generation,
- scheduling state,
- workspace snapshots and diffs,
- container or sandbox execution,
- tool-call parsing and rendering,
- experiment fixtures and scripts.

Do not introduce a broad typeclass until there are at least two concrete uses
that justify the shared interface. Prefer concrete data structures and pure
functions for early experiments.

## Execution Boundaries

Keep the host harness responsible for scheduling, prompting, tracing, and merge
decisions. Keep workspace side effects behind explicit tool/container backends.

Avoid leaking host paths into prompts and traces intended to model agent task
execution. When adding execution backends, preserve a stable agent-visible
workspace path such as `/workspace`.

## Tests

When a backend depends on host services such as FUSE or containerd, keep ordinary
unit tests focused on pure command rendering, access logs, and state updates.
Put tests requiring real host services behind explicit flags or smoke commands.

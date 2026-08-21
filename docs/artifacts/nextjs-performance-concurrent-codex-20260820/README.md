# Next.js Performance Concurrent Codex Trace

This directory contains a preserved SeaOfGoals experiment trace and a standalone HTML viewer for sharing.

- `sog-trace.jsonl`: raw SeaOfGoals trace from the successful concurrent Codex run.
- `trace.html`: standalone HTML summary generated from the trace.

Source run before preservation:

```text
/home/erchius/development/scfg/SeaOfGoals/test-suite/skill-experiments/nextjs-performance/runs/current
```

The run demonstrates:

- concurrent Codex-backed goal execution with bwrap workspaces;
- a merge conflict on `app/dashboard/page.tsx`;
- recovery by rerunning the serially later goal;
- final checklist success for the Next.js fixture.

The trace was produced before `dag_snapshot` trace events were added, so the HTML reports zero DAG snapshots for this preserved run.

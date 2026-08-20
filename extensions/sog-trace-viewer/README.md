# SeaOfGoals Trace Viewer

Minimal VS Code extension for browsing `sog-trace.jsonl` as a notebook-like trajectory view.

## Usage

- Open this folder as an extension development host, or run:

```bash
code --extensionDevelopmentPath=/home/erchius/development/scfg/SeaOfGoals/extensions/sog-trace-viewer /home/erchius/development/scfg/SeaOfGoals
```

- Run `SeaOfGoals: Open Trace View` from the command palette.
- Run `SeaOfGoals: Open Goal Timeline` to view the same trace as a schedule-like grid: chronological rows with goal columns for horizontal comparison.
- Or right click a `sog-trace.jsonl` file and choose `SeaOfGoals: Open Trace View`.

## Features

- Renders each JSONL event as a cell.
- Renders a goal timeline board for comparing subgoal-local tool calls, effects, completion status, and run-level merge/replan events when present.
- Shows prompt, assistant messages, tool calls/results, subgoal events, effects, workflow status, and finish reason.
- Provides quick filters for subgoals, tools, effects, workflow, and messages.

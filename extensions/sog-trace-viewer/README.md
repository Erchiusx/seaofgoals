# SeaOfGoals Trace Viewer

Minimal VS Code extension for browsing `sog-trace.jsonl` as a notebook-like trajectory view.

## Usage

- Open this folder as an extension development host, or run:

```bash
code --extensionDevelopmentPath=/home/erchius/development/scfg/SeaOfGoals/extensions/sog-trace-viewer /home/erchius/development/scfg/SeaOfGoals
```

- Run `SeaOfGoals: Open Trace View` from the command palette.
- Or right click a `sog-trace.jsonl` file and choose `SeaOfGoals: Open Trace View`.

## Features

- Renders each JSONL event as a cell.
- Shows prompt, assistant messages, tool calls/results, subgoal events, effects, workflow status, and finish reason.
- Provides quick filters for subgoals, tools, effects, workflow, and messages.

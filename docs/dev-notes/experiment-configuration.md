# Experiment Configuration

## Purpose

An experiment must be reproducible without reconstructing a long list of shell
assignments. `seaofgoals.config.json` remains the runtime scheduler tuning file;
it is not an experiment description. A versioned `experiment.*.json` records
the runner, model, graph, workspace policy, planner behavior, and history mode
for one experiment variant.

Run or inspect a configuration with:

```sh
make show-experiment-config CONFIG=path/to/experiment.json
make run-experiment-config CONFIG=path/to/experiment.json
```

The launcher rejects unknown keys and incompatible combinations, clears the
experiment variables it owns from the inherited environment, then translates
the validated configuration into the current `SOG_*` process interface. This
keeps the migration narrow: Haskell components can continue using their
existing loaders while experiments have one declarative entry point.

## Schema

The version 1 shape is:

```json
{
  "version": 1,
  "experiment": "fixture-directory-name",
  "runner": "pi",
  "driver": "host",
  "model": "gpt-5.6",
  "scheduler": "concurrent",
  "workflow": {
    "enabled": true,
    "graph": "test-suite/skill-experiments/example/sog.json"
  },
  "workspace": {
    "backend": "fuse",
    "sandbox": "bwrap",
    "conflictMode": "strict",
    "maskedPaths": ["path/to/embedded/instructions"],
    "maskedPathGoals": ["G000", "G001"]
  },
  "planning": {
    "incremental": true,
    "preload": true
  },
  "history": {
    "piHandoff": false
  },
  "harness": {
    "lifecycle": false
  },
  "cache": {
    "retention": "24h"
  },
  "build": {
    "fuseSupport": true
  },
  "runtimeConfig": "seaofgoals.config.json",
  "skillPath": "/path/to/SKILL.md"
}
```

Paths may be absolute, start with `~`, or be relative to the repository root.
`build.fuseSupport` controls the Cabal FUSE flag independently of the selected
workspace backend. Paired baseline and concurrent configurations should both
enable it so alternating runs reuse one build rather than recompiling the whole
package. A FUSE workspace requires this capability. A cache key may be given as
`cache.key`; otherwise `run-experiment.sh` derives one from the effective
experiment settings.

`workspace.conflictMode` is either `strict` or `file-writes-only`. The latter
only removes pure directory writes from conflict comparison; regular-file
write/read conflicts remain conflicts.

`workspace.maskedPaths` contains workspace-relative directories that bwrap
overlays with read-only empty directories. `workspace.maskedPathGoals` limits
the overlay to selected Pi goal processes; an empty goal list applies the mask
to every goal. This allows an experiment to keep embedded instruction sources
in the real fixture for build or package commands without exposing those
sources to planner or editing agents. Paths must remain inside `/workspace`.

## Credentials And Provenance

Credentials are deliberately absent from the configuration schema. The runner
continues to inherit credentials or load `~/.secrets/rise` and
`~/.secrets/openai`. Arbitrary environment maps are also excluded from the
schema so configuration files cannot quietly bypass validation.

At startup, `run-experiment.sh` copies the selected description to
`runs/control/<run-id>/experiment.json` beside the trace. This captures the
declared settings for later analysis without storing credentials.

# Real qsv MCP release experiment

This experiment applies the SSL `mcp-release-prep` skill to the actual qsv MCP
package from commit `9673f2ae77bcb65d6e5fc6573f47aaaad36cfd66`, the source
revision recorded by SSL. The release target is `17.0.1` and the minimum qsv
binary version remains unchanged.

The fixture uses the real TypeScript sources, 460-test suite, package lock, and
MCPB archiver. Dependencies are installed before the experiment and reused
offline inside bwrap. Generated `node_modules`, `dist`, and MCPB files are not
tracked.

Prepare the fixture:

```sh
test-suite/skill-experiments/mcp-release-prep-qsv-real/prepare-fixture.sh
```

Run the speculative FUSE experiment:

```sh
make run-experiment-config \
  CONFIG=test-suite/skill-experiments/mcp-release-prep-qsv-real/experiment.concurrent.json
```

Run the direct single-Pi baseline:

```sh
make run-experiment-config \
  CONFIG=test-suite/skill-experiments/mcp-release-prep-qsv-real/experiment.baseline.json
```

The concurrent configuration uses the versioned
`qsv-9673f2a-v4-goal-local-context` compiled graph. Its runtime skill-context
file is intentionally empty: G000 receives the complete compiled graph, while
each execution goal receives only the original task, graph topology, its
self-contained goal contract, and any planned context. The single-Pi baseline
continues to receive the original skill text.

The Pi SDK session disables automatic skill discovery because the compiled
graph is its instruction source. In addition, the concurrent bwrap view masks
the package's embedded `mcp-release-prep` and `release-prep` instruction
directories from every goal except packaging. The package goal retains the
original directories so the MCPB contains the real project files.

Validate and inspect either configuration without running the model by using
`make show-experiment-config CONFIG=...`. Provider credentials remain outside
the JSON file; `run-experiment.sh` loads `~/.secrets/rise` or
`~/.secrets/openai` when needed.

`npm run build` and `npm test` both compile into `dist/`. Their optimistic
parallel placement intentionally exercises dynamic file-conflict discovery;
this real repository is therefore a conflict-and-rerun case, not an assumed
speedup-positive fixture.

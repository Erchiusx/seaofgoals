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

Validate and inspect either configuration without running the model by using
`make show-experiment-config CONFIG=...`. Provider credentials remain outside
the JSON file; `run-experiment.sh` loads `~/.secrets/rise` or
`~/.secrets/openai` when needed.

`npm run build` and `npm test` both compile into `dist/`. Their optimistic
parallel placement intentionally exercises dynamic file-conflict discovery;
this real repository is therefore a conflict-and-rerun case, not an assumed
speedup-positive fixture.

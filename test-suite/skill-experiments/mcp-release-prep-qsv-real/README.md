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
MCP_RELEASE_PREP_QSV_REAL_SKILL=/home/erchius/datasets/SSL/docs/testsets/mcp-release-prep/SKILL.md \
SOG_MODEL=gpt-5.6 SOG_PI_MODEL=gpt-5.6 \
make experiment-pi-fuse-concurrent-planner SKILL_EXPERIMENT=mcp-release-prep-qsv-real
```

Run the direct single-Pi baseline:

```sh
MCP_RELEASE_PREP_QSV_REAL_SKILL=/home/erchius/datasets/SSL/docs/testsets/mcp-release-prep/SKILL.md \
SOG_DISABLE_WORKFLOW=1 SOG_AGENT_RUNNER=pi SOG_EXPERIMENT_DRIVER=host \
SOG_MODEL=gpt-5.6 SOG_PI_MODEL=gpt-5.6 \
make experiment SKILL_EXPERIMENT=mcp-release-prep-qsv-real
```

`npm run build` and `npm test` both compile into `dist/`. Their optimistic
parallel placement intentionally exercises dynamic file-conflict discovery;
this real repository is therefore a conflict-and-rerun case, not an assumed
speedup-positive fixture.

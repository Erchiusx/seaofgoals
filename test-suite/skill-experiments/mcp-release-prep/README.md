# mcp-release-prep Experiment

Runs the SSL `mcp-release-prep` skill against a local qsv-like MCP package.

The fixture has two independent layers of work:

- release metadata, documentation, and changelog updates touch disjoint files;
- `npm run build` and `npm test` both perform real TypeScript compilation but
  write to separate output trees.

The build and test scripts generate and compile 6,000 and 5,200 TypeScript modules
inside the run workspace. This makes filesystem and compiler work visible in
the trace without requiring network access or a preinstalled `node_modules`
tree. Packaging depends on the build output, while final release verification
depends on both the test report and package artifact.

The bwrap execution view exposes Node and the system TypeScript compiler but
does not expose the host's npm installation. The task therefore invokes the
exact underlying commands from `package.json`; this changes only command
dispatch, not the build, test, package order or their outputs.

The source skill normally derives changelog entries from Git history. The
fixture provides the equivalent local input in `release-commits.txt` because a
copied seed workspace does not contain the parent repository's `.git` data.

Run the final fixture check in a completed workspace with:

```sh
cd .claude/skills
node scripts/check-release.mjs --require-artifact
```

Run the concurrent experiment with:

```sh
SOG_MODEL=gpt-5.6 SOG_PI_MODEL=gpt-5.6 \
  make experiment-pi-fuse-concurrent-planner SKILL_EXPERIMENT=mcp-release-prep
```

This target mounts a per-goal FUSE overlay inside bwrap at `/workspace`. It does
not create `ancestor` and `workspace` copies of the fixture tree.

Run the direct single-Pi baseline with the existing baseline mode used by the
other skill experiments.

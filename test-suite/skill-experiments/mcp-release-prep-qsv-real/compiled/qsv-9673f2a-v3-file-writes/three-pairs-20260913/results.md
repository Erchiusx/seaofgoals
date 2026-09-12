# Three configured qsv release pairs

All six runs used the committed `gpt-5.6` experiment configurations. The
concurrent configuration used FUSE, incremental planning, preload, no history
handoff, and `file-writes-only` conflict comparison. Wall times below come from
the first and last trace timestamps and exclude Cabal compilation.

| Pair | Baseline | Concurrent | Concurrent / baseline | Merge conflicts |
|---|---:|---:|---:|---|
| 1 | 222.8s | 393.0s | 1.76x | G003 after G002 on plugin.json; G004 after G003 on CHANGELOG.md |
| 2 | 195.0s | 382.9s | 1.96x | G006 after G005 on dist/src/bm25-search.d.ts |
| 3 | 207.1s | 237.3s | 1.15x | none |
| Mean | 208.3s | 337.7s | 1.62x | - |

Every workspace contains version 17.0.1 in package.json, manifest.json, and
.claude-plugin/plugin.json, a dated 17.0.1 changelog entry, and the nonempty
14,276,830-byte `qsv-mcp-server-17.0.1.mcpb` artifact. Isolated `npm test`
validation passed with 401 tests passing and 59 qsv-dependent tests skipped.

The baseline mappings are post-hoc assignments based on the actual commands in
each single-Pi trace. G002-G004 is shown as one shared baseline row because the
single agent combined those edits in some rounds.

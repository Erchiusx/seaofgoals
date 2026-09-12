# Real qsv MCP release experiment

Both valid runs used qsv commit `9673f2ae77bcb65d6e5fc6573f47aaaad36cfd66`,
Pi, the RISE `gpt-5.6` model, the same prepared dependencies, and release target
`17.0.1`. Trace wall time excludes Cabal compilation and fixture copying.

## Concurrent SOG

Trace wall time: **309.7 s**.

| Goal | Work | Read rounds | Read time | Write rounds | Write time | Active time |
|---|---|---:|---:|---:|---:|---:|
| G000 | Runtime planning | 18 | 139.9 s | 0 | 0.0 s | 139.9 s |
| G001 | Release inspection | 2 | 40.7 s | 0 | 0.0 s | 40.7 s |
| G002 | Core metadata edits | 0 | 0.0 s | 1 | 7.5 s | 7.5 s |
| G003 | Documentation edits | 2 | 20.6 s | 1 | 20.4 s | 41.0 s |
| G004 | Changelog edit | 1 | 6.5 s | 1 | 22.1 s | 28.6 s |
| G005 | TypeScript build | 0 | 0.0 s | 1 | 7.1 s | 7.1 s |
| G006 | Test compilation and suite | 0 | 0.0 s | 2 | 19.1 s | 19.1 s |
| G007 | MCPB packaging | 0 | 0.0 s | 1 | 34.9 s | 34.9 s |
| G008 | Final verification | 2 | 47.7 s | 0 | 0.0 s | 47.7 s |

G005 and the first G006 attempt started together. G005 merged first; G006 then
reported a conflict on `.claude/skills/dist` and was rerun once against the
accepted G005 workspace. The final artifact is 14 MiB and all three release
metadata files contain `17.0.1`.

## Single Pi baseline mapped to workflow work

Trace wall time: **285.8 s**. The baseline has no goal IDs, so turns are mapped
by their actual tool calls. Shared edit rounds cannot be split reliably among
G002-G004.

| Goal group | Work | Read rounds | Read time | Write rounds | Write time | Active time |
|---|---|---:|---:|---:|---:|---:|
| G001 | Release inspection | 5 | 55.2 s | 0 | 0.0 s | 55.2 s |
| G002-G004 | Metadata, docs, changelog, later doc repair | 0 | 0.0 s | 4 | 69.3 s | 69.3 s |
| G005 | Initial failed cwd, build, rebuild | 0 | 0.0 s | 3 | 24.7 s | 24.7 s |
| G006 | Test and retest | 0 | 0.0 s | 2 | 15.0 s | 15.0 s |
| G007 | Package inspection, package-script repair, two package runs | 1 | 8.0 s | 3 | 48.6 s | 56.6 s |
| G008 | Archive and final consistency verification | 1 | 16.3 s | 2 | 36.6 s | 52.9 s |

The single agent went beyond the raw skill: it found that the real packaging
script omitted `package.json` from the archive, edited that script, adjusted two
release text files, and reran build, tests, and packaging. Even with this extra
repair, it finished **23.9 s (8.4%) faster** than concurrent SOG. The concurrent
speed ratio is `285.8 / 309.7 = 0.923x` relative to the baseline.

This fixture is therefore useful for validating conflict detection and rerun
behavior, but its native compile/test work is too short and too file-conflicting
to demonstrate a parallel speedup.

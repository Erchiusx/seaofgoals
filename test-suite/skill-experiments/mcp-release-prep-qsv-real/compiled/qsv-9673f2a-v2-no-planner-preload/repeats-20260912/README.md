# qsv release preparation repeats

Three same-model pairs compare direct single-Pi execution with concurrent SOG
execution using FUSE workspaces, incremental G000 planning, and preload history.
Each set has its own post-hoc baseline mapping because the single Pi used a
different number of model turns in each run.

| Set | Baseline | Concurrent | Concurrent / baseline |
|---|---:|---:|---:|
| [1](set-1/comparison.html) | 239.7s | 362.0s | 1.51x |
| [2](set-2/comparison.html) | 217.3s | 252.8s | 1.16x |
| [3](set-3/comparison.html) | 215.3s | 253.3s | 1.18x |
| Mean | 224.1s | 289.4s | 1.29x |

Set 1 dynamically reran both G004 after a conflict with G002 on
`.claude/skills/.claude-plugin/plugin.json` and G006 after a conflict with G005
on `.claude/skills/dist`. Sets 2 and 3 reran only G006 for the shared `dist`
conflict. Every baseline process and concurrent goal process exited with status
zero.

# port-widget planner-resolution repeats

All runs used `gpt-5.6`, a fresh UUID workspace, and the same fixture. The
baseline is one Pi process executing the raw skill. The concurrent runs use the
compiled graph, FUSE workspaces, incremental G000 planning, preload, no history
handoff, and no harness lifecycle tools.

| Pair | Single Pi | Concurrent SOG | Concurrent / baseline | Result |
| --- | ---: | ---: | ---: | --- |
| 1 | 250.4s | 516.9s | 2.06x | both checkers passed |
| 2 | 264.8s | 412.0s | 1.56x | both checkers passed |
| 3 | 235.6s | 495.4s | 2.10x | both checkers passed |

| Distribution | Mean | Median | Range |
| --- | ---: | ---: | ---: |
| Single Pi | 250.3s | 250.4s | 235.6-264.8s |
| Concurrent SOG | 474.7s | 495.4s | 412.0-516.9s |

The concurrent mean is 1.90x the baseline mean in these three repeats. Adding
the immediately preceding 191.9s / 459.4s pair gives four-pair means of 235.7s
and 470.9s, or 2.00x.

## Run observations

- G000 took 177.7s, 180.1s, and 184.5s including its model-only exit. Its
  planner-control rounds alone took 121.7s, 126.8s, and 118.1s.
- G001 was completed by G000 in all three concurrent runs.
- G005 was resolved as `no_action` only in pair 1. In pairs 2 and 3 it launched
  a model-only Pi goal lasting 3.4s and 4.1s.
- Pair 1 had one merge conflict: G004 conflicted with G003 on
  `packages/react-instantsearch-core/src/index.ts`, then G004 reran. Pairs 2 and
  3 had no merge conflicts.
- G007 remained a long tail: 146.2s, 83.7s, and 128.0s including its model-only
  exit.
- The union of active agent turns covered 509.7/516.9s, 406.1/412.0s, and
  489.4/495.4s. Only 5.9-7.2s per concurrent run was outside an active turn, so
  scheduler idle time is not the primary regression.

The checker is static and does not verify runtime behavior or TypeScript types.

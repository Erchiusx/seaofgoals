# Port-widget retry-history experiment: interim collection

The selected sample for each planned position is the first valid completion:
every Pi process exits `0`, speculative runs reach the final `G006` merge, and
the workspace passes both `check-port-widget.js` and the coverage audit.
This rule avoids selecting a faster duplicate after observing its timing.

| Strategy | r1 | r2 | r3 | Mean of completed planned samples |
|---|---:|---:|---:|---:|
| Direct baseline | 105.7s | 139.9s | 116.3s | 120.6s (n=3) |
| Speculative clean history | 153.8s | 180.4s | 175.7s | 170.0s (n=3) |
| Speculative read-prefix history | 143.4s | 197.5s | 186.3s | 175.7s (n=3) |

The direct baseline is one Pi process without goal boundaries; `None` below
means no post-hoc goal assignment has been made. Read/write time is tool-round
elapsed time, while wall time includes model generation and harness overhead.

## Direct baseline

| Sample | Trace | Read rounds/time | Write rounds/time | Goal time | Wall time |
|---|---|---:|---:|---:|---:|
| r1 | `retry-history-baseline-r1c-20260918` | 8 / 45.3s | 5 / 50.4s | 95.7s | 105.7s |
| r2 | `retry-history-baseline-r2-20260918` | 12 / 68.8s | 5 / 62.4s | 131.2s | 139.9s |
| r3 | `retry-history-baseline-r3-20260918` | 8 / 46.6s | 5 / 60.5s | 107.1s | 116.3s |

## Speculative clean history

| Goal | r1 read/write rounds (time) | r2 read/write rounds (time) | r3 read/write rounds (time) |
|---|---|---|---|
| G001 | 4 / 0 (43.3s / 0.0s) | 5 / 0 (31.4s / 0.0s) | 7 / 0 (39.4s / 0.0s) |
| G002 | 2 / 1 (14.0s / 13.0s) | 2 / 2 (10.3s / 11.0s) | 2 / 3 (12.4s / 21.6s) |
| G003 | 7 / 1 (55.5s / 22.4s) | 8 / 3 (66.6s / 36.3s) | 6 / 4 (42.9s / 33.6s) |
| G004 | 12 / 2 (78.0s / 30.4s) | 11 / 2 (70.1s / 34.4s) | 13 / 3 (80.6s / 34.0s) |
| G005 | 4 / 1 (31.3s / 13.8s) | 6 / 2 (41.6s / 24.2s) | 1 / 1 (14.9s / 13.1s) |
| G006 | 5 / 0 (39.4s / 0.0s) | 5 / 0 (37.2s / 0.0s) | 5 / 0 (40.1s / 0.0s) |
| Wall time | 153.8s | 180.4s | 175.7s |

## Speculative read-prefix history

| Goal | r1 read/write rounds (time) | r2 read/write rounds (time) | r3 read/write rounds (time) |
|---|---|---|---|
| G001 | 4 / 0 (40.4s / 0.0s) | 5 / 0 (31.3s / 0.0s) | 5 / 0 (32.9s / 0.0s) |
| G002 | 2 / 1 (9.6s / 9.0s) | 2 / 2 (16.1s / 35.8s) | 2 / 2 (11.5s / 17.7s) |
| G003 | 7 / 3 (45.7s / 20.5s) | 10 / 4 (69.3s / 23.0s) | 9 / 2 (75.7s / 33.5s) |
| G004 | 11 / 1 (75.8s / 9.3s) | 15 / 2 (91.6s / 40.9s) | 14 / 3 (83.1s / 33.9s) |
| G005 | 1 / 1 (6.5s / 13.4s) | 2 / 1 (31.8s / 15.2s) | 1 / 2 (7.5s / 17.9s) |
| G006 | 5 / 0 (36.4s / 0.0s) | 7 / 0 (59.1s / 0.0s) | 5 / 0 (43.9s / 0.0s) |
| Wall time | 143.4s | 197.5s | 186.3s |

## Excluded or extra runs

- `retry-history-baseline-r1b-20260918` failed after a backend connection
  error; it is not a timing sample.
- The earlier read-prefix r2/r2b/r2c/r2d/r2e traces were incomplete due either
  network failure or the command-session lifecycle issue; none reached G006.
- `retry-history-read-prefix-r3-20260918-retry-20260918T071349Z` failed in G001
  (`concurrent pi goal failed: failed`) and is not a timing sample.
- A second manual invocation produced valid extra completions (read-prefix r2
  132.0s, baseline r3 114.5s, clean r3 167.0s). They remain useful stochastic
  observations but are excluded from the predeclared 3-by-3 matrix.

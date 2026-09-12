# Pi FUSE Concurrent Experiment

## Purpose

The Pi concurrent experiment must use the same workspace semantics as the
runtime design. Each goal runs through bwrap with `/workspace` backed by a FUSE
overlay. The base fixture is not copied into per-goal `ancestor` and `workspace`
trees. FUSE records reads and writes, while the accepted goal snapshot contains
only task-local changed paths.

Use the explicit entry point:

```sh
SOG_MODEL=gpt-5.6 SOG_PI_MODEL=gpt-5.6 \
  make experiment-pi-fuse-concurrent-planner SKILL_EXPERIMENT=mcp-release-prep
```

The run id contains `--fuse--` so CopyTree and FUSE traces cannot be confused.

## Scheduler Corrections

Incremental G000 planning is control-plane work. It publishes per-goal plans and
can overlap execution, but its filesystem observations and empty snapshot are
not merged into the task workspace.

Execution goals may finish out of order, but merge acceptance follows their
trusted serial index. This is required by the baseline policy: keep the former
result, add a dependency, and rerun the latter result after a conflict. Accepting
a later result first would otherwise require rollback of the shared base.

## Experiment Results

The first complete FUSE run exposed a real directory-level conflict between the
build and test goals. Both wrote their own subtrees but also created the shared
`.workload` parent. The scheduler accepted G005, added `G005 -> G006`, reran G006,
and produced a valid release.

The fixture now pre-creates `.workload`, matching its intended independent
layout: build writes `.workload/build` and `dist`, while test writes
`.workload/test` and `.test-output`.

Run `643203f6-ff5f-4d00-b78b-e3211133891a--20260912T124821Z--mcp-release-prep--concurrent-sog--fuse--preload-context`
completed all nine goals with no merge conflict. Its trace wall time was 208.3
seconds. The same-model direct single-Pi baseline run
`76c8aac6-8ed0-4d82-8ec2-ca48af94c379--20260912T124229Z--mcp-release-prep--serial-sog`
completed in 131.2 seconds. Both passed `check-release.mjs --require-artifact`.

The heavy work did overlap: G005 build used one 33.5-second write round and G006
test used one 31.6-second write round. This sample remained slower because G000
used nine planning rounds totaling 100.0 seconds. Workspace copying is therefore
not the remaining explanation for the gap in this run; planner generation is.

## Planner Input And Goal Completion

G000 produces preload plans for execution goals; it must not consume an
automatically generated preload plan itself. A real-qsv run accidentally gave
G000 278 synthetic history entries containing about 624 KB of repository data.
Pi measured 126,310 input tokens and spent about 21 seconds compacting that
history before its first turn. The common preload entry point now returns empty
context for G000, while later goals still consume plans published by G000.

Pi goals complete by allowing the Pi session to stop naturally. They are not
required to call a lifecycle tool or generate a successor summary. The goal
prompt asks the model to stop immediately after its assigned work, and the Pi
SDK runner does not expose `end_goal`. Process success, timeout, and exit status
remain the harness's completion signal.

## Open Timing Question: `model_wait`

The phase visualization currently derives `model_wait` from Pi client events;
it is not timing reported by the model endpoint. `PiProcess.mapPiEvent` emits a
`model_wait` marker for every Pi `message_start`, including non-assistant
messages, and the plotter attributes the following interval to that marker
until reasoning, text, or tool-call streaming begins. Across a goal's turns,
these intervals are accumulated.

This makes `model_wait` a useful approximation of client-observed time before
the next model output, but its exact contents are unclear. It may combine API
queueing, network time-to-first-token, server-side work before streaming, and
some Pi message/session bookkeeping. It must not be presented as pure endpoint
queue time or hidden reasoning time. Discuss with Pi and endpoint maintainers
whether a request-start event or transport-level timing can establish cleaner
boundaries before using this phase as an explanatory metric.

## Real qsv Repeated Runs

Three paired `gpt-5.6` runs after removing G000's accidental preload measured
baseline/concurrent wall times of 239.7/362.0, 217.3/252.8, and 215.3/253.3
seconds. The means were 224.1 and 289.4 seconds, respectively. Concurrent SOG
was therefore slower in all three samples, by 1.51x, 1.16x, and 1.18x.

Set 1 was additionally contaminated by a G004/G002 conflict on the plugin
manifest and reran G004. All three sets encountered the expected G006/G005
conflict on the shared TypeScript `dist` tree and reran G006. These measurements
demonstrate working conflict detection and recovery, but the task is not a
conflict-free speedup example. Each baseline trace has a per-run post-hoc goal
mapping because the single Pi used 18, 15, and 17 turns across the three runs.

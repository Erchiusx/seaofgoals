# Incremental Action Planning Experiment

## Architecture

G000 is a single continuously running planner. It publishes per-goal preload
and predicted-action plans, while execution goals depend on the availability
of their own plan rather than on completion of G000. Independent plans may be
returned as separate planner tool calls in one model response. The Pi runner
accepts multiple goal plans in one call and the harness records each published
plan independently.

This preserves the distinction between planning availability and execution
dependencies: the planner can overlap with already-unblocked goals, and a
single generation round need not be spent on every individual goal.

## Latest Run

Run: `5554f1dc-86b2-4f91-99ba-f377017e2be9--20260910T111208Z--port-widget--concurrent-sog--preload-context`

The run completed successfully with a wall time of 304.0 seconds.

| Goal | Read rounds | Read time | Write rounds | Write time | Goal time |
| --- | ---: | ---: | ---: | ---: | ---: |
| G000 | 2 | 46.3s | 0 | 0.0s | 46.3s |
| G001 | 1 | 8.3s | 0 | 0.0s | 8.3s |
| G002 | 0 | 0.0s | 4 | 21.8s | 21.8s |
| G003 | 3 | 22.8s | 3 | 29.7s | 52.5s |
| G004 | 3 | 18.1s | 2 | 10.9s | 29.0s |
| G005 | 1 | 8.4s | 0 | 0.0s | 8.4s |
| G006 | 3 | 18.9s | 1 | 14.7s | 33.6s |
| G007 | 9 | 68.0s | 4 | 38.8s | 106.8s |

## Interpretation

Allowing multiple planner calls per response reduced G000 from the previous
16 read rounds and 104.3 seconds to 2 read rounds and 46.3 seconds. This
confirms that forcing one prediction per model round was a real overhead.

The total wall time did not improve in this run because G007 became the
critical path: it still performed substantial exploration and write-time
validation. The next optimization target is therefore not more planner
parallelism alone. The harness should verify that G007 receives the complete
preload and predicted-action context for its merged predecessor state, and
the planner should predict the validation commands and files needed by G007.

The trace should distinguish three cases when evaluating this optimization:

1. a command genuinely missing from the planner's prediction;
2. a predicted command or file result that was injected but ignored by the
   model;
3. a command that became invalid because an earlier merge changed the state.

Only the first case is a preload prediction failure. The second is a prompt
or history-injection failure, and the third is a state/versioning failure.

## Follow-up

- Add streaming publication when a complete planner tool-call argument is
  received, before waiting for the tool result.
- Log the per-goal planner publication time and the first subsequent use of
  each injected result.
- Inspect G007's nine read rounds before changing its goal prompt.
- Avoid declaring a goal plan ready merely because a plan artifact exists;
  readiness must be checked for that specific goal.

## Retry-Controlled Rerun

Run: `c52770c8-947d-4b19-a8f6-c168e1f86d6d--20260910T115230Z--port-widget--concurrent-sog--preload-context`

The same experiment was rerun with a fresh workspace to reduce the influence
of the previous G007 repair chain. Wall time was **227.2 seconds**.

| Goal | Read rounds | Read time | Write rounds | Write time | Goal time |
| --- | ---: | ---: | ---: | ---: | ---: |
| G000 | 2 | 38.4s | 0 | 0.0s | 38.4s |
| G001 | 1 | 10.7s | 0 | 0.0s | 10.7s |
| G002 | 0 | 0.0s | 2 | 20.4s | 20.4s |
| G003 | 4 | 28.5s | 3 | 32.1s | 60.7s |
| G004 | 4 | 26.1s | 1 | 19.0s | 45.1s |
| G005 | 1 | 10.4s | 0 | 0.0s | 10.4s |
| G006 | 2 | 17.3s | 1 | 13.3s | 30.6s |
| G007 | 5 | 35.0s | 1 | 5.7s | 40.7s |

G007 still performed one edit: it read the JS widget and then added the
`ais.colorMenu` widget type before rerunning validation. Therefore this rerun
reduces, but does not eliminate, retry contamination. Compared with the prior
run, G007 fell from 106.8s to 40.7s and the total wall time fell by 76.8s.
The remaining critical path is G003 at 60.7s, followed by G004 at 45.1s and
G007 at 40.7s.

## Configuration and Readiness Corrections

Pi experiments now default `SOG_PI_MODEL` to `SOG_MODEL`, preventing the Pi
runner from silently falling back to its own model default. Concurrent plan
readiness also checks that the specific goal id is present in the preload
artifact; merely finding `preload-plan.json` is no longer sufficient to
unlock a goal.

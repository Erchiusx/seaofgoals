# API Harness Roadmap

This note records the current migration path for the SeaOfGoals API harness so
the experiment can be resumed after interruptions.

## Current Direction

Use the API harness as the main controllable runtime again, backed by the
OpenAI-compatible RISE endpoint:

- `OPENAI_BASE_URL` and `OPENAI_API_KEY` come from `~/.secrets/rise`.
- The GPT backend should prefer `/v1/responses` over `/v1/chat/completions`.
- The harness should be able to run fair single-agent baselines without
  lifecycle tools.
- Traces should record enough timing and token accounting to explain wall time,
  cache behavior, and reasoning overhead.

## Completed Baseline Infrastructure

- API harness can execute multiple model-returned tool calls from the same round
  concurrently, except workflow barrier tools.
- `SOG_HARNESS_LIFECYCLE=0` disables `begin_subgoal`, `end_subgoal`, and
  `record_effect`, and switches to a no-lifecycle system prompt.
- `make serve-traces` starts a dynamic trace browser over
  `test-suite/skill-experiments/*/runs/control/*/sog-trace.jsonl`.
- RISE `/v1/responses` was manually verified for text responses, function tool
  calls, and encrypted reasoning output on a G000-style planning request.

## Immediate Work Items

1. Commit the current Responses API and encrypted reasoning history support.
2. Add usage trace events for every model response:
   - input tokens
   - cached input tokens
   - output tokens
   - reasoning output tokens
   - total tokens
3. Add prompt cache request support:
   - `prompt_cache_key`
   - `prompt_cache_retention`
   - stable cache key construction for experiments

## Next Experiments

After the immediate work items are implemented:

1. Re-run the `port-widget` raw-skill single-agent baseline with:
   - `SOG_HARNESS_LIFECYCLE=0`
   - no `SOG_SERIAL_GOALS_TEXT`
   - raw skill text supplied via `SOG_SKILL_PATH`
   - `/v1/responses`
   - prompt cache enabled
2. Re-run the compiled/concurrent `port-widget` experiment under the same model
   and endpoint.
3. Compare:
   - wall time
   - per-round model wait time
   - tool-call count
   - cached-token ratio
   - reasoning-token count
   - repeated read/explore commands

## Deferred Design Questions

- Whether history handoff should include complete predecessor output items,
  summarized predecessor state, or both.
- Whether encrypted reasoning items improve dependent-goal performance enough
  to justify larger histories.
- How to keep stable prompt prefixes stable while still allowing per-goal
  history handoff.
- Whether goal-entering prompts and system prompts should be written to trace as
  first-class model-visible context events.

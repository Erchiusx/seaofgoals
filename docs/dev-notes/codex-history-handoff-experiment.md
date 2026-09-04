# Codex History Handoff Experiment

## Question

We want to know whether Codex's native subagent/fork mechanism, which copies the
parent history into a child thread, prevents a child agent from re-exploring the
workspace.

This matters for SeaOfGoals because the current concurrent scheduler starts
separate goal workers. If every worker starts from an empty model context, sibling
and successor goals repeatedly inspect the same files. That makes concurrent
execution much more expensive than a single Codex run.

## What the Codex source proves

The local Codex source supports the narrower mechanical claim: forked or injected
history is model-visible.

Relevant source points:

- `AGENTS.md` says Codex maintains a message history that is sent to the model in
  inference requests.
- `codex-rs/app-server/src/request_processors/turn_processor.rs` says
  `AgentRunner::start` delegates to `spawn_subagent`, which forks from the
  parent's full history.
- `codex-rs/app-server/src/extensions.rs` wires the guardian agent spawner to
  `thread_manager.spawn_subagent`.
- `codex-rs/app-server-protocol/src/protocol/v2/thread.rs` defines
  `ThreadInjectItemsParams` as raw Responses API items appended to the
  thread's model-visible history.
- `codex-rs/app-server/tests/suite/v2/thread_inject_items.rs` checks that
  injected items are persisted in rollout history and sent in the next model
  request.

This proves that copied/injected history can be seen by the model. It does not
prove that the model will choose not to re-read files.

## Current SeaOfGoals handoff baseline

SeaOfGoals has an experimental history handoff mode:

```text
SOG_CODEX_HISTORY_HANDOFF=1
```

This mode is not Codex native thread fork. It starts a new `codex exec
--ephemeral` process for each goal, then pastes the predecessor goals' captured
Codex JSONL stdout into the next goal prompt.

The latest run was:

```text
SOG_CODEX_HISTORY_HANDOFF=1
SOG_AGENT_RUNNER=codex
SOG_EXPERIMENT_DRIVER=host
SOG_SCHEDULER=concurrent
make experiment-codex SKILL_EXPERIMENT=port-widget
```

Workspace:

```text
test-suite/skill-experiments/port-widget/runs/workspaces/1ea3c145-af0e-4f55-a9a1-24d62827af03--20260901T063453Z--port-widget--concurrent-sog
```

Trace:

```text
test-suite/skill-experiments/port-widget/runs/workspaces/1ea3c145-af0e-4f55-a9a1-24d62827af03--20260901T063453Z--port-widget--concurrent-sog/sog-trace.jsonl
```

Result:

```text
concurrent chase exceeded max replans
elapsed_seconds=438.65s
```

Observed behavior:

- Successor goals still re-read files that were already inspected by predecessor
  goals, including widget export files and package metadata.
- The handoff can make prompts larger because it includes raw Codex JSONL:
  command metadata, command output, agent messages, and process events.
- The run therefore does not show that raw pasted history prevents repeated
  exploration.

This is a useful negative baseline, but it should not be treated as evidence
against Codex's native subagent/fork mechanism. The native mechanism preserves
history as structured model context, while this baseline embeds previous process
stdout as prompt text.

## Existing no-handoff comparison

Earlier runs already showed that separate per-goal Codex processes repeat a lot
of exploration compared with a single Codex serial run.

For `port-widget`:

```text
concurrent SOG:
  225.99s, passed
  commands: 101
  explore commands: 16
  read commands: 74

single Codex serial:
  61.02s, passed
  commands: 24
  explore commands: 3
  read commands: 17
```

For `add-trigger`:

```text
concurrent SOG:
  265.02s, passed
  commands: 80
  explore commands: 18
  read commands: 54

single Codex serial:
  75.43s, passed
  commands: 22
  explore commands: 3
  read commands: 17
```

For `plugin-new-frontend-system-support`:

```text
concurrent SOG:
  247.45s, failed
  commands: 70
  explore commands: 11
  read commands: 56

single Codex serial:
  56.64s, passed
  commands: 19
  explore commands: 3
  read commands: 14
```

The main interpretation is that context fragmentation is currently a large
cost. The scheduler duplicates both workspace snapshots and model context.

## What would prove the native Codex behavior

We need a two-part experiment.

First, a mechanical test should confirm that the child model request contains
the parent's file-read output. This can be done inside the Codex app-server test
suite with a mock model:

```text
1. Create a parent thread.
2. Run a turn that reads a sentinel file.
3. Fork a child/subagent.
4. Capture the child model request.
5. Assert that the sentinel text from the parent tool output appears in the
   child's model input.
```

That proves context propagation.

Second, a behavioral test should run real Codex:

```text
1. Create a fixture with facts.txt containing a unique sentinel value.
2. Parent reads facts.txt and completes a small task.
3. Fork a child/subagent from the parent.
4. Ask the child to use the sentinel for a follow-up task.
5. Record whether the child re-runs cat/sed/rg/find on facts.txt.
6. Compare against a fresh no-history Codex thread.
```

Useful metrics:

```text
child_read_facts_txt: boolean
child_answer_correct: boolean
child_command_count: integer
child_read_command_count: integer
model_input_contains_parent_tool_output: boolean
```

Expected interpretation:

- If the forked child answers correctly without reading `facts.txt`, copied
  history can prevent repeated exploration for this controlled case.
- If the forked child still reads `facts.txt`, copied history is available but
  does not naturally suppress exploration.
- If a fresh no-history child must read the file or fails, the experiment
  distinguishes history reuse from ordinary workspace inspection.

## Implication for SeaOfGoals

The current raw JSONL handoff is not the final design. It is too noisy and can
increase prompt size. If we want context reuse, better candidates are:

- native Codex thread continuation or subagent fork;
- a compact predecessor summary generated at goal completion;
- a structured, bounded read cache containing only selected file observations.

For dependency and merge experiments, the safest baseline remains fresh goal
contexts plus explicit predecessor summaries. For performance experiments, we
should separately test whether native Codex fork reduces redundant exploration.

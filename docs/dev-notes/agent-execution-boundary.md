# Agent Execution Boundary

## Context Isolation

The first execution model should not share full conversation history between
tasks.

Each task should start from a fresh prompt context:

```text
system prompt
developer prompt
compiled goal-entering prompt
summaries from direct predecessors
workspace snapshot metadata
available tools
```

The only cross-task language context should be explicit summaries produced by
predecessor tasks. When a task finishes, the agent should be asked to produce a
small `summary_for_dependents` describing the work state that later tasks need.
Dependent tasks receive those summaries, but not the full transcript of prior
agent messages or tool calls.

This keeps language context dependencies explicit:

- Rerunning a task is easier to reproduce.
- Hidden dependencies through conversation history are avoided.
- The DAG edge set also describes which predecessor summaries are visible.
- Trace attribution is clearer because each task starts from a known prompt.
- Parallel sibling tasks cannot accidentally influence each other through shared
  context.

The intended task result shape is therefore closer to:

```json
{
  "task_id": "G003",
  "status": "success",
  "summary_for_dependents": "...",
  "observed_reads": [],
  "observed_writes": [],
  "workspace_snapshot": "...",
  "declared_outputs": []
}
```

This summary is part of the explicit dataflow. It should be treated like any
other predecessor output rather than as shared ambient context.

## Host Harness and Container Tools

The first containerd design should keep the scheduler and LLM harness on the
host, while executing task tool calls inside per-task containers.

The host side owns:

- DAG scheduling,
- LLM requests,
- prompt construction,
- tool-call parsing,
- trace collection,
- dependency updates,
- merge and rerun decisions.

The container side owns:

- shell commands,
- file edits,
- tests,
- package manager commands,
- database clients,
- other workspace side effects.

This gives each DAG task a clean side-effect boundary without putting API keys
or scheduler state inside the container.

The agent loop itself does not need one OS process per task in the first
implementation. Multiple ready tasks can be run by separate host workers, and
those workers can be Haskell threads at first. The heavy side effects happen in
containerd tasks or spawned tool processes.

A task worker can be modeled as:

```text
TaskWorker(Gi):
  build fresh prompt for Gi
  include direct predecessor summaries
  prepare containerd snapshot from current base
  create a per-task container
  run the LLM/tool-call loop on the host
  execute tool calls in the per-task container
  collect read/write access metadata
  ask the agent for summary_for_dependents
  commit the task snapshot
  return TaskResult
```

Separate OS processes can be introduced later if host worker crash isolation
becomes important, but process isolation is not the initial boundary. The
initial boundary is tool-call side effects.

## Container Lifetime

Each DAG node should get its own container and mutable snapshot:

```text
prepared environment snapshot
  -> prepare task snapshot
  -> create per-task container
  -> execute tool calls
  -> commit task result snapshot
  -> destroy container
```

Different DAG nodes should not share one mutable container, because that would
obscure the workspace snapshot boundary the merge algorithm relies on.

The container root should not be interpreted as a clean, dependency-free base
image for every task. Many skills assume the local environment already has the
right language runtime, package manager, project dependencies, service clients,
and build cache. We should not turn every task execution into an environment
installation exercise.

Real experiments should therefore start from a prepared environment:

```text
experiment environment image/rootfs/snapshot
  contains runtimes, tools, dependency caches, and service clients
  -> fork per-task workspace snapshot
  -> run the agent's tool calls
```

The smoke test may use a small image such as Alpine only to verify container
lifecycle and `/workspace` mounting. That is not the intended execution
environment for real skill experiments.

Supported environment roots should eventually include:

```text
ContainerdImage
  a prebuilt experiment image

ContainerdRootfs
  a prepared root filesystem directory

ContainerdPreparedSnapshot
  a committed containerd snapshot prepared by an experiment setup step
```

The first implementation may support only images and rootfs directories, but the
interfaces should avoid assuming that every task starts from a bare image.

The naming should avoid confusing SOG tasks with containerd tasks. Prefer names
such as:

```text
GoalNode
AgentWorker
ContainerTask
Snapshot
```

## Tool-Call Batch Semantics

The harness should treat multiple tool calls returned by one agent response as a
parallel batch.

Protocol:

```text
Within one agent loop round:
  all tool calls returned by the model are considered independent
  the harness may execute them concurrently

Across agent loop rounds:
  later tool calls may depend on earlier tool results
```

If the model needs tool-call ordering, it must split the calls across loop
rounds:

```text
round 1:
  call A

round 2, after A's result is visible:
  call B
```

If the model returns several tool calls in one response:

```text
round 1:
  call A
  call B
  call C
```

then the harness is allowed to execute `A`, `B`, and `C` concurrently. The model
is implicitly declaring that these calls do not depend on each other.

The agent prompt should state this rule explicitly:

```text
You may return multiple tool calls in one response only when they are independent
and can be executed in parallel.

If a tool call depends on the result or side effect of another tool call, return
only the prerequisite tool call first. Wait for the tool result, then issue the
dependent tool call in a later response.
```

The harness loop can then be:

```text
response = callLLM(history)

if response has no tool calls:
  finish task
else:
  execute all tool calls in the response concurrently
  append all tool results to history
  continue
```

For reproducibility, tool results from the same response should be appended back
to the conversation in the original tool-call order, not in completion order.

## Intra-Goal Conflicts

The same access tracking used for cross-goal merge can also record conflicts
inside one tool-call batch.

If two tool calls from the same response conflict at the filesystem level, the
harness should record that the model's independence declaration was wrong:

```text
tool_call_batch_id
tool_call_id
read_set
write_set
conflicts_with
```

The first implementation can record this without automatically splitting the
goal. Later, these intra-goal conflict records can provide evidence for
refining a compiled goal into smaller nodes.

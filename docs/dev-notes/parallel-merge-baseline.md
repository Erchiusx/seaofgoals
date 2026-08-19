# Parallel Workspace Merge Baseline

## Context

SeaOfGoals is moving from merely observing skill subgoals to executing a compiled
goal DAG speculatively.

The intended execution model is:

- Compile a raw skill into an ordered list of task goals.
- Treat the skill author's original serial order as a trusted execution plan.
- Run goals that are currently believed to be independent in parallel.
- Give each running goal its own workspace snapshot.
- Observe file accesses and writes while the goal runs.
- Merge successful goal snapshots back into the evolving workflow state.
- When a merge conflict reveals a missing dependency, update the DAG and rerun
  invalidated goals.

The current `Workspace` direction supports this model by representing each task
workspace as an overlay over a base snapshot. FUSE can expose that overlay as a
normal filesystem view for the agent. containerd can later manage the concrete
container filesystems and snapshots used before and after each task node.

## Baseline Assumption

The earliest baseline should trust the original serial plan.

If the skill says the work should happen in this order:

```text
S1 < S2 < ... < Sn
```

then this order is treated as semantically valid. Parallel execution is an
optimization attempt, not a replacement for the skill author's plan.

Therefore, when two speculatively parallel tasks conflict, the baseline does not
try to decide which task is more correct. It keeps the result of the task that is
earlier in the original serial order and reruns the later task on top of the new
merged state.

In short:

```text
if Si conflicts Sj and i < j:
  keep Si
  add dependency Si -> Sj
  rerun Sj
```

This gives the system a conservative fallback: failed parallelism degrades toward
the original serial execution.

## Access Sets

Each task should produce access metadata:

```text
R(S): paths read by task S
W(S): paths written by task S
A(S): paths accessed by task S = R(S) union W(S)
```

For the first baseline, reads and writes are both treated as effects relevant to
parallelism. Read/read overlap is allowed. Any overlap involving a write is
treated as evidence that the two tasks are not independent.

The initial conflict predicate is:

```text
conflict(Si, Sj) iff
  W(Si) intersects A(Sj)
  or W(Sj) intersects A(Si)
```

Expanded:

```text
conflict(Si, Sj) iff
  W(Si) intersects W(Sj)
  or W(Si) intersects R(Sj)
  or R(Si) intersects W(Sj)
```

`R(Si) intersects R(Sj)` is not a conflict.

## Dependency Discovery

Conflict is used as evidence of a missing ordering edge.

Given the trusted serial order:

```text
Si < Sj
```

and an observed conflict:

```text
conflict(Si, Sj)
```

the dynamic scheduler updates the DAG:

```text
Si -> Sj
```

The conflict itself is symmetric, but the discovered dependency is directed by
the original serial order.

## Merge Rule

The first merge policy is:

```text
take former, rerun latter
```

For a pair of conflicting tasks `Si` and `Sj` where `i < j`:

1. Commit or keep the snapshot result of `Si`.
2. Add the dependency edge `Si -> Sj`.
3. Mark `Sj` invalid if it has already run.
4. Mark any already-run descendants of `Sj` invalid.
5. Rerun invalidated tasks from a workspace snapshot that includes `Si`.

This policy deliberately avoids semantic merge in the first implementation.
There is no model-based conflict resolution, no hunk-level merge, and no attempt
to preserve both task results when the access sets show interference.

The initial implementation is a file-level FUSE snapshot merge:

```text
inputs:
  ordered FuseStoreSnapshot values
  observed Access lists
  EffectScope
  target workspace path

algorithm:
  check pairwise scoped access conflicts in original serial order
  if any conflict exists, reject the merge and report former/latter task ids
  otherwise apply each snapshot diff to the target workspace in order
```

Diff application is intentionally simple:

```text
created/modified file -> copy task-local file into target workspace
deleted path          -> remove target path if it exists
renamed path          -> remove old target path, copy new task-local file
```

At the dependency/effect layer, rename is normalized before conflict checks:

```text
rename(from, to) = delete(from) + create(to)
```

Keeping a distinct rename operation is still useful inside lower-level snapshot
diffs, because a workspace backend may observe or materialize rename directly.
The scheduler does not need that distinction. For dependency discovery, the
important fact is that the old path and the new path are both written.

The target workspace is expected to already represent the base state that the
task snapshots forked from. The merge step applies task deltas; it does not clone
the base workspace by itself.

## Scheduler Update Baseline

When a merge conflict is reported, the scheduler adds one missing dependency
edge. The conflict predicate is symmetric, but the edge is not. The edge is
oriented by the trusted serial order:

```text
if conflict(Si, Sj) and i < j:
  add edge Si -> Sj
  invalidate Sj and every already-run descendant of Sj
```

The current pure scheduler helper returns the conservative invalidation set:

```text
{latter} union descendants(latter)
```

At runtime, the scheduler can intersect this set with the goals that have
actually completed or are currently running. Pending goals do not need reruns;
they only need to respect the newly discovered edge before starting.

## Why This Is a Useful First Baseline

This baseline is simple and reproducible:

- Every new edge is justified by an observed access conflict.
- Every edge direction is justified by the original serial skill order.
- The system can always fall back to serial execution.
- It avoids introducing model judgment into merge correctness.
- It gives a clear lower bound for later, more aggressive merge strategies.

It is also easy to evaluate. If the system eventually learns enough edges, the
execution should converge toward the trusted serial plan. If many nodes remain
independent under this conservative rule, they are strong candidates for real
parallelism.

## What FUSE and containerd Provide

FUSE can provide an observation point for file access:

- `read`, `open`, `getattr`, and `readdir` can contribute to `R(S)`.
- `write`, `create`, `truncate`, `unlink`, and `rename` can contribute to `W(S)`.

containerd can provide snapshot lifecycle:

- prepare a task snapshot from a parent snapshot,
- run the task in a container,
- commit the task result snapshot,
- compute the final filesystem diff between parent and result.

containerd snapshot diffs are useful for write sets, but containerd by itself
does not normally report every file read during task execution. Read-set
tracking needs an additional observation layer such as FUSE, fanotify, eBPF, or
another syscall/filesystem tracing mechanism.

## Known Conservatism

This baseline intentionally over-approximates conflicts.

Examples:

- `rg` or `find` may read many files and cause broad dependencies.
- Directory reads may conflict with later creates/deletes under the directory.
- Metadata reads may be less semantically important than content reads.
- Two tasks may write the same text file in non-overlapping hunks and still be
  safe to merge.
- A task may read a file that another task writes, but its final output may not
  actually depend on that content.

These cases should not be optimized in the first baseline. They can become later
refinements once the conservative version works.

Metadata reads are intentionally included in the conservative read set. This is
not only for completeness; real tools often make decisions from metadata without
reading file content.

For example, `make`, incremental compilers, test runners, and cache-aware tools
may `stat` source and output files to compare mtimes:

```text
Task A:
  stat src/foo.c
  stat build/foo.o
  decide whether build/foo.o is up to date

Task B:
  write src/foo.c
```

If `Task A` observes old metadata while `Task B` is concurrently changing the
source file, `Task A` may incorrectly decide not to rebuild. In that case a
metadata-only read is a real dependency.

The first baseline therefore treats:

```text
MetadataRead(path) + Write(path)
```

as a conflict. This is conservative because some metadata reads, such as a plain
`ls -l`, may not affect later behavior. Later versions may relax this by
distinguishing metadata-sensitive tools from incidental metadata reads, but the
initial baseline should not try to infer that distinction.

## Later Refinements

Possible future improvements:

- Distinguish content reads, metadata reads, and directory reads.
- Treat validation/test goals differently from editing goals.
- Use three-way textual merge for same-file non-overlapping writes.
- Use structured merge for JSON, YAML, SQL, XML, and package manifests.
- Let a model resolve narrow merge conflicts after mechanical merge fails.
- Detect read invalidation more precisely by comparing rerun output.
- Use containerd snapshot labels to record task ids, parent snapshot ids, and
  observed access metadata.

These refinements should be measured against the baseline, not mixed into the
first implementation.

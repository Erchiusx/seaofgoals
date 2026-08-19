# Two-Phase Goal Execution

## Motivation

The conservative access baseline treats reads and writes as effects relevant to
parallelism. This is useful for correctness, but it can over-approximate
dependencies.

Many agents begin a task by exploring the workspace:

```text
find .
ls
rg
stat files
```

If all of these accesses are treated as strong read dependencies, a goal can
appear to depend on most of the repository even when it only needed directory
shape or filenames to decide what to inspect next.

A possible refinement is to split each goal into two phases:

```text
Phase 1: discovery
Phase 2: execution
```

The discovery phase lets the agent learn the workspace shape and declare the
files it intends to inspect or modify. The execution phase performs content
reads, edits, tests, and other side effects.

## Phase 1: Discovery

Discovery should be intentionally limited.

Allowed operations:

- read directory entries,
- stat paths,
- inspect path existence and metadata,
- possibly use filename/path search.

Forbidden operations:

- read file contents,
- write files,
- run arbitrary shell commands with unrestricted filesystem access,
- run tests or builds.

The goal is to let the agent answer:

```text
Which files are relevant?
Which directories matter?
Which files should be opened?
Which files might need to be written?
```

At the end of discovery, the agent should declare a scope:

```json
{
  "files_to_read": ["..."],
  "files_to_write_or_maybe_write": ["..."],
  "directories_used_for_discovery": ["..."],
  "reason": "..."
}
```

This declaration is not just prose. It becomes explicit workflow metadata.

## Phase 2: Execution

Execution receives:

- the goal prompt,
- predecessor summaries,
- workspace snapshot metadata,
- the declared discovery scope.

Allowed operations:

- read declared files,
- write declared output files,
- run tests or validation commands,
- request an explicit scope extension if more files are needed.

If the agent needs to read or write a path outside the declared scope, it should
request a scope extension. The harness records that event, updates the scope,
and continues.

This makes hidden context acquisition observable:

```text
discover -> declare scope -> execute within scope -> request extension if needed
```

## Access Classification

Two-phase execution separates access metadata by phase:

```text
DiscoveryAccess:
  DirectoryRead
  MetadataRead

ExecutionAccess:
  ContentRead
  Write
  TestOrValidationRead
```

The current conservative baseline treats metadata reads as normal reads. A
two-phase design gives us room to interpret discovery metadata more carefully.

For example:

```text
Task A discovery:
  stat foo

Task B:
  write foo
```

This may be a weak dependency signal by itself.

But if discovery leads to:

```json
{
  "files_to_read": ["foo"]
}
```

then a concurrent write to `foo` is stronger evidence that `Task A` should be
rerun after `Task B` if the serial order requires it.

## Conflict Policy

The first two-phase policy could be:

```text
Execution Write conflicts with Execution ContentRead.
Execution Write conflicts with Execution Write.
Execution Write conflicts with declared files_to_read.
Execution Write conflicts with declared files_to_write_or_maybe_write.
Create/delete/rename under a discovered directory may conflict with that
directory discovery.
```

Pure discovery metadata reads may be recorded as weaker evidence until they are
connected to a declared read/write scope.

This is less conservative than the single-phase baseline, but it is also more
complex. It should therefore be evaluated against the baseline rather than mixed
into the first implementation.

## Tool Design

Two-phase execution is hard to enforce if the agent can call arbitrary shell
commands during discovery. For example, a `shell` tool can run `cat`, `sed`,
`rg`, tests, or package managers.

A more enforceable tool split is:

Discovery tools:

```text
list_dir
stat_path
find_path
declare_scope
```

Execution tools:

```text
read_file
write_file
shell
record_effect
request_scope_extension
```

Discovery mode should expose only discovery tools. Execution mode can expose the
normal editing and validation tools.

This also gives cleaner traces, because a discovery event is structurally
different from a content read or write event.

## Relationship To The Current Baseline

Two-phase execution should be treated as a later refinement.

The current baseline remains:

```text
single phase
record read/write access
conflict on write/access overlap
take former, rerun latter
```

The two-phase model should be introduced after the conservative baseline can run
end to end. Then we can compare:

- how many conflicts the conservative baseline reports,
- how many conflicts two-phase execution reports,
- whether two-phase execution misses any real dependency,
- whether agent quality changes when it must plan file scope before reading.

This comparison is important because two-phase execution changes the agent's
behavior. It may reduce false dependencies, but it may also make simple tasks
more verbose or brittle.

## Open Questions

- Should discovery allow filename/path search over the whole workspace?
- Should metadata reads conflict with writes only when they lead to declared
  scope?
- How should validation commands be classified when they read much of the
  workspace?
- Should scope extensions force a return to discovery mode, or can they happen
  inside execution mode?
- Should declared scope be treated as a hard permission boundary or only as
  dependency metadata?

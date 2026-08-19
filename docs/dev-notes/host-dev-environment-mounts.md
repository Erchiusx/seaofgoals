# Host Dev Environment Mounts

## Problem

Real skills often assume the developer machine already has a useful execution
environment:

- language runtimes,
- package managers,
- dependency caches,
- database clients,
- service CLIs,
- project-specific tools,
- shell environment variables.

A bare container image is therefore the wrong default for many experiments. It
turns task execution into environment installation and hides the skill behavior
we are trying to study.

At the same time, mounting the whole host home directory into a task container is
too broad. It leaks unrelated state into the experiment, makes traces noisy, and
can let task side effects escape the workspace snapshot that the scheduler is
trying to merge.

The desired execution view is therefore host-derived, but not host-wide.

## Why Permissions Matter

SeaOfGoals is not trying to build a general-purpose security sandbox. The primary
goal is snapshot isolation:

```text
run each task on a separate workspace version
observe its reads and writes
merge or rerun based on conflicts
```

Snapshot isolation only applies to paths that are actually inside the managed
snapshot. If a task process can write to arbitrary host paths outside that
snapshot, those writes are not versioned, cannot be rolled back by rejecting the
task snapshot, and cannot be merged by the scheduler.

Permissions and mounts matter because they define the execution boundary around
the snapshot:

- which filesystem tree becomes `/workspace`,
- which host paths are visible as dependencies,
- which host paths can be written,
- where caches and logs go,
- whether external service sockets or credentials are reachable,
- which paths are included in dependency/conflict detection.

In this project, permission policy is therefore mostly about shaping observable
side effects, not about defending the user from untrusted code. The ideal policy
forces semantically important project edits into `/workspace`, while allowing
enough host-derived environment state for real tools to run.

For example:

```text
write /workspace/src/Foo.hs
  snapshot-managed, mergeable, participates in dependency detection

write /home/host/.cache/pip/...
  outside the workspace snapshot; useful environment noise for a demo

write /home/host/.config/tool/state.json
  outside the workspace snapshot; may be semantically important and hard to
  merge or rerun correctly
```

Rootless containerd only addresses the host privilege needed to create containers
and mounts as a normal user. It does not by itself decide which host paths should
be visible, which writes are versioned, or which effects the scheduler should
trust. Those are SeaOfGoals policy decisions.

## Execution View

The container should expose a small, stable layout:

```text
/workspace
  current task workspace snapshot, read-write

/deps
  selected host toolchains and dependency caches, preferably read-only

/cache
  experiment or task scoped writable cache

/tmp
  task scoped temporary directory

/home/sog
  small synthetic home directory
```

The real host `$HOME` should not be bind mounted read-write. If a skill needs a
home subdirectory, it should be declared explicitly and mounted with the narrowest
reasonable access mode.

Examples:

```text
~/.cargo/registry  -> /deps/cargo/registry  read-only
~/.cargo/git       -> /deps/cargo/git       read-only
~/.rustup          -> /deps/rustup          read-only
~/.cache/pip       -> /deps/pip-cache       read-only
project snapshot   -> /workspace           read-write
```

Environment variables should be rewritten to container paths:

```text
HOME=/home/sog
XDG_CACHE_HOME=/cache
PIP_CACHE_DIR=/cache/pip
CARGO_HOME=/deps/cargo
```

Writable caches should be scoped to the experiment or task unless sharing them is
an explicit part of the experiment.

## Bwrap Demo Backend

For the first human-free demo, a `bwrap` backend is a good fit because it can
reuse the host development environment without requiring a container image or a
prepared rootfs.

The intended demo shape is:

```text
bwrap:
  tmpfs /
  ro-bind /usr -> /usr
  ro-bind /etc -> /etc
  symlink /bin -> /usr/bin
  symlink /lib -> /usr/lib
  symlink /lib64 -> /usr/lib64
  proc /proc
  dev /dev
  bind task workspace -> /workspace
  bind task cache     -> /cache
  bind synthetic home -> /home/sog
  bind task tmp       -> /tmp
  setenv HOME /home/sog
  setenv XDG_CACHE_HOME /cache/xdg
  setenv XDG_STATE_HOME /cache/state
  setenv XDG_CONFIG_HOME /workspace/.sog/config
  chdir /workspace
```

This is not a security claim. The host system view is still broad enough to make
normal host tools available. The point is to avoid a container image while
forcing normal writes into a small set of managed writable sinks.

The first interface should stay pure and policy-oriented:

```text
BwrapExecutionView
  host root policy
  mounts
  env rewrites
  unset env keys
  default cwd

BwrapDemoPaths
  workspace host path
  cache host path
  synthetic home host path
  tmp host path
```

The runner can later turn this view into a real process execution. The policy
should remain separate from the process runner so the same execution view can be
tested without requiring `bwrap` on the host.

Compared with the rootless containerd backend:

- bwrap avoids image/rootfs setup and is better for host-derived demos,
- containerd remains better for prepared, reproducible environments,
- both should use the same workspace/cache/home confinement policy,
- both should feed dependency detection through `RootOnly` for the
  early demo.

## Compile-Time Mount Requirements

The skill compiler can generate mount requirements from the raw skill text. These
requirements are not final host paths. They are a request for capabilities that
the runtime can later resolve.

Example:

```json
{
  "mount_requirements": [
    {
      "name": "workspace",
      "kind": "workspace",
      "purpose": "task working tree",
      "access": "read_write",
      "container_path": "/workspace",
      "required": true
    },
    {
      "name": "python-cache",
      "kind": "host_cache",
      "purpose": "reuse Python package cache",
      "access": "read_only",
      "host_path_candidates": [
        "~/.cache/pip",
        "~/.cache/uv",
        "~/.local/share/uv"
      ],
      "container_path": "/deps/python",
      "required": false
    }
  ],
  "env_rewrites": {
    "HOME": "/home/sog",
    "XDG_CACHE_HOME": "/cache"
  }
}
```

The compiler should prefer semantic requirement kinds over absolute host paths.
Suggested initial kinds:

```text
workspace
host_toolchain
host_cache
task_cache
socket
credential
service_data
temp
```

Suggested access modes:

```text
read_only
read_write
socket
forbidden_by_default
```

Credentials and service sockets should default to `forbidden_by_default` unless a
later policy explicitly allows them.

## Runtime Resolution

Before running an experiment, the harness resolves compile-time requirements into
a concrete mount plan:

```text
compile-time requirements
  -> expand host path candidates
  -> check existence and permissions
  -> apply allowlist and sensitivity policy
  -> rewrite environment variables
  -> produce final mount plan
```

The resolver, not the model, should decide which concrete host paths are usable.
It should also reject broad mounts such as `$HOME` or `/` unless a user explicitly
approves them for the experiment.

The final plan should be recorded with the run metadata so the experiment is
reproducible.

## User Review

For human-reviewed runs, the resolved mount plan can be shown to the user before
execution.

The review should make these facts explicit:

- host path,
- container path,
- access mode,
- reason or requirement name,
- whether the mount is required,
- whether it is sensitive,
- what environment variables will be rewritten.

The user can then approve, deny, or edit the plan. This review step is important
because mount choices can expose private files, credentials, sockets, caches, or
host service state.

For human-free experiments, the same decision point should be implemented as a
deterministic policy gate instead of an interactive prompt. The policy chooses
between explicit modes such as:

```text
DemoWorkspaceOnlyEffects
DemoReadOnlyHostHome
DemoUnsafeBindHome
StrictCuratedMounts
```

The run metadata should record the selected policy and resolved mount plan so the
experiment remains auditable.

For a human-reviewed run, the rendered plan could look like:

```text
Mount plan for mysql2postgres:

rw  /run/sog/workspaces/<id>  -> /workspace     required  workspace snapshot
rw  /run/sog/cache/<id>       -> /cache         required  task cache
ro  /home/user/.cache/pip     -> /deps/python   optional  Python cache

Environment rewrites:
HOME=/home/sog
XDG_CACHE_HOME=/cache

Approve this mount plan? [y/N]
```

Later versions can support saved approvals or project-level policies, but the
baseline should keep the review explicit.

## Baseline Policy

The first safe baseline should allow only:

- workspace snapshot as read-write,
- task temp and task cache as read-write,
- language toolchains and package caches as read-only,
- explicitly configured prepared rootfs or image,
- no credentials or service sockets by default.

This gives task containers enough of the host development environment to run
real skills, while keeping scheduler-visible side effects concentrated in the
workspace snapshot and scoped cache.

## Demo Effect Scope

For early demos, SeaOfGoals may use a deliberately narrower effect model:

```text
Only effects under /workspace participate in dependency detection and merge.
Writes outside /workspace are treated as cache, log, or host-environment noise.
```

This lets a demo reuse more of the host development environment without turning
every package-manager cache update or shell history write into a scheduler
conflict.

The demo policy should still record ignored external effects for inspection, but
the scheduler should compute conflicts only from the scoped workspace accesses.

Example:

```text
read  /workspace/src/Input.sql     participates in dependency detection
write /workspace/schema/output.sql participates in dependency detection
write /home/host/.cache/tool/...   recorded, but ignored by the demo scheduler
write /home/host/.local/log/...    recorded, but ignored by the demo scheduler
```

This is not a long-term correctness claim. Some writes outside `/workspace` can
be semantically important, such as daemon state, package-manager lock state,
generated configuration, service data, credentials, or external build volumes.
The demo policy is useful only because it keeps the first scheduler experiment
focused on project-file dependencies.

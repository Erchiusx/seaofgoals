# mcp-release-prep I/O-heavy experiment

Both runs used `gpt-5.6`, Pi, bwrap, the same fixture, and the same direct
underlying Node commands. Both final workspaces pass
`scripts/check-release.mjs --require-artifact` and contain 22,407 generated
files: 48 MB of build output, 41 MB of test output, and an 876 KB package.

## Concurrent SOG

Trace wall time: **195.0 s**. A compile/test command is classified as write
because it creates a large output tree even though the generic trace analyzer
currently classifies an arbitrary bash command as read unless it recognizes a
write verb.

| Goal | Work | Read rounds / time | Write rounds / time | Active time |
| --- | --- | ---: | ---: | ---: |
| G000 | Inspect workspace and publish per-goal preload plans | 9 / 83.6 s | 0 / 0.0 s | 83.6 s |
| G001 | Inspect release inputs and command contract | 2 / 20.1 s | 0 / 0.0 s | 20.1 s |
| G002 | Update package, manifest, and plugin metadata | 0 / 0.0 s | 1 / 10.9 s | 10.9 s |
| G003 | Update four release documents | 1 / 14.3 s | 1 / 14.9 s | 29.2 s |
| G004 | Build changelog from local `(mcp)` commit input | 1 / 5.5 s | 1 / 10.4 s | 15.9 s |
| G005 | Generate 6,001 sources and compile the build tree | 0 / 0.0 s | 1 / 10.6 s | 10.6 s |
| G006 | Generate 5,201 sources, compile tests, and check release files | 0 / 0.0 s | 1 / 9.8 s | 9.8 s |
| G007 | Read the build tree and write the MCPB package | 0 / 0.0 s | 1 / 5.3 s | 5.3 s |
| G008 | Run the integrated final checker | 1 / 4.3 s | 0 / 0.0 s | 4.3 s |

G005 and G006 entered together. Their shell commands ran from 11:04:59.370
to 11:05:05.607 and from 11:04:59.778 to 11:05:04.836 respectively, so the
heavy build and test I/O overlapped as intended.

## Single Pi baseline

Trace wall time: **132.7 s**. The baseline received the raw skill and task,
not the compiled graph. It preserved the skill's build, test, and package
order, while batching independent file edits within one model turn.

| Corresponding goal | Work | Read rounds / time | Write rounds / time | Active time |
| --- | --- | ---: | ---: | ---: |
| G001 | Discover and inspect release inputs | 4 / 34.2 s | 0 / 0.0 s | 34.2 s |
| G002-G004 | Update all disjoint release files; includes one failed `apply_patch` attempt | 1 / 7.1 s | 2 / 38.2 s | 45.3 s |
| G005 | Build TypeScript output | 0 / 0.0 s | 1 / 10.9 s | 10.9 s |
| G006 | Compile test output and check release files | 0 / 0.0 s | 1 / 9.5 s | 9.5 s |
| G007 | Package build output | 0 / 0.0 s | 1 / 6.0 s | 6.0 s |
| G008 | Final checker and artifact inspection | 2 / 17.7 s | 0 / 0.0 s | 17.7 s |

The concurrent run saves roughly one build/test stage on that branch, but the
83.6 s G000 planning phase and separate model sessions dominate this fixture.
For this sample, SOG is 1.47x slower by trace wall time (`195.0 / 132.7`).

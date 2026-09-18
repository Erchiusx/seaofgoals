# cargo-fuzz candidate fixture

This fixture turns the raw `cargo-fuzz` skill into three independent, bounded
fuzz campaigns: `decode-frame`, `normalize-segments`, and `decode-runs`.

Each target has its own standard `fuzz/corpus/<target>/` and
`fuzz/artifacts/<target>/` directories.  A campaign must use a bounded
libFuzzer duration, for example:

```bash
cargo +nightly fuzz run decode-frame -- -max_total_time=60
```

The intended comparison is a natural single-agent baseline, a single agent
which elects to launch campaigns concurrently, and SeaOfGoals candidate
partitions.  Do not use cargo-fuzz's experimental `--jobs` mode: separate
targets are the experimental units.

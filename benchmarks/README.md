# Scan performance validation

No end-to-end speedup, battery-life improvement, E-core affinity, idle-core reservation,
or absence of fan noise is claimed. Utility QoS expresses scheduling intent only.
The earlier PR numbers had no reproducible logs and mixed incompatible baselines.

## Traversal microbenchmark (macOS)

Run `BENCH_RUNS=7 bash scripts/benchmark_scan.sh /absolute/root /another/disjoint/root > samples.jsonl`.
Use a static, fully readable fixture. The harness alternates Foundation, serial FTS, and
bounded parallel FTS order and rejects unequal file counts, allocated bytes, or errors.
One root cannot benefit from root-level parallelism. This is not a full-volume backend benchmark.
Report medians and dispersion from the JSONL samples, not the best isolated run.
These runs share filesystem caches; do not label them cold-cache measurements.

For a base/head app comparison, build both commits in Release with the same Swift toolchain.
Record commit SHAs, Mac model/SoC, macOS/toolchain, storage and filesystem, dataset file count,
power source, Low Power Mode, initial thermal state, and Full Disk Access. Alternate build order;
compare the same categories or the same full-volume root and count all warnings. Retain raw logs.
Use separate first-run and repeated-run series with an explicitly documented cache-reset method.

Measure elapsed time, user/system CPU time, peak RSS, UI responsiveness, and cancellation latency.
Use Instruments/System Trace and Energy Log (or available power instrumentation on that Mac)
to measure total energy over the scan, not just peak CPU percentage. Repeat on Intel and Apple
Silicon, battery and AC, with Low Power Mode on/off. Test a non-NVMe/external or network volume
before making storage-independent claims. Do not infer a speedup from worker counts.

## Resource limits and failure semantics

- Legacy stages share an OperationQueue: 2 workers normally; 1 on <=2 processors, Low Power Mode,
  or any non-nominal thermal state. Notifications update admission limits; in-flight calls drain.
- Backend requests use traversal=2, classification=1 per directory, atomic=2 normally; all 1 in
  the conservative profile. These are per-stage limits, not a process-wide thread cap. Leaf
  preparation and the separate legacy scanner may also be active.
- A power/thermal change requiring fewer backend workers cancels the current scan. The UI
  explains that a retry uses fewer workers. Blocking filesystem calls are not forcibly interrupted.
- FTS is physical, does not change cwd, and stays on the root device. Missing optional roots are
  empty; unreadable or failed traversals are incomplete and excluded from cleanup estimates.
- `st_blocks * 512 / st_nlink` is attributed allocation, not exact reclaimable space. Hard links,
  APFS clones, snapshots and open files prevent interpreting it as guaranteed free space.

Run `CLEARDISK_TEST_MOUNTS=1 swift test` on macOS for the mounted-image regression test.
Run the measurement tests with Thread Sanitizer separately. Compressed files,
iCloud placeholders and live filesystem mutation also require macOS validation before merge.

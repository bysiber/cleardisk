#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$(mktemp -d /tmp/cleardisk-bench.XXXXXX)"
trap 'rm -rf "$BENCH_DIR"' EXIT
swiftc -O -o "$BENCH_DIR/scan-benchmark" \
    "$ROOT/Sources/ClearDisk/DirectoryMeasurement.swift" \
    "$ROOT/Sources/ClearDisk/ScanResourcePolicy.swift" \
    "$ROOT/benchmarks/ScanBenchmark.swift"
"$BENCH_DIR/scan-benchmark" "$@"

"""Verify the counter schema and run the native trace writer against a stub core."""
import argparse
import json
import pathlib
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=pathlib.Path, help="Instrumented MeloNX worktree")
parser.add_argument("--schema", type=int, default=3, help="Expected trace schema")
args = parser.parse_args()
common = args.source.resolve() / "src/MeloNX/MeloNX/Common"
managed = args.source / "src/Ryujinx.Common/A19Probe.cs"
count = int(re.search(r"public const int Count = (\d+);", managed.read_text())[1])
swift = (common / "A19Lab.swift").read_text()
names = re.findall(r'"([a-zA-Z0-9_]+)"', swift.split("private let a19Names: [String] = [", 1)[1].split("]", 1)[0])
if len(names) != count or len(set(names)) != count:
    raise SystemExit("Swift and managed counter layouts differ")

with tempfile.TemporaryDirectory() as temp:
    stage = pathlib.Path(temp)
    harness = stage / "trace.c"
    harness.write_text("""
#include <stdint.h>
#include <stdio.h>
#include <time.h>

int32_t a19_trace_start(const char *);
void a19_trace_stop(void);
int32_t a19_trace_count(void);
int32_t a19_trace_error(void);
int64_t a19_probe_frequency(void) { return 1000000000; }
int32_t a19_probe_read(int64_t *out, int32_t count) {
    if (count != MANAGED_COUNTERS) return 0;
    for (int32_t index = 0; index < count; index++) out[index] = index;
    return count;
}
int main(int argc, char **argv) {
    if (argc != 2 || !a19_trace_start(argv[1])) return 1;
    const struct timespec delay = { 0, 10000000 };
    for (int index = 0; index < 300 && !a19_trace_count() && !a19_trace_error(); index++) {
        nanosleep(&delay, NULL);
    }
    a19_trace_stop();
    return a19_trace_error() || !a19_trace_count();
}
""")
    executable = stage / "trace"
    trace = stage / "trace.jsonl"
    subprocess.run(
        ["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", f"-DMANAGED_COUNTERS={count}",
         "-Wall", "-Wextra", "-Werror", "-pthread", str(harness),
         str(common / "A19Bench.c"), "-o", str(executable)],
        check=True,
    )
    subprocess.run([str(executable), str(trace)], check=True)
    header, *samples = map(json.loads, trace.read_text().splitlines())
    if header["schemaVersion"] != args.schema or header["counterNames"] != names:
        raise SystemExit("Native and Swift trace schemas differ")
    if not samples or any(sample["counters"] != list(range(count)) for sample in samples):
        raise SystemExit("Native trace did not record every counter in order")
    print(f"PASS native JSONL writer, schema {args.schema}, {count} counters")

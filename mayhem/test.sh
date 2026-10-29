#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# 1) The project's own unit tests (silent on success, abort on a failed assertion).
passed=0 ; failed=0
for t in "$SRC"/build/tests/test_*; do
  [ -x "$t" ] || { echo "missing test runner $t (build.sh bug)" >&2; failed=$((failed+1)); continue; }
  if "$t" >/dev/null 2>&1; then passed=$((passed+1)); else echo "FAIL: $(basename "$t")" >&2; failed=$((failed+1)); fi
done
[ "$(ls "$SRC"/build/tests/test_* 2>/dev/null | wc -l)" -gt 0 ] || { echo "no unit tests built" >&2; failed=$((failed+1)); }

# 2) Known-answer checks through the jsoninfo CLI (the unit tests are exit-code only, so these
#    assert real output: a program that is neutered to exit(0) produces no/empty output and fails).
JI="$SRC/build/tests/jsoninfo"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
printf '{"a":[1,2.5,"x\\u00e9/",null,true],"b":{"c":false}}' > "$W/in.json"

expect_file() {  # <name> <expected-content> <file>
  if [ -f "$3" ] && [ "$(cat "$3")" = "$2" ]; then passed=$((passed+1)); else echo "FAIL: $1" >&2; failed=$((failed+1)); fi
}

"$JI" -m -o "$W/min.json" "$W/in.json" >/dev/null 2>&1
expect_file "minify" '{"a":[1,2.5,"xé/",null,true],"b":{"c":false}}' "$W/min.json"

"$JI" -m -e -s -o "$W/esc.json" "$W/in.json" >/dev/null 2>&1
expect_file "minify+escape" '{"a":[1,2.5,"x\u00E9\/",null,true],"b":{"c":false}}' "$W/esc.json"

"$JI" -p -o "$W/pretty.json" "$W/in.json" >/dev/null 2>&1
expect_file "pretty" '{
    "a": [
        1,
        2.5,
        "xé/",
        null,
        true
    ],
    "b": {
        "c": false
    }
}' "$W/pretty.json"

"$JI" "$W/in.json" 2>&1 | sed 's/^name: .*/name: in/' > "$W/info.txt"
expect_file "info" 'name: in
size: 50
vals: 12
  arr:  1
  obj:  2
  str:  4
  int:  1
  real: 1
  bool: 2
  null: 1' "$W/info.txt"

printf '{"a":' > "$W/bad.json"
"$JI" "$W/bad.json" > "$W/bad.txt" 2>&1
expect_file "read error" 'JSON read fail: unexpected end of data, position:5' "$W/bad.txt"

emit_ctrf "yyjson-unit+jsoninfo-golden" "$passed" "$failed" 0

#!/usr/bin/env bash
# LISP/mayhem/test.sh — GOLDEN / known-answer oracle for krig/LISP's komplott interpreter.
#
# komplott ships a `make test` target that simply runs the interpreter over the example LISP
# programs in tests/ and eyeballs the output. We turn the DETERMINISTIC programs into a
# known-answer functional oracle:
#
#   * mayhem/build.sh built /mayhem/komplott-tests with the project's NORMAL flags (NO sanitizer),
#     so the oracle exercises the real shipped interpreter behavior and never false-fails on benign
#     UB. This script only RUNS that binary — it never compiles (PATCH grading: patch -> build.sh
#     -> test.sh).
#   * For each example program it runs the interpreter and DIFFs combined stdout+stderr against a
#     committed golden file (mayhem/testdata/golden/<name>.out). The goldens were captured once from
#     the normal-flags binary and verified byte-stable across repeated runs.
#
# This is a PATCH-grade, anti-reward-hack oracle by construction: it asserts the EXACT computed
# OUTPUT of each program — e.g. (exp 2 16) => 65536, factorial(15) => 1307674368000, the
# self-hosted LISP-in-LISP `eval` results, sum-of-prefixes lists — not merely "exited 0". A no-op /
# exit(0) "patch", or any change that breaks the reader/evaluator so a program stops producing its
# correct output, FAILS the diff.
#
# tests/true-tco.scm is DELIBERATELY EXCLUDED: it documents komplott's lack of true tail-call
# optimization and intentionally overflows the C stack (aborts), so it is not a passing oracle.
set -uo pipefail

# clang/gcc reject SOURCE_DATE_EPOCH='' (empty); must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

# SRC is /mayhem in the commit image; default to this checkout's repo root so the suite also runs
# straight from a developer checkout (mayhem/ is one level below the repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SRC:=$(cd "$HERE/.." && pwd)}"
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

# The normal-flags oracle binary that build.sh produced.
BIN="$SRC/komplott-tests"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; emit_ctrf "komplott-golden" 0 1; exit 2; }

GOLDEN="$SRC/mayhem/testdata/golden"
[ -d "$GOLDEN" ] || { echo "missing golden dir $GOLDEN — wrong tree?" >&2; emit_ctrf "komplott-golden" 0 1; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0

# run_case <name> <scm-file>
# Runs the interpreter on tests/<file>, diffs combined stdout+stderr against
# mayhem/testdata/golden/<name>.out. MUST exit 0 AND match the golden byte-for-byte.
run_case() {
  local name="$1" prog="$2"
  local gold="$GOLDEN/$name.out" got="$WORK/$name.out" rc
  if [ ! -f "$gold" ]; then
    echo "FAIL $name: missing golden $gold" >&2; failed=$((failed+1)); return
  fi
  if [ ! -f "$SRC/$prog" ]; then
    echo "FAIL $name: missing program $SRC/$prog" >&2; failed=$((failed+1)); return
  fi
  "$BIN" "$SRC/$prog" > "$got" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name: komplott $prog exited $rc (expected 0)" >&2
    sed 's/^/    /' "$got" >&2
    failed=$((failed+1)); return
  fi
  if diff -u "$gold" "$got" > "$WORK/$name.diff" 2>&1; then
    echo "PASS $name"; passed=$((passed+1))
  else
    echo "FAIL $name: output differs from golden" >&2
    head -20 "$WORK/$name.diff" | sed 's/^/    /' >&2
    failed=$((failed+1))
  fi
}

# Deterministic example programs from tests/. Each exercises a different interpreter path:
#   test    — the full Little-Schemer-style suite (assert/pass markers, recursion, self-eval)
#   exp     — exponent recursion -> 65536
#   lisp15  — LISP 1.5 example battery (assoc/pairlis/eval results)
#   old     — early sample (mapcar, ff, basic defines)
#   odin    — factorial(15) -> 1307674368000 + assertions
run_case test   tests/test.scm
run_case exp    tests/exp.scm
run_case lisp15 tests/lisp15.scm
run_case old    tests/old.scm
run_case odin   tests/odin.scm

emit_ctrf "komplott-golden" "$passed" "$failed"

#!/usr/bin/env bash
# LISP/mayhem/build.sh — build krig/LISP's `komplott` interpreter as the fuzz target.
#
# komplott (komplott.c) is a small, single-file LISP 1.5 interpreter in C. main() reads a LISP
# source file from a CLI path argument (argv[1]) — or stdin when none is given — then READS,
# EVALs and PRINTs each top-level form (lisp_read / lisp_eval / lisp_print) until EOF, at which
# point read_token() calls exit(0). The natural fuzz surface is the interpreter itself on a source
# file, so the Mayhem target is FILE-INPUT (CLI): `/mayhem/komplott @@` runs komplott on the fuzz
# bytes as a LISP program (read + eval + print). No libFuzzer harness, and therefore no per-harness
# *-standalone reproducer — the interpreter binary IS the reproducer (run it on the crashing file).
# The target name `komplott` is kept from the old fork integration (old Mayhemfile: `/komplott @@`).
#
# We compile the WHOLE interpreter with $SANITIZER_FLAGS (ASan+UBSan, halting, by default) so the
# fuzzed code — reader, evaluator, GC — is instrumented, not just an entry shim. The fuzz target
# lands at /mayhem/komplott.
#
# build.sh produces TWO binaries from the same single-file source:
#   (1) /mayhem/komplott        — SANITIZED fuzz target (ASan+UBSan halting, by default)
#   (2) /mayhem/komplott-tests  — NORMAL-flags oracle binary for mayhem/test.sh (no sanitizers, so
#                                 the golden suite exercises real shipped behavior and never
#                                 false-fails on benign UB the fuzz build would halt on). test.sh
#                                 only RUNS this binary (it never compiles).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the base ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit
# empty value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (the interpreter's
# natural crash). komplott links only libc (no extra libs), so the empty-sanitizer build links
# cleanly with no additional flags.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# komplott's upstream Makefile compiles with `-g -Og -Wall -Werror -std=c11`. We keep the c11
# dialect but drop -Werror (it would turn any clang-version warning diff into a hard build break)
# and let $SANITIZER_FLAGS supply -g / -O level. No benign-UB relaxation is needed: under halting
# ASan+UBSan the interpreter runs every shipped test program to exit 0 with no sanitizer output,
# and reports no leaks (verified during integration), so the full sanitizer set stays ON and HALTING.

# ---------------------------------------------------------------------------
# (1) FUZZ build — the interpreter compiled WITH $SANITIZER_FLAGS so the fuzzed code (reader,
#     evaluator, GC) is instrumented. File-input Mayhem target lands at /mayhem/komplott.
# ---------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c11 -Wall -o /mayhem/komplott komplott.c

# ---------------------------------------------------------------------------
# (2) TEST-ORACLE build — the SAME source with the project's NORMAL flags (no sanitizer), for
#     mayhem/test.sh's golden-output suite. A clean, independent build so the oracle reflects real
#     shipped behavior; test.sh only RUNS this binary.
# ---------------------------------------------------------------------------
$CC -g -Og -Wall -std=c11 -o /mayhem/komplott-tests komplott.c

echo "build.sh: built /mayhem/komplott (sanitized fuzz target) and /mayhem/komplott-tests (test oracle)"
ls -l /mayhem/komplott /mayhem/komplott-tests

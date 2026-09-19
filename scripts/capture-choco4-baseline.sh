#!/usr/bin/env bash
# Capture the golden-oracle behavioral baseline of chocosolver instance
# generation over a corpus of Clafer Choco models (Sigil-Logic/chocosolver#2,
# Stage 0 of the Choco-solver 6.0.1 alignment epic, chocosolver#1).
#
# Usage: capture-choco4-baseline.sh [OUTDIR] [CORPUS_ROOT]
#
#   OUTDIR       output directory (default: baseline-out; must not exist or be empty)
#   CORPUS_ROOT  directory whose immediate subdirectories are corpus classes
#                holding .js (and optionally .cfr) models
#                (default: src/test/resources)
#
# Environment:
#   CHOCOSOLVER_JAR  jar under test (default: target/chocosolver-0.4.4-jar-with-dependencies.jar)
#   CLAFER           clafer compiler for .cfr inputs (default: none — .cfr models are
#                    recorded as "skipped: no compiler"); the reference capture used the
#                    Sigil clafer fork, see environment.txt
#   REDUCED          TSV of reduced configurations (default:
#                    .evidence/choco4-baseline/reduced-configurations.tsv); columns
#                    <model> <flags> <note>; the flags REPLACE the model-declared int
#                    range, and when <REDUCED_MODELS>/<class>/<model>.js exists that
#                    derived model is captured instead of the corpus model
#   REDUCED_MODELS   directory of derived models (default:
#                    .evidence/choco4-baseline/reduced-models)
#   EXCLUDED         TSV of excluded models (default:
#                    .evidence/choco4-baseline/exclusions.tsv); columns <model> <reason>;
#                    an excluded model is recorded in summary.tsv with its reason and
#                    not run (its full instance set is not enumerable)
#   TIMEOUT          per-run wall-clock budget in seconds (default: 300)
#   CAP              instance cap (default: 300000); reaching it is a harness-level failure
#   STORE_LIMIT      bytes; above it a model's raw dump and canonical text are dropped
#                    after hashing and only the count and SHA-256 are kept
#                    (default: 4000000)
#
# Per model the capture runs the jar from inside the model's own work directory:
#   instantiate (default):  --file model.js --search PreferSmallerInstances
#                           --minint <lo> --maxint <hi> -n CAP --output instances.txt
#   validate (class dir named assert-*):  the same with -v (no -n; validation
#                           ignores the cap and enumerates every counterexample)
#   unsat (instantiate produced 0 instances and exit 0):  additionally
#                           --repl with the commands minUnsat, unsatCore, quit -> unsat.txt
# <lo>,<hi> is the model's own intRange(lo, hi) directive, which the CLI would
# otherwise silently widen to [-128, 127]; models without the directive get no
# int flags.  Instances are canonicalized into an order-insensitive set by
# scripts/canonicalize-choco-instances.py.
#
# Model-level outcomes — exit 0, or exit 1 with an error recorded on
# stdout/stderr (JavaScript evaluation errors, solver exceptions), and compile
# errors — are evidence and are recorded, not failed on.  Harness-level failures
# — any other exit status (timeout, invocation failure, signal), an exit 1
# without error text, an unsat-core REPL run that neither succeeds nor records
# an exception, a model reaching CAP, a malformed dump — fail the capture so structurally-present-but-invalid
# evidence is never published.  environment.txt records the solver source
# commit and tree state, the SHA-256 of each harness script, and the compiler
# binary hash and tree state, so evidence is tied to the exact producing bytes.
set -euo pipefail

OUT="${1:-baseline-out}"
CORPUS="${2:-src/test/resources}"
JAR="${CHOCOSOLVER_JAR:-target/chocosolver-0.4.4-jar-with-dependencies.jar}"
REDUCED="${REDUCED:-.evidence/choco4-baseline/reduced-configurations.tsv}"
REDUCED_MODELS="${REDUCED_MODELS:-.evidence/choco4-baseline/reduced-models}"
EXCLUDED="${EXCLUDED:-.evidence/choco4-baseline/exclusions.tsv}"
TIMEOUT="${TIMEOUT:-300}"
CAP="${CAP:-300000}"
STORE_LIMIT="${STORE_LIMIT:-4000000}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$HERE/canonicalize-choco-instances.py"

if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  echo "error: output directory '$OUT' exists and is not empty; refusing to overlay a prior capture" >&2
  exit 1
fi
command -v timeout > /dev/null || { echo "error: GNU timeout not found (coreutils)" >&2; exit 1; }
command -v java > /dev/null || { echo "error: java not found" >&2; exit 1; }
command -v python3 > /dev/null || { echo "error: python3 not found" >&2; exit 1; }
[ -f "$JAR" ] || { echo "error: jar not found at $JAR (run 'mvn -DskipTests package' first)" >&2; exit 1; }
[ -f "$CANON" ] || { echo "error: canonicalizer not found at $CANON" >&2; exit 1; }
[ -d "$CORPUS" ] || { echo "error: corpus root '$CORPUS' is not a directory" >&2; exit 1; }
if [ -n "${CLAFER:-}" ] && ! command -v "$CLAFER" > /dev/null && [ ! -x "$CLAFER" ]; then
  echo "error: CLAFER='$CLAFER' is not executable" >&2; exit 1
fi

JAR_ABS="$(cd "$(dirname "$JAR")" && pwd)/$(basename "$JAR")"
REDUCED_ABS=""
if [ -f "$REDUCED" ]; then REDUCED_ABS="$(cd "$(dirname "$REDUCED")" && pwd)/$(basename "$REDUCED")"; fi
REDUCED_MODELS_ABS=""
if [ -d "$REDUCED_MODELS" ]; then REDUCED_MODELS_ABS="$(cd "$REDUCED_MODELS" && pwd)"; fi
EXCLUDED_ABS=""
if [ -f "$EXCLUDED" ]; then EXCLUDED_ABS="$(cd "$(dirname "$EXCLUDED")" && pwd)/$(basename "$EXCLUDED")"; fi
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Report a path relative to the repository root when it lies inside it (portable
# environment.txt), absolute otherwise.
relpath() { case "$1" in "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}";; *) printf '%s' "$1";; esac; }
# clean/dirty state of a git tree, for provenance.
treestate() { if [ -z "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ]; then echo clean; else echo "dirty ($(git -C "$1" status --porcelain --untracked-files=no | wc -l | tr -d ' ') tracked files modified)"; fi; }

shopt -s nullglob
models=()
for class_dir in "$CORPUS"/*/; do
  for f in "$class_dir"*.js "$class_dir"*.cfr; do models+=("$f"); done
done
[ "${#models[@]}" -gt 0 ] || { echo "error: empty corpus under $CORPUS" >&2; exit 1; }

sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

mkdir -p "$OUT"
{
  echo "date-utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "chocosolver: $(java -jar "$JAR_ABS" --version 2>&1 | head -1)"
  echo "jar: $JAR"
  echo "jar-sha256: $(sha256 "$JAR_ABS")"
  echo "chocosolver-commit: $(git rev-parse HEAD 2>/dev/null || echo unavailable)"
  echo "chocosolver-tree: $(treestate "$REPO_ROOT")"
  for h in capture-choco4-baseline.sh canonicalize-choco-instances.py compare-choco-baselines.py publish-choco4-baseline.py; do
    [ -f "$HERE/$h" ] && echo "harness-sha256: $(sha256 "$HERE/$h")  $(relpath "$HERE/$h")"
  done
  echo "java: $(java -version 2>&1 | head -1)"
  echo "maven: $(mvn -version 2>/dev/null | head -1 || echo unavailable)"
  echo "arch: $(uname -m)  os: $(uname -s)"
  if [ -n "${CLAFER:-}" ]; then
    echo "clafer: $("$CLAFER" --version 2>&1 | head -1)  ($CLAFER)"
    cbin="$(command -v "$CLAFER" || echo "$CLAFER")"
    cdir="$(dirname "$cbin")"
    echo "clafer-commit: $(git -C "$cdir" rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "clafer-tree: $(git -C "$cdir" rev-parse HEAD > /dev/null 2>&1 && treestate "$cdir" || echo unavailable)"
    echo "clafer-binary-sha256: $(sha256 "$cbin")"
  else
    echo "clafer: none (.cfr models skipped)"
  fi
  echo "corpus: $CORPUS (${#models[@]} models)"
  echo "reduced-configurations: $([ -n "$REDUCED_ABS" ] && relpath "$REDUCED_ABS" || echo none)"
  echo "reduced-models: $([ -n "$REDUCED_MODELS_ABS" ] && relpath "$REDUCED_MODELS_ABS" || echo none)"
  echo "exclusions: $([ -n "$EXCLUDED_ABS" ] && relpath "$EXCLUDED_ABS" || echo none)"
  echo "cap: $CAP  timeout: ${TIMEOUT}s  store-limit: $STORE_LIMIT bytes"
  echo "invocation: java -jar <jar> --file model.js --search PreferSmallerInstances --minint <lo> --maxint <hi> [-n $CAP | -v] --output instances.txt  (timeout ${TIMEOUT}s per run; unsat: --repl < 'minUnsat, unsatCore, quit')"
} > "$OUT/environment.txt"

printf 'class\tmodel\tmode\tconfig\tflags\texit\traw\tunique\tcanon-sha256\tnote\n' > "$OUT/summary.tsv"
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$OUT/summary.tsv"; }

fail() { echo "error: harness-level failure on $1: $2" >&2; exit 1; }

for f in "${models[@]}"; do
  class="$(basename "$(dirname "$f")")"
  ext="${f##*.}"
  base="$(basename "$f" ".$ext")"
  if [ -n "$EXCLUDED_ABS" ]; then
    reason="$(awk -F'\t' -v m="$base" 'NR>1 && $1==m {print $2; exit}' "$EXCLUDED_ABS")"
    if [ -n "$reason" ]; then row "$class" "$base" excluded declared - - - - - "$reason"; continue; fi
  fi
  work="$OUT/$class/$base"
  mkdir -p "$work"
  note=""
  config=declared
  if [ "$ext" = cfr ]; then
    cp "$f" "$work/model.cfr"
    if [ -z "${CLAFER:-}" ]; then
      row "$class" "$base" skipped declared - - - - - "no clafer compiler (set CLAFER)"
      continue
    fi
    crc=0
    ( cd "$work" && "$CLAFER" -k -m choco model.cfr > compile.txt 2>&1 ) || crc=$?
    echo "$crc" > "$work/compile-exit.txt"
    if [ "$crc" -ne 0 ] || [ ! -s "$work/model.js" ]; then
      row "$class" "$base" compile-error declared - "$crc" - - - "clafer -k -m choco exit $crc: $(grep -m1 -o 'Compile error.*\|Name resolver.*\|Cannot .*' "$work/compile.txt" | head -1 | cut -c1-100)"
      continue
    fi
    note="compiled from model.cfr"
  else
    cp "$f" "$work/model.js"
  fi

  mode=instantiate
  case "$class" in assert-*) mode=validate;; esac

  flags=(--search PreferSmallerInstances)
  override=""
  if [ -n "$REDUCED_ABS" ]; then
    override="$(awk -F'\t' -v m="$base" 'NR>1 && $1==m {print $2; exit}' "$REDUCED_ABS")"
  fi
  if [ -n "$override" ]; then
    # shellcheck disable=SC2206
    flags+=($override)
    config=reduced
    if [ -n "$REDUCED_MODELS_ABS" ] && [ -f "$REDUCED_MODELS_ABS/$class/$base.js" ]; then
      cp "$REDUCED_MODELS_ABS/$class/$base.js" "$work/model.js"
      note="${note:+$note; }derived model $REDUCED_MODELS/$class/$base.js"
    fi
    note="${note:+$note; }reduced configuration: $(awk -F'\t' -v m="$base" 'NR>1 && $1==m {print $3; exit}' "$REDUCED_ABS")"
  else
    # `grep` exits 1 on a model without the directive; under `set -o pipefail` that
    # must not abort the capture (i239 declares no intRange and runs at the CLI default).
    range="$({ grep -o 'intRange([^)]*)' "$work/model.js" || true; } | head -1 | sed 's/intRange(//; s/)//; s/ //g')"
    if [ -n "$range" ]; then flags+=(--minint "${range%%,*}" --maxint "${range##*,}"); fi
  fi
  if [ "$mode" = validate ]; then flags=(-v "${flags[@]}"); else flags+=(-n "$CAP"); fi
  printf '%s\n' "${flags[*]}" > "$work/flags.txt"

  rc=0
  ( cd "$work" && timeout "$TIMEOUT" java -jar "$JAR_ABS" --file model.js "${flags[@]}" --output instances.txt > stdout.txt 2> stderr.txt ) || rc=$?
  echo "$rc" > "$work/exit.txt"
  # Model-level evidence is exit 0 or exit 1 (a Java uncaught exception or the CLI's own
  # System.exit(1)) with an error recorded on stdout/stderr.  Everything else — 124-127
  # (timeout tool), >= 128 (signal: killed/crashed JVM), or an exit 1 with no error text —
  # is a harness-level failure and must not be published as evidence.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then fail "$class/$base" "exit $rc (timeout, invocation failure, or signal)"; fi
  if [ "$rc" -eq 1 ] && ! grep -q 'Exception\|Error\|Aborting' "$work/stdout.txt" "$work/stderr.txt"; then
    fail "$class/$base" "exit 1 without a recorded error"
  fi
  [ -f "$work/instances.txt" ] || : > "$work/instances.txt"

  python3 "$CANON" "$work/instances.txt" "$work" || fail "$class/$base" "malformed instance dump"
  read -r kind raw unique digest < <(sed 's/[a-z0-9]*=//g' "$work/canon.summary.txt")
  if [ "$mode" = instantiate ] && [ "$raw" -ge "$CAP" ]; then fail "$class/$base" "reached the instance cap ($CAP); add a reduced configuration"; fi

  if [ "$mode" = validate ]; then
    grep '^  assert ' "$work/stdout.txt" | sed 's/^  //' | LC_ALL=C sort -u > "$work/assertions.canon.txt" || true
  fi
  if [ "$mode" = instantiate ] && [ "$rc" -eq 0 ] && [ "$raw" -eq 0 ] && grep -q '^Generated 0 instance' "$work/stdout.txt"; then
    urc=0
    ( cd "$work" && printf 'minUnsat\nunsatCore\nquit\n' | timeout "$TIMEOUT" java -jar "$JAR_ABS" --repl --file model.js "${flags[@]:0:${#flags[@]}-2}" > unsat.txt 2>&1 ) || urc=$?
    # The REPL run follows the same boundary as the main run: exit 0 with the minUnsat
    # output, or exit 1 with a recorded exception (chocosolver's own unsat-core machinery
    # raising on the model, e.g. UnsatisfiableException in FBBT), is model-level evidence;
    # any other status, or an exit 0 without the minUnsat output, is a harness-level failure.
    echo "$urc" > "$work/unsat-exit.txt"
    if [ "$urc" -eq 0 ]; then
      grep -q 'Min UNSAT command:' "$work/unsat.txt" || fail "$class/$base" "unsat-core REPL run produced no minUnsat output"
      note="${note:+$note; }instantiate produced 0 instances; minUnsat/unsatCore captured"
    elif [ "$urc" -eq 1 ] && grep -q 'Exception\|Error' "$work/unsat.txt"; then
      note="${note:+$note; }instantiate produced 0 instances; minUnsat raised $({ grep -o -m1 '[A-Za-z.]*Exception\|[A-Za-z.]*Error' "$work/unsat.txt" || true; } | tail -1 | sed 's/.*\.//')"
    else
      fail "$class/$base" "unsat-core REPL run exit $urc without a recorded error"
    fi
    mode=unsat
  fi
  if grep -q 'Error\|Exception' "$work/stdout.txt" "$work/stderr.txt" 2>/dev/null; then
    note="${note:+$note; }$({ grep -h -o -m1 '[A-Za-z.]*Error[^(]*\|[A-Za-z.]*Exception[^:]*' "$work/stdout.txt" "$work/stderr.txt" || true; } | head -1 | cut -c1-80)"
  fi
  if [ "$(wc -c < "$work/instances.canon.txt" | tr -d ' ')" -gt "$STORE_LIMIT" ]; then
    rm -f "$work/instances.txt" "$work/instances.canon.txt"
    note="${note:+$note; }hash-only: canonical text above STORE_LIMIT ($STORE_LIMIT bytes) dropped after hashing"
  fi
  row "$class" "$base" "$mode" "$config" "${flags[*]}" "$rc" "$raw" "$unique" "$digest" "$note"
done

# Integrity manifest over every captured per-model file plus the summary
# (environment.txt carries the capture date and is deliberately excluded, so the
# manifest is byte-reproducible on the same toolchain).
( cd "$OUT" && find . -type f ! -name environment.txt ! -name manifest.sha256 | LC_ALL=C sort | while read -r p; do
    if command -v sha256sum > /dev/null; then sha256sum "$p"; else shasum -a 256 "$p"; fi
  done > manifest.sha256 )
echo "baseline captured under $OUT: $(( $(wc -l < "$OUT/summary.tsv") - 1 )) models, $(wc -l < "$OUT/manifest.sha256" | tr -d ' ') files in manifest.sha256"

#!/usr/bin/env bash
# Self-test of the golden-oracle tooling (Sigil-Logic/chocosolver#2): negative and
# positive fixtures for canonicalize-choco-instances.py, compare-choco-baselines.py,
# publish-choco4-baseline.py, and the exit-status boundaries of
# capture-choco4-baseline.sh (driven through fake `java` and `clafer` shims on
# PATH).  No real solver run is needed; fixtures are synthetic.
#
# Usage: test-choco-baseline-tools.sh        (exit 0 when every case behaves as specified)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$HERE/canonicalize-choco-instances.py"
COMPARE="$HERE/compare-choco-baselines.py"
PUBLISH="$HERE/publish-choco4-baseline.py"
CAPTURE="$HERE/capture-choco4-baseline.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <expected-rc> <cmd...>
  local name="$1" want="$2"; shift 2; local rc=0
  "$@" > "$T/out.txt" 2> "$T/err.txt" || rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL $name: exit $rc, expected $want"; sed 's/^/    /' "$T/err.txt" | head -3; fi
}
HDR=$'class\tmodel\tmode\tconfig\tflags\texit\traw\tunique\tcanon-sha256\tnote'
mkmodel() { # mkmodel <root> <class> <model> <exit> <canon-text> [assertions-text]
  local d="$1/$2/$3"; mkdir -p "$d"; echo "$4" > "$d/exit.txt"
  printf '=== Instance 1 Begin ===\n\n%s \n\n--- Instance 1 End ---\n' "$5" > "$d/instances.txt"
  python3 "$CANON" "$d/instances.txt" "$d" > /dev/null
  [ $# -ge 6 ] && printf '%s\n' "$6" > "$d/assertions.canon.txt"
  read -r _ raw unique sha < <(sed 's/[a-z0-9]*=//g' "$d/canon.summary.txt")
  printf '%s\t%s\tinstantiate\tdeclared\t--search PreferSmallerInstances\t%s\t%s\t%s\t%s\t\n' "$2" "$3" "$4" "$raw" "$unique" "$sha" >> "$1/summary.tsv"
}
mkcapture() { # mkcapture <root> : two models + one excluded row, with manifest and environment
  local r="$1"; mkdir -p "$r"; echo "$HDR" > "$r/summary.tsv"
  mkmodel "$r" solve-positive alpha 0 "c0_A"
  mkmodel "$r" assert-positive beta 0 "c0_B" "assert c0_B"
  printf 'solve-positive\tgamma\texcluded\tdeclared\t-\t-\t-\t-\t-\treason\n' >> "$r/summary.tsv"
  mkdir -p "$r/failing/cx"; echo "abstract A" > "$r/failing/cx/model.cfr"; echo "Compile error at line 1" > "$r/failing/cx/compile.txt"; echo 1 > "$r/failing/cx/compile-exit.txt"
  printf 'failing\tcx\tcompile-error\tdeclared\t-\t1\t-\t-\t-\tclafer exit 1\n' >> "$r/summary.tsv"
  echo "date-utc: test" > "$r/environment.txt"
  ( cd "$r" && find . -type f ! -name environment.txt ! -name manifest.sha256 | LC_ALL=C sort | while read -r p; do shasum -a 256 "$p"; done > manifest.sha256 )
}

# --- canonicalizer -----------------------------------------------------------
printf '=== Instance 1 Begin ===\n\nc0_B \n  c0_y \n  c0_x \nc0_A \n\n--- Instance 1 End ---\n\n=== Instance 2 Begin ===\n\nc0_A \nc0_B \n  c0_x \n  c0_y \n\n--- Instance 2 End ---\n' > "$T/perm.txt"
check canon-permutation 0 python3 "$CANON" "$T/perm.txt" "$T/perm"
grep -q 'raw=2 unique=1' "$T/perm/canon.summary.txt" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL canon-permutation: sibling order not collapsed"; }
printf '=== Instance 1 Begin ===\n\nc0_A \n' > "$T/trunc.txt";                                   check canon-truncated 2 python3 "$CANON" "$T/trunc.txt" "$T/o1"
printf '=== Instance 1 Begin ===\nA\n--- Counterexample 1 End ---\n' > "$T/kind.txt";              check canon-kind-mismatch 2 python3 "$CANON" "$T/kind.txt" "$T/o2"
printf '=== Instance 1 Begin ===\nA\n--- Instance 2 End ---\n' > "$T/num.txt";                     check canon-number-mismatch 2 python3 "$CANON" "$T/num.txt" "$T/o3"
printf '=== Instance 2 Begin ===\nA\n--- Instance 2 End ---\n' > "$T/gap.txt";                     check canon-numbering-gap 2 python3 "$CANON" "$T/gap.txt" "$T/o4"
printf -- '--- Instance 1 End ---\n' > "$T/stray.txt";                                             check canon-stray-end 2 python3 "$CANON" "$T/stray.txt" "$T/o5"
printf '=== Instance 1 Begin ===\n=== Instance 2 Begin ===\nA\n--- Instance 2 End ---\n' > "$T/nest.txt"; check canon-nested 2 python3 "$CANON" "$T/nest.txt" "$T/o6"
printf '=== Instance 1 Begin ===\nA\n    B\n--- Instance 1 End ---\n' > "$T/jump.txt";             check canon-indent-jump 2 python3 "$CANON" "$T/jump.txt" "$T/o7"
: > "$T/empty.txt";                                                                                check canon-empty-dump 0 python3 "$CANON" "$T/empty.txt" "$T/o8"

# --- compare -----------------------------------------------------------------
mkcapture "$T/old"; mkcapture "$T/new"
check compare-identical 0 python3 "$COMPARE" "$T/old" "$T/new"
cp -r "$T/new" "$T/n1"; sed -i.bak 's/c0_A/c9_A/' "$T/n1/solve-positive/alpha/instances.canon.txt";          check compare-altered-set 1 python3 "$COMPARE" "$T/old" "$T/n1"
cp -r "$T/new" "$T/n2"; echo 1 > "$T/n2/solve-positive/alpha/exit.txt"; sed -i.bak $'s/\\talpha\\tinstantiate\\tdeclared\\t--search PreferSmallerInstances\\t0/\\talpha\\tinstantiate\\tdeclared\\t--search PreferSmallerInstances\\t1/' "$T/n2/summary.tsv"; check compare-changed-exit 1 python3 "$COMPARE" "$T/old" "$T/n2"
cp -r "$T/new" "$T/n3"; rm -rf "$T/n3/solve-positive/alpha"; grep -v $'\talpha\t' "$T/n3/summary.tsv" > "$T/n3/s" && mv "$T/n3/s" "$T/n3/summary.tsv"; check compare-missing-model 1 python3 "$COMPARE" "$T/old" "$T/n3"
cp -r "$T/new" "$T/n4"; sed -i.bak 's/\tgamma\texcluded/\tdelta\texcluded/' "$T/n4/summary.tsv";           check compare-renamed-exclusion 1 python3 "$COMPARE" "$T/old" "$T/n4"
cp -r "$T/new" "$T/n5"; sed -i.bak 's/\tgamma\texcluded\tdeclared\t-\t-/\tgamma\tskipped\tdeclared\t-\t-/' "$T/n5/summary.tsv"; check compare-excluded-to-skipped 1 python3 "$COMPARE" "$T/old" "$T/n5"
cp -r "$T/new" "$T/n6"; rm "$T/n6/assert-positive/beta/assertions.canon.txt";                               check compare-missing-assertions 1 python3 "$COMPARE" "$T/old" "$T/n6"
cp -r "$T/new" "$T/n7"; : > "$T/n7/assert-positive/beta/assertions.canon.txt";                              check compare-emptied-assertions 1 python3 "$COMPARE" "$T/old" "$T/n7"
cp -r "$T/new" "$T/n8"; rm "$T/n8/solve-positive/alpha/canon.summary.txt";                                  check compare-missing-canon-summary 1 python3 "$COMPARE" "$T/old" "$T/n8"
cp -r "$T/new" "$T/n9"; rm "$T/n9/solve-positive/alpha/instances.canon.txt" "$T/n9/solve-positive/alpha/instances.txt"; check compare-hash-only-side 0 python3 "$COMPARE" "$T/old" "$T/n9"
cp -r "$T/new" "$T/n10"; printf '=== Instance 1 Begin ===\n\nc0_A \n\n--- Instance 1 End ---\n\n=== Instance 2 Begin ===\n\nc0_A \n\n--- Instance 2 End ---\n' > "$T/n10/solve-positive/alpha/instances.txt"; check compare-order-drift-only 0 python3 "$COMPARE" "$T/old" "$T/n10"
grep -q 'drift' "$T/out.txt" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL compare-order-drift-only: drift not reported"; }
check compare-not-a-capture 2 python3 "$COMPARE" "$T/old" "$T"
cp -r "$T/new" "$T/n11"; echo "different message" > "$T/n11/failing/cx/compile.txt";                          check compare-compile-log-differs 1 python3 "$COMPARE" "$T/old" "$T/n11"
cp -r "$T/new" "$T/n12"; echo 2 > "$T/n12/failing/cx/compile-exit.txt";                                        check compare-compile-exit-differs 1 python3 "$COMPARE" "$T/old" "$T/n12"
cp -r "$T/new" "$T/n13"; rm -rf "$T/n13/failing/cx";                                                            check compare-compile-dir-missing 1 python3 "$COMPARE" "$T/old" "$T/n13"

# --- publish -----------------------------------------------------------------
check publish-ok 0 python3 "$PUBLISH" "$T/old" "$T/pub1"
check publish-again 0 python3 "$PUBLISH" "$T/old" "$T/pub2"
cmp -s "$T/pub1/baseline.tar.gz" "$T/pub2/baseline.tar.gz" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL publish-deterministic"; }
check publish-nesting 2 python3 "$PUBLISH" "$T/old" "$T/old/sub"
mkdir -p "$T/emptycap"; echo "$HDR" > "$T/emptycap/summary.tsv"; echo x > "$T/emptycap/environment.txt"; printf 'abc  ./missing\n' > "$T/emptycap/manifest.sha256"
check publish-empty-capture 2 python3 "$PUBLISH" "$T/emptycap" "$T/pub3"
cp -r "$T/old" "$T/tamper"; echo x >> "$T/tamper/solve-positive/alpha/exit.txt";                            check publish-tampered-manifest 2 python3 "$PUBLISH" "$T/tamper" "$T/pub4"
cp -r "$T/old" "$T/noart"; rm "$T/noart/solve-positive/alpha/canon.summary.txt"; ( cd "$T/noart" && find . -type f ! -name environment.txt ! -name manifest.sha256 | LC_ALL=C sort | while read -r p; do shasum -a 256 "$p"; done > manifest.sha256 ); check publish-missing-artifact 2 python3 "$PUBLISH" "$T/noart" "$T/pub5"
cp -r "$T/old" "$T/omit"; echo 9 > "$T/omit/solve-positive/alpha/exit.txt"; grep -v 'solve-positive/alpha/exit.txt' "$T/omit/manifest.sha256" > "$T/omit/m" && mv "$T/omit/m" "$T/omit/manifest.sha256"; check publish-omitted-manifest-line 2 python3 "$PUBLISH" "$T/omit" "$T/pub6"
cp -r "$T/old" "$T/extra"; echo stray > "$T/extra/solve-positive/alpha/stray.txt";                              check publish-unlisted-file 2 python3 "$PUBLISH" "$T/extra" "$T/pub7"
cp -r "$T/old" "$T/dup"; head -1 "$T/dup/manifest.sha256" >> "$T/dup/manifest.sha256";                          check publish-duplicate-entry 2 python3 "$PUBLISH" "$T/dup" "$T/pub8"
cp -r "$T/old" "$T/trav"; sed -i.bak '1s#  \./#  ./../#' "$T/trav/manifest.sha256";                              check publish-traversing-entry 2 python3 "$PUBLISH" "$T/trav" "$T/pub9"
check publish-seal 0 python3 "$PUBLISH" --seal "$T/pub1"
( cd "$T/pub1" && shasum -a 256 -c evidence.sha256 > /dev/null ) && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL publish-seal: evidence.sha256 does not verify"; }

# --- capture-script boundaries (fake java / clafer shims) -----------------------
# The shims read the scenario from the first line of the model in the work directory.
mkdir -p "$T/bin"
cat > "$T/bin/java" <<'SHIM'
#!/usr/bin/env bash
case " $* " in *" -version "*) echo 'fake java' >&2; exit 0;; *" --version "*) echo 'fake chocosolver'; exit 0;; esac
out=""; repl=0; args=("$@")
for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = "--output" ] && out="${args[$((i+1))]}"; [ "${args[$i]}" = "--repl" ] && repl=1; done
scenario="$(head -1 model.js | sed 's#^// scenario: ##')"
emit() { printf '=== Instance 1 Begin ===\n\nc0_A \n\n--- Instance 1 End ---\n' > "$out"; }
if [ "$repl" -eq 1 ]; then
  case "$scenario" in
    unsat-ok)           echo "ClaferChocoIG> Min UNSAT command:"; echo "([[c]], A)"; exit 0;;
    unsat-repl-exception) echo "ClaferChocoIG> Min UNSAT command:"; echo "Exception in thread \"main\" org.clafer.common.UnsatisfiableException"; exit 1;;
    unsat-repl-silent)  exit 1;;
    unsat-repl-empty)   echo "ClaferChocoIG> "; exit 0;;
    unsat-repl-hang)    sleep 10; exit 0;;
  esac
fi
case "$scenario" in
  ok)            echo "Instantiating..."; emit; echo "Generated 1 instance(s) within the scope"; exit 0;;
  exit1-error)   echo "Instantiating..."; echo 'Exception in thread "main" org.clafer.Boom' >&2; exit 1;;
  exit1-silent)  echo "Instantiating..."; exit 1;;
  exit137)       exit 137;;
  hang)          sleep 10; exit 0;;
  unsat-*)       echo "Instantiating..."; : > "$out"; echo "Generated 0 instance(s) within the scope"; exit 0;;
esac
exit 99
SHIM
cat > "$T/bin/clafer" <<'SHIM'
#!/usr/bin/env bash
case " $* " in *" --version "*) echo 'Clafer fake'; exit 0;; esac
scenario="$(head -1 model.cfr | sed 's#^// scenario: ##')"
case "$scenario" in
  ok)             echo "// scenario: ok" > model.js; exit 0;;
  compile-error)  echo "Compile error at line 1 column 1"; exit 1;;
  exit1-silent)   exit 1;;
  exit137)        exit 137;;
  hang)           sleep 10; exit 0;;
  no-output)      exit 0;;
esac
exit 99
SHIM
chmod +x "$T/bin/java" "$T/bin/clafer"
: > "$T/fake.jar"
runcap() { # runcap <name> <expected-rc> <ext> <scenario>
  local name="$1" want="$2" ext="$3" scenario="$4"
  rm -rf "$T/cap-$name"; mkdir -p "$T/corpus-$name/t"
  printf '// scenario: %s\n' "$scenario" > "$T/corpus-$name/t/m.$ext"
  local rc=0
  ( cd "$T" && PATH="$T/bin:$PATH" CHOCOSOLVER_JAR="$T/fake.jar" CLAFER="$T/bin/clafer" TIMEOUT=2 REDUCED=/nonexistent REDUCED_MODELS=/nonexistent EXCLUDED=/nonexistent \
      bash "$CAPTURE" "$T/cap-$name" "$T/corpus-$name" > "$T/out.txt" 2> "$T/err.txt" ) || rc=$?
  if [ "$rc" -eq "$want" ]; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL capture-$name: exit $rc, expected $want"; sed 's/^/    /' "$T/err.txt" | head -3; fi
}
runcap ok 0 js ok
grep -q $'\tinstantiate\tdeclared\t.*\t0\t1\t1\t' "$T/cap-ok/summary.tsv" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL capture-ok: row not recorded"; }
runcap exit1-with-error 0 js exit1-error
grep -q $'\t1\t0\t0\t' "$T/cap-exit1-with-error/summary.tsv" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL capture-exit1-with-error: exit 1 row not recorded"; }
runcap exit1-silent 1 js exit1-silent
runcap exit137 1 js exit137
runcap hang-timeout 1 js hang
runcap unsat-ok 0 js unsat-ok
grep -q $'\tunsat\t' "$T/cap-unsat-ok/summary.tsv" && [ "$(cat "$T/cap-unsat-ok/t/m/unsat-exit.txt")" = 0 ] && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL capture-unsat-ok: unsat row/exit not recorded"; }
runcap unsat-repl-exception 0 js unsat-repl-exception
grep -q 'minUnsat raised UnsatisfiableException' "$T/cap-unsat-repl-exception/summary.tsv" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL capture-unsat-repl-exception: exception not recorded"; }
runcap unsat-repl-silent 1 js unsat-repl-silent
runcap unsat-repl-empty 1 js unsat-repl-empty
runcap unsat-repl-hang 1 js unsat-repl-hang
runcap compile-ok 0 cfr ok
grep -q 'compiled from model.cfr' "$T/cap-compile-ok/summary.tsv" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL capture-compile-ok: compiled row not recorded"; }
runcap compile-error 0 cfr compile-error
grep -q $'\tcompile-error\tdeclared\t-\t1\t' "$T/cap-compile-error/summary.tsv" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL capture-compile-error: row not recorded"; }
runcap compile-silent1 1 cfr exit1-silent
runcap compile-exit137 1 cfr exit137
runcap compile-hang 1 cfr hang
runcap compile-no-output 1 cfr no-output
rm -rf "$T/corpus-nocomp"; mkdir -p "$T/corpus-nocomp/t"; echo "// scenario: ok" > "$T/corpus-nocomp/t/m.cfr"
nocomp_rc=0
( cd "$T" && PATH="$T/bin:$PATH" CHOCOSOLVER_JAR="$T/fake.jar" TIMEOUT=2 REDUCED=/nonexistent REDUCED_MODELS=/nonexistent EXCLUDED=/nonexistent bash "$CAPTURE" "$T/cap-nocomp" "$T/corpus-nocomp" > /dev/null 2>&1 ) || nocomp_rc=$?
if [ "$nocomp_rc" -eq 0 ] && grep -q $'\tskipped\t' "$T/cap-nocomp/summary.tsv"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL capture-no-compiler: skipped row not recorded (exit $nocomp_rc)"; fi

echo "test-choco-baseline-tools: $pass passed, $failn failed"
[ "$failn" -eq 0 ]

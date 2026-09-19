#!/usr/bin/env bash
# Self-test of the golden-oracle tooling (Sigil-Logic/chocosolver#2): negative and
# positive fixtures for canonicalize-choco-instances.py, compare-choco-baselines.py,
# and publish-choco4-baseline.py.  No solver run is needed; fixtures are synthetic.
#
# Usage: test-choco-baseline-tools.sh        (exit 0 when every case behaves as specified)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$HERE/canonicalize-choco-instances.py"
COMPARE="$HERE/compare-choco-baselines.py"
PUBLISH="$HERE/publish-choco4-baseline.py"
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

# --- publish -----------------------------------------------------------------
check publish-ok 0 python3 "$PUBLISH" "$T/old" "$T/pub1"
check publish-again 0 python3 "$PUBLISH" "$T/old" "$T/pub2"
cmp -s "$T/pub1/baseline.tar.gz" "$T/pub2/baseline.tar.gz" && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL publish-deterministic"; }
check publish-nesting 2 python3 "$PUBLISH" "$T/old" "$T/old/sub"
mkdir -p "$T/emptycap"; echo "$HDR" > "$T/emptycap/summary.tsv"; echo x > "$T/emptycap/environment.txt"; printf 'abc  ./missing\n' > "$T/emptycap/manifest.sha256"
check publish-empty-capture 2 python3 "$PUBLISH" "$T/emptycap" "$T/pub3"
cp -r "$T/old" "$T/tamper"; echo x >> "$T/tamper/solve-positive/alpha/exit.txt";                            check publish-tampered-manifest 2 python3 "$PUBLISH" "$T/tamper" "$T/pub4"
cp -r "$T/old" "$T/noart"; rm "$T/noart/solve-positive/alpha/canon.summary.txt"; ( cd "$T/noart" && find . -type f ! -name environment.txt ! -name manifest.sha256 | LC_ALL=C sort | while read -r p; do shasum -a 256 "$p"; done > manifest.sha256 ); check publish-missing-artifact 2 python3 "$PUBLISH" "$T/noart" "$T/pub5"
check publish-seal 0 python3 "$PUBLISH" --seal "$T/pub1"
( cd "$T/pub1" && shasum -a 256 -c evidence.sha256 > /dev/null ) && pass=$((pass+1)) || { failn=$((failn+1)); echo "FAIL publish-seal: evidence.sha256 does not verify"; }

echo "test-choco-baseline-tools: $pass passed, $failn failed"
[ "$failn" -eq 0 ]

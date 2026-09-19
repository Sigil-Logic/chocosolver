#!/usr/bin/env python3
"""Compare two chocosolver golden-oracle captures (Sigil-Logic/chocosolver#2).

Usage: compare-choco-baselines.py <old-capture-dir> <new-capture-dir>

Each capture directory is produced by scripts/capture-choco4-baseline.sh:
summary.tsv (one row per corpus model) plus, for every model that ran,
<class>/<model>/ with exit.txt, canon.summary.txt (count and SHA-256 of the
canonical set), and, unless the capture kept only the hash for size,
instances.txt (raw dump) and instances.canon.txt (canonical, order-insensitive
instance set); when present, assertions.canon.txt (validation mode), unsat.txt
and unsat-exit.txt (UNSAT models), compile.txt and compile-exit.txt (compiled
.cfr inputs).  For the frozen reference, extract
.evidence/choco4-baseline/baseline.tar.gz next to its summary.tsv first.

The comparison is driven by the two summary.tsv files so that every corpus
model — including excluded, skipped, and compile-error rows, which have no
directory — is accounted for.  Per model it reports:
  - outcome parity: mode, configuration, and exit code
  - instance-count parity (unique canonical instances)
  - instance-SET equality (canonical text when stored on both sides, else the
    recorded SHA-256; a hash missing on either side is a failure)
  - enumeration-order drift (same set, different raw sequence) — informational
  - artifact parity, whenever either side has a model directory (compile-error
    rows keep their compiler artifacts): the presence of each optional
    artifact must agree, and the failed-assertion set, unsat-core text, and
    compile/unsat exit codes must be equal when present
Exit status: 0 when every model is outcome-equal and set-equal (order drift is
allowed and reported), 1 otherwise, 2 on usage errors.  The table is the input
for the documented re-baselining rationale of the migration stages; it makes
no judgement beyond parity.
"""
import csv
import sys
from pathlib import Path

RAN_MODES = {"instantiate", "validate", "unsat"}
OPTIONAL = ("assertions.canon.txt", "unsat.txt", "unsat-exit.txt", "compile.txt", "compile-exit.txt")


def read(p: Path) -> str:
    return p.read_text() if p.exists() else ""


def summary(d: Path) -> dict:
    out = {}
    for tok in read(d / "canon.summary.txt").split():
        k, _, v = tok.partition("=")
        out[k] = v
    return out


def load(root: Path) -> dict[tuple[str, str], dict]:
    path = root / "summary.tsv"
    if not path.is_file():
        raise FileNotFoundError(path)
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    return {(r["class"], r["model"]): r for r in rows}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    old_root, new_root = Path(sys.argv[1]), Path(sys.argv[2])
    try:
        old, new = load(old_root), load(new_root)
    except FileNotFoundError as e:
        print(f"error: {e} missing; not a capture directory", file=sys.stderr)
        return 2
    keys = sorted(set(old) | set(new))
    if not keys:
        print("error: both summaries are empty", file=sys.stderr)
        return 2

    failures = 0
    drift = 0
    print(f"{'model':60} {'outcome':>22} {'count':>11} set-equal order   artifacts")
    for key in keys:
        name = f"{key[0]}/{key[1]}"
        ro, rn = old.get(key), new.get(key)
        if ro is None or rn is None:
            print(f"{name:60} MISSING in {'new' if rn is None else 'old'} summary")
            failures += 1
            continue
        outcome_o = f"{ro['mode']}/{ro['config']}/exit {ro['exit']}"
        outcome_n = f"{rn['mode']}/{rn['config']}/exit {rn['exit']}"
        outcome_equal = outcome_o == outcome_n
        outcome_str = outcome_o if outcome_equal else f"{outcome_o} -> {outcome_n}"
        problems = []

        ran_o, ran_n = ro["mode"] in RAN_MODES, rn["mode"] in RAN_MODES
        do, dn = old_root / key[0] / key[1], new_root / key[0] / key[1]
        # Artifact parity applies whenever either side has a model directory: compile-error
        # rows keep model.cfr, compile.txt, and compile-exit.txt although they never ran.
        if do.is_dir() != dn.is_dir():
            problems.append(f"model directory only in {'old' if do.is_dir() else 'new'}")
        elif do.is_dir():
            for extra in OPTIONAL:
                po, pn = (do / extra).exists(), (dn / extra).exists()
                if po != pn:
                    problems.append(f"{extra} {'only in old' if po else 'only in new'}")
                elif po and read(do / extra) != read(dn / extra):
                    problems.append(f"{extra} differs")
        if ran_o and ran_n:
            for d, side in ((do, "old"), (dn, "new")):
                if not d.is_dir() or not (d / "exit.txt").is_file() or not (d / "canon.summary.txt").is_file():
                    problems.append(f"{side}: missing per-model artifacts")
            so, sn = summary(do), summary(dn)
            sha_o, sha_n = so.get("sha256"), sn.get("sha256")
            if not sha_o or not sha_n:
                problems.append("canonical hash missing")
                set_equal = False
            elif (do / "instances.canon.txt").exists() and (dn / "instances.canon.txt").exists():
                set_equal = read(do / "instances.canon.txt") == read(dn / "instances.canon.txt") and sha_o == sha_n
            else:  # hash-only storage on at least one side
                set_equal = sha_o == sha_n
            if (do / "instances.txt").exists() and (dn / "instances.txt").exists():
                order_equal = read(do / "instances.txt") == read(dn / "instances.txt")
            else:
                order_equal = set_equal  # raw dumps not stored; drift is not observable
            cnt_o, cnt_n = so.get("unique", "-"), sn.get("unique", "-")
            if cnt_o != ro["unique"] or cnt_n != rn["unique"]:
                problems.append("summary/canon count mismatch")
        else:
            # Rows without a run (excluded, skipped, compile-error): the summary row plus any
            # compiler artifacts compared above are the evidence.
            set_equal = ro["canon-sha256"] == rn["canon-sha256"] and ro["unique"] == rn["unique"]
            order_equal = True
            cnt_o, cnt_n = ro["unique"], rn["unique"]
            if ran_o != ran_n:
                problems.append("ran on one side only")

        count_str = cnt_o if cnt_o == cnt_n else f"{cnt_o}->{cnt_n}"
        order_str = ("same" if order_equal else "drift") if set_equal else "-"
        if set_equal and not order_equal:
            drift += 1
        art = "ok" if not problems else "; ".join(problems)
        print(f"{name:60} {outcome_str:>22} {count_str:>11} {'yes' if set_equal else 'NO':>9} {order_str:7} {art}")
        if not (outcome_equal and set_equal) or problems:
            failures += 1
    print(f"\n{len(keys)} models, {failures} parity failure(s), {drift} with enumeration-order drift only")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

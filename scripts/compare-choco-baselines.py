#!/usr/bin/env python3
"""Compare two chocosolver golden-oracle captures (Sigil-Logic/chocosolver#2).

Usage: compare-choco-baselines.py <old-capture-dir> <new-capture-dir>

Each capture directory is produced by scripts/capture-choco4-baseline.sh:
<class>/<model>/ with exit.txt, instances.txt (raw dump), instances.canon.txt
(canonical, order-insensitive instance set), canon.summary.txt, and, when
present, assertions.canon.txt (validation mode) and unsat.txt (UNSAT models).
For the frozen reference, extract .evidence/choco4-baseline/baseline.tar.gz
first.

Per model the comparison reports:
  - exit-code parity
  - instance-count parity (unique canonical instances)
  - instance-SET equality (canonical sets; enumeration order is ignored)
  - enumeration-order drift (same set, different raw sequence) — informational
  - failed-assertion set parity and unsat-core text parity, when captured
Exit status: 0 when every model is exit-equal and set-equal (order drift is
allowed and reported), 1 otherwise, 2 on usage errors.  The table is the
input for the documented re-baselining rationale of the migration stages; it
makes no judgement beyond parity.
"""
import sys
from pathlib import Path


def read(p: Path) -> str:
    return p.read_text() if p.exists() else ""


def summary(d: Path) -> dict:
    out = {}
    for tok in read(d / "canon.summary.txt").split():
        k, _, v = tok.partition("=")
        out[k] = v
    return out


def models(root: Path) -> set[str]:
    return {
        f"{c.name}/{m.name}"
        for c in root.iterdir() if c.is_dir()
        for m in c.iterdir() if m.is_dir()
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    old_root, new_root = Path(sys.argv[1]), Path(sys.argv[2])
    if not old_root.is_dir() or not new_root.is_dir():
        print("error: both arguments must be capture directories", file=sys.stderr)
        return 2
    names = sorted(models(old_root) | models(new_root))
    if not names:
        print("error: no <class>/<model> directories found", file=sys.stderr)
        return 2

    failures = 0
    drift = 0
    print(f"{'model':60} {'exit':>7} {'count':>11} set-equal order   extras")
    for name in names:
        o, n = old_root / name, new_root / name
        if not o.is_dir() or not n.is_dir():
            print(f"{name:60} MISSING in {'new' if not n.is_dir() else 'old'}")
            failures += 1
            continue
        exit_o, exit_n = read(o / "exit.txt").strip(), read(n / "exit.txt").strip()
        so, sn = summary(o), summary(n)
        cnt_o, cnt_n = so.get("unique", "-"), sn.get("unique", "-")
        if (o / "instances.canon.txt").exists() and (n / "instances.canon.txt").exists():
            set_equal = read(o / "instances.canon.txt") == read(n / "instances.canon.txt")
        else:  # hash-only storage (canonical text above the capture's STORE_LIMIT)
            set_equal = so.get("sha256") == sn.get("sha256")
        if (o / "instances.txt").exists() and (n / "instances.txt").exists():
            order_equal = read(o / "instances.txt") == read(n / "instances.txt")
        else:
            order_equal = set_equal  # raw dumps not stored; order drift is not observable
        extras = []
        for extra in ("assertions.canon.txt", "unsat.txt"):
            if (o / extra).exists() or (n / extra).exists():
                same = read(o / extra) == read(n / extra)
                extras.append(f"{extra.split('.')[0]}={'same' if same else 'DIFF'}")
                if not same:
                    failures += 1
        exit_str = exit_o if exit_o == exit_n else f"{exit_o}->{exit_n}"
        count_str = cnt_o if cnt_o == cnt_n else f"{cnt_o}->{cnt_n}"
        order_str = ("same" if order_equal else "drift") if set_equal else "-"
        if set_equal and not order_equal:
            drift += 1
        print(f"{name:60} {exit_str:>7} {count_str:>11} {'yes' if set_equal else 'NO':>9} {order_str:7} {' '.join(extras)}")
        if not set_equal or exit_o != exit_n:
            failures += 1
    print(f"\n{len(names)} models, {failures} parity failure(s), {drift} with enumeration-order drift only")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

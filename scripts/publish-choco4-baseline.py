#!/usr/bin/env python3
"""Publish a capture as the frozen evidence directory (Sigil-Logic/chocosolver#2).

Usage: publish-choco4-baseline.py <capture-dir> <evidence-dir>
       publish-choco4-baseline.py --seal <evidence-dir>

Publish mode validates the capture before copying anything: summary.tsv must
carry at least one model row; every row whose mode ran (instantiate, validate,
unsat) must have its <class>/<model>/ directory with exit.txt and
canon.summary.txt; manifest.sha256 must list exactly the capture's files
(summary.tsv plus every per-model file; environment.txt and the manifest
itself are the only exclusions), each as a plain capture-relative path
without duplicates, existing and hashing as recorded; and the two
directories must not nest.  It then copies
environment.txt, summary.tsv, and manifest.sha256 into <evidence-dir> and packs
every per-model directory into <evidence-dir>/baseline.tar.gz deterministically
(sorted entries, zeroed mtimes and ownership, gzip without a timestamp), so
re-publishing the same capture yields a byte-identical tarball.  It prints the
tarball's SHA-256 and entry count for the README.

Seal mode writes <evidence-dir>/evidence.sha256, the integrity manifest over
every file in the evidence directory except itself (provenance, summary, the
per-model manifest, the tarball, exclusions and reduced-configuration inputs,
test-suite evidence, README).  Run it last, after any hand-edited file such as
the README has reached its final form; `sha256sum -c evidence.sha256` from
inside the directory verifies the published set.
"""
import csv
import gzip
import hashlib
import io
import shutil
import sys
import tarfile
from pathlib import Path

TOP_LEVEL = ("environment.txt", "summary.tsv", "manifest.sha256")
RAN_MODES = {"instantiate", "validate", "unsat"}
SEAL = "evidence.sha256"


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def fail(msg: str) -> int:
    print(f"error: {msg}", file=sys.stderr)
    return 2


def validate(src: Path) -> str | None:
    for name in TOP_LEVEL:
        if not (src / name).is_file():
            return f"{src / name} missing; not a complete capture"
    with open(src / "summary.tsv", newline="") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    if not rows:
        return "summary.tsv has no model rows; refusing to publish an empty capture"
    for r in rows:
        if r.get("mode") in RAN_MODES:
            d = src / r["class"] / r["model"]
            for req in ("exit.txt", "canon.summary.txt"):
                if not (d / req).is_file():
                    return f"{r['class']}/{r['model']}: {req} missing for a model that ran"
    listed: set[str] = set()
    for line in (src / "manifest.sha256").read_text().splitlines():
        if not line.strip():
            continue
        digest, _, rel = line.partition("  ")
        if not rel.startswith("./") or ".." in Path(rel).parts or Path(rel).is_absolute():
            return f"manifest entry {rel!r} is not a plain capture-relative path"
        if rel in listed:
            return f"manifest entry {rel} is listed twice"
        target = src / rel
        if not target.is_file():
            return f"manifest entry {rel} is missing from the capture"
        if sha256(target) != digest:
            return f"manifest entry {rel} does not hash as recorded"
        listed.add(rel)
    if not listed:
        return "manifest.sha256 is empty"
    # The manifest must cover exactly the capture: summary.tsv plus every per-model file.
    # Only the two top-level paths ./environment.txt and ./manifest.sha256 are excluded
    # (by exact relative path, never by basename, so a nested file of the same name is a
    # capture file like any other), and the check is bidirectional.
    expected = {
        "./" + p.relative_to(src).as_posix() for p in src.rglob("*") if p.is_file()
    } - {"./environment.txt", "./manifest.sha256"}
    unlisted = sorted(expected - listed)
    if unlisted:
        return f"{len(unlisted)} capture file(s) not listed in manifest.sha256, e.g. {unlisted[0]}"
    unexpected = sorted(listed - expected)
    if unexpected:
        return f"manifest.sha256 lists {len(unexpected)} path(s) outside the capture set, e.g. {unexpected[0]}"
    return None


def publish(src: Path, dst: Path) -> int:
    if not src.is_dir():
        return fail(f"{src} is not a directory")
    src_r, dst_r = src.resolve(), dst.resolve()
    if src_r == dst_r or src_r in dst_r.parents or dst_r in src_r.parents:
        return fail("capture and evidence directories must not nest")
    problem = validate(src)
    if problem:
        return fail(problem)
    dst.mkdir(parents=True, exist_ok=True)
    for name in TOP_LEVEL:
        shutil.copyfile(src / name, dst / name)
    files = sorted(
        p for p in src.rglob("*") if p.is_file() and p.relative_to(src).parts[0] not in TOP_LEVEL
    )
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for p in files:
            info = tar.gettarinfo(str(p), arcname=str(p.relative_to(src)))
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            info.mode = 0o644
            with open(p, "rb") as fh:
                tar.addfile(info, fh)
    out = dst / "baseline.tar.gz"
    with open(out, "wb") as fh:
        with gzip.GzipFile(filename="", mode="wb", fileobj=fh, mtime=0) as gz:
            gz.write(buf.getvalue())
    print(f"{out}: {len(files)} files, sha256 {sha256(out)}")
    return 0


def seal(dst: Path) -> int:
    if not dst.is_dir() or not (dst / "manifest.sha256").is_file():
        return fail(f"{dst} is not a published evidence directory")
    files = sorted(p for p in dst.rglob("*") if p.is_file() and p.name != SEAL)
    lines = [f"{sha256(p)}  {p.relative_to(dst).as_posix()}" for p in files]
    (dst / SEAL).write_text("\n".join(lines) + "\n")
    print(f"{dst / SEAL}: {len(lines)} files sealed")
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--seal":
        return seal(Path(sys.argv[2]))
    if len(sys.argv) == 3:
        return publish(Path(sys.argv[1]), Path(sys.argv[2]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

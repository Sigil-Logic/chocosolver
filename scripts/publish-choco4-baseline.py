#!/usr/bin/env python3
"""Publish a capture as the frozen evidence directory (Sigil-Logic/chocosolver#2).

Usage: publish-choco4-baseline.py <capture-dir> <evidence-dir>

Copies environment.txt, summary.tsv, and manifest.sha256 from the capture
into <evidence-dir> and packs every per-model directory into
<evidence-dir>/baseline.tar.gz deterministically (sorted entries, zeroed
mtimes and ownership, gzip without a timestamp), so re-publishing the same
capture yields a byte-identical tarball.  Prints the tarball's SHA-256 and the
entry count for the README.
"""
import gzip
import hashlib
import io
import shutil
import sys
import tarfile
from pathlib import Path

TOP_LEVEL = ("environment.txt", "summary.tsv", "manifest.sha256")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    for name in TOP_LEVEL:
        if not (src / name).is_file():
            print(f"error: {src / name} missing; not a complete capture", file=sys.stderr)
            return 2
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
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"{out}: {len(files)} files, sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

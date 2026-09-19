#!/usr/bin/env python3
"""Canonicalize a chocosolver instance dump into an order-insensitive instance set.

Usage: canonicalize-choco-instances.py <instances.txt> <out-dir>

Reads the formal (non-prettified) output that `chocosolver --output <file>`
writes: blocks delimited by `=== Instance N Begin ===` / `--- Instance N End ---`
(or `Counterexample` in validation mode), each an indentation-structured tree
of clafer instances (two spaces per level, one clafer per line).

Canonical form of one instance: at every level, sibling subtrees are sorted by
their own canonical text, so the order in which the solver happens to print
siblings does not matter; trailing whitespace is dropped; the `$N` identity
suffixes and reference values are kept verbatim (they carry reference identity
within the instance).  The canonical SET is the sorted, de-duplicated list of
canonical instances, written to <out-dir>/instances.canon.txt with blocks
separated by a line containing only `---`.  A summary line goes to
<out-dir>/canon.summary.txt: kind, raw count, unique count, SHA-256 of the
canonical file.

Exit status 0 on success; 2 on malformed input (unterminated block, marker
kind/number mismatch, stray or nested marker, numbering gap, odd indentation),
so a capture never silently publishes a truncated or corrupted dump.
"""
import hashlib
import re
import sys
from pathlib import Path

BEGIN = re.compile(r"^=== (Instance|Counterexample) (\d+) Begin ===$")
END = re.compile(r"^--- (Instance|Counterexample) (\d+) End ---$")

def split_blocks(text: str) -> list[tuple[str, list[str]]]:
    """Split a dump into (kind, lines) blocks.

    Every `=== <Kind> <n> Begin ===` must be closed by the matching
    `--- <Kind> <n> End ---` (same kind, same number); blocks must be numbered
    1, 2, 3, ... in order.  Anything else — a nested or stray marker, a
    mismatched close, a gap in numbering, a missing close — is a malformed dump.
    """
    blocks: list[tuple[str, list[str]]] = []
    cur: list[str] | None = None
    kind, number = "", 0
    for raw in text.splitlines():
        line = raw.rstrip()
        m = BEGIN.match(line)
        if m:
            if cur is not None:
                raise ValueError(f"nested Begin marker: {line!r}")
            kind, number = m.group(1), int(m.group(2))
            if number != len(blocks) + 1:
                raise ValueError(f"unexpected block number {number} (expected {len(blocks) + 1})")
            cur = []
            continue
        m = END.match(line)
        if m:
            if cur is None:
                raise ValueError(f"End marker without Begin: {line!r}")
            if (m.group(1), int(m.group(2))) != (kind, number):
                raise ValueError(f"End marker {line!r} does not close '{kind} {number}'")
            blocks.append((kind, cur))
            cur = None
            continue
        if cur is not None and line != "":
            cur.append(line)
    if cur is not None:
        raise ValueError("unterminated instance block (truncated dump?)")
    return blocks

def parse_tree(lines: list[str]) -> list[tuple[str, list]]:
    root: list = []
    stack: list[tuple[int, list]] = [(-1, root)]
    for line in lines:
        indent = len(line) - len(line.lstrip(" "))
        if indent % 2:
            raise ValueError(f"odd indentation: {line!r}")
        depth = indent // 2
        while stack[-1][0] >= depth:
            stack.pop()
        if stack[-1][0] != depth - 1:
            raise ValueError(f"indentation jump: {line!r}")
        node = (line.strip(), [])
        stack[-1][1].append(node)
        stack.append((depth, node[1]))
    return root

def canon(node: tuple[str, list]) -> str:
    text, children = node
    sub = sorted(canon(c) for c in children)
    return "\n".join([text] + ["  " + l for s in sub for l in s.split("\n")])

def canon_instance(lines: list[str]) -> str:
    return "\n".join(sorted(canon(n) for n in parse_tree(lines)))

def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    text = src.read_text() if src.exists() else ""
    try:
        blocks = split_blocks(text)
        insts = [canon_instance(b) for _, b in blocks]
    except ValueError as e:
        print(f"error: {src}: {e}", file=sys.stderr)
        return 2
    kinds = sorted({k for k, _ in blocks})
    kind = kinds[0] if len(kinds) == 1 else ("none" if not kinds else "+".join(kinds))
    unique = sorted(set(insts))
    body = "\n---\n".join(unique) + ("\n" if unique else "")
    out.mkdir(parents=True, exist_ok=True)
    (out / "instances.canon.txt").write_text(body)
    digest = hashlib.sha256(body.encode()).hexdigest()
    (out / "canon.summary.txt").write_text(
        f"kind={kind.lower()} raw={len(insts)} unique={len(unique)} sha256={digest}\n"
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())

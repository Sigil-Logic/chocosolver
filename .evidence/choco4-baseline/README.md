# Choco-solver 4.0.0 Golden-Oracle Baseline (chocosolver 0.4.4)

**Status**: Frozen snapshot  
**Version**: 1.0.0  
**Date**: 2026-09-18  
**Project**: Clafer Toolchain (Sigil Logic)  
**Issue**: [chocosolver#2](https://github.com/Sigil-Logic/chocosolver/issues/2)  

---

## Purpose

This directory freezes the **behavioral baseline of chocosolver 0.4.4 against `choco-solver:4.0.0`** over the repository's own model corpus, captured *before any migration change*.  It is Stage 0 of the Choco-solver 6.0.1 alignment ([chocosolver#1](https://github.com/Sigil-Logic/chocosolver/issues/1)): each later stage re-runs the same capture on the migrated tree and compares against this snapshot, so a behavioral difference is attributable to a specific Choco version step.  The oracle compares **instance sets** — canonicalized and order-insensitive — never enumeration sequences, because search and restart defaults change across Choco versions and legitimately reorder enumeration.

## Contents

| File | Purpose |
|---|---|
| `environment.txt` | Capture environment, toolchain versions, jar SHA-256, source commits, exact invocation (SL-DOM-P05 reproducibility) |
| `summary.tsv` | One row per corpus model: class, model, mode, configuration, flags, exit code, raw and unique instance counts, SHA-256 of the canonical instance set, note |
| `manifest.sha256` | SHA-256 of every captured file (SL-DOM-P04 evidence integrity); byte-reproducible on the same toolchain |
| `exclusions.tsv` | Models whose full instance set is not enumerable, with the measured reason (input to the capture) |
| `reduced-configurations.tsv`, `reduced-models/` | Pinned reduced configurations and derived models for excluded-at-declared-scope models (input to the capture) |
| `baseline.tar.gz` | The per-model capture tree: `model.js`, `flags.txt`, `stdout.txt`, `stderr.txt`, `exit.txt`, `canon.summary.txt`, and, below the size limit, `instances.txt` (raw dump) and `instances.canon.txt` (canonical set); `assertions.canon.txt` for validation runs, `unsat.txt` for UNSAT models, `model.cfr` and `compile.txt` for compiled inputs |
| `test-suite.txt` | The 0.4.4 test suite's result on the capture toolchain (`mvn test`): the starting point for the "suite green" criterion of the migration stages |

Tarball SHA-256: `c98c6cfaa3e036dffa112aff2dfd99e270b22daa170d869d3647a4fdd8b2e8b2`
Manifest: 808 entries (807 per-model files plus `summary.tsv`) files.  Totals: 112 corpus models, 286,913 instances recorded.

## Corpus and outcomes

The corpus is `src/test/resources`, the model sets the JUnit suite runs (`SolvePositiveTest`, `SolveNegativeTest`, `OptimizationTest`, `AssertPositiveTest`, `AssertNegativeTest`) plus the `failing` set the suite does not run.  Every model has a recorded outcome:

| Class | Models | Complete sets | of which hash-only | Reduced configuration | Validation runs | UNSAT (0 instances) | Excluded | Errors | Compile errors | Instances recorded |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `assert-negative` | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 2 |
| `assert-positive` | 7 | 0 | 0 | 0 | 7 | 0 | 0 | 0 | 0 | 0 |
| `failing` | 8 | 3 | 0 | 0 | 0 | 1 | 0 | 4 | 0 | 3 |
| `optimization` | 6 | 6 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 76 |
| `solve-negative` | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| `solve-positive` | 89 | 75 | 3 | 1 | 0 | 0 | 13 | 0 | 0 | 286,832 |
| **Total** | 112 | 84 | 3 | 1 | 8 | 2 | 13 | 4 | 0 | 286,913 |

- **Complete sets** are enumerated to exhaustion at the model's declared scopes and integer range.  Three are large (`i23` with 262,144 instances, `deployment-example` with 21,504, and `powerWindow_singleDoor` with 1,318 instances of about 8 KB each) and are stored **hash-only**: their `canon.summary.txt` keeps the count and SHA-256, the dumps are dropped because their canonical text exceeds the 4 MB storage limit; regenerating the capture recreates them.
- **Reduced configuration**: `i122-CVL` exceeds 300,001 instances at its declared scopes; the derived model `reduced-models/solve-positive/i122-CVL.js` sets every per-clafer scope and the default scope to 1 and runs with int range `[0, 1]` (`reduced-configurations.tsv`), giving a complete set of 1,176 instances.
- **Validation runs** (`assert-*`, `-v`): the counterexample set plus the sorted set of failed-assertion lines.  The seven `assert-positive` models produce no counterexample; `assert-negative/escapes` produces 2 counterexamples over 2 failing assertions.
- **UNSAT**: models that instantiate to zero instances additionally record the REPL's `minUnsat` and `unsatCore` output (`unsat.txt`).
- **Excluded**: 13 `solve-positive` models exceed 300,001 instances at their declared scopes or do not terminate within 150 s at that cap (`exclusions.tsv` gives the per-model measurement).  Tightening the integer range to `[0, 0]` or `[0, 1]` leaves them unbounded or makes them UNSAT, and forcing every scope to 1 raises `InsufficientScopeException` on all but one (which became the reduced configuration above).  An order-dependent `-n` prefix was rejected as evidence: it is exactly the artifact the oracle must not depend on.
- **Errors** (`failing/`): `EAST-ADL-PowerWindow` and `reals` fail JavaScript evaluation (`ReferenceError` on the undefined `c0_Port` and `real`; the CLI prints the error and exits 0 with no instances); `i40_integers_strings_assignment` and `oclBench_b1` raise `JoinSetWithStringException` (exit 1); `ClaferTools_ToolingArchitecture` instantiates to 0 instances (UNSAT, unsat core captured); the three `.cfr` models `gi29`, `gi30`, `gi31` compile with the Sigil clafer fork and yield 1 instance each, with canonical sets identical to those of their 2016 `.js` twins in `solve-positive`.

## Capture procedure

`scripts/capture-choco4-baseline.sh` runs the jar from inside each model's own work directory:

| Mode | Selection | Invocation |
|---|---|---|
| instantiate | every class except `assert-*` | `java -jar <jar> --file model.js --search PreferSmallerInstances --minint <lo> --maxint <hi> -n 300000 --output instances.txt` |
| validate | `assert-*` classes | the same with `-v` and without `-n` (validation ignores the cap and enumerates every counterexample) |
| unsat | instantiate produced 0 instances with exit 0 | additionally `--repl` fed `minUnsat`, `unsatCore`, `quit` |

Pinned choices, and why:

- **Integer range from the model.**  `<lo>, <hi>` is the model's own `intRange(lo, hi)` directive (`(-8, 7)` for 101 of the 108 `.js` models).  Without `--maxint` the CLI silently widens every model to `[-128, 127]` (`Utils.resolveScopes`), whereas the JUnit suite solves at the declared range; the capture follows the suite.  The one model without a directive (`i239`) runs at the CLI default.
- **Search strategy pinned** to `PreferSmallerInstances`, the current default.  Enumeration is run-to-run deterministic under it; the CLI has no seed option and the `Random` strategy is not used, so there is no seed to record.
- **Formal output** (no `--prettify`), written with `--output` so instance text is separated from the status lines on stdout.
- **`--moo` is a no-op**: `Normal.runNormal` selects the optimizer whenever the model declares objectives, and the six `optimization` models enumerate their complete Pareto-optimal sets (4 to 40 instances) with or without the flag.
- **Guards, not evidence**: a 300 s budget and a 300,000-instance cap per run.  A model that hits either fails the capture (harness-level failure), so structurally-present-but-truncated evidence is never published; the cure is an entry in `exclusions.tsv` or `reduced-configurations.tsv`.
- **`.cfr` inputs** (`failing/gi29`, `gi30`, `gi31`) are compiled in place with `clafer -k -m choco` by the compiler named in `CLAFER`; the reference used the Sigil clafer fork at commit `cefa7aa35f3b32c1811b2283fe715ed32081e7ae` (`Clafer 0.5.1`).  Without `CLAFER` they are recorded as skipped and the manifest differs.

## Canonicalization

`scripts/canonicalize-choco-instances.py` turns a dump into an order-insensitive set:

1. Split the dump at `=== Instance N Begin ===` / `--- Instance N End ---` (or `Counterexample`) and reject a truncated or malformed dump (exit 2).
2. Parse each instance as an indentation tree (two spaces per level, one clafer per line, trailing whitespace dropped).
3. At every level, sort sibling subtrees by their own canonical text.  `$N` identity suffixes and reference values (`-> T = X`) are kept verbatim: they carry reference identity within the instance.
4. The canonical set is the sorted, de-duplicated list of canonical instances, separated by `---` lines; `canon.summary.txt` records `kind`, `raw`, `unique`, and the SHA-256 of that file.

The comparison is therefore insensitive to sibling print order and enumeration order.  It is **not** insensitive to a solver renumbering `$N` identities within an instance; should a later Choco version do that, the raw dumps kept in the tarball allow a stronger canonicalization (identity renaming) to be applied to both sides retroactively.  Every raw count equals its unique count in this capture: the solver emits no duplicate instances.

## Regeneration and comparison

Reproducing the manifest byte-identically on the same toolchain (JDK 21.0.2, Maven 3.9.16, python3, GNU coreutils `timeout`, the Sigil clafer fork at `cefa7aa35f3b32c1811b2283fe715ed32081e7ae`):

```bash
mvn -DskipTests package
CLAFER=/path/to/sigil/clafer/clafer bash scripts/capture-choco4-baseline.sh baseline-out   # or: make baseline (with CLAFER exported)
cmp baseline-out/manifest.sha256 .evidence/choco4-baseline/manifest.sha256
```

The reference itself was produced twice in succession and the two manifests were byte-identical.  Publishing a capture as the frozen directory is `python3 scripts/publish-choco4-baseline.py baseline-out .evidence/choco4-baseline` (deterministic tarball).

Comparing a migrated tree against the reference — the step every later stage runs:

```bash
mkdir ref && tar xzf .evidence/choco4-baseline/baseline.tar.gz -C ref
mvn -DskipTests package
CLAFER=/path/to/sigil/clafer/clafer bash scripts/capture-choco4-baseline.sh new-out
python3 scripts/compare-choco-baselines.py ref new-out
```

`compare-choco-baselines.py` reports, per model, exit-code parity, unique-count parity, instance-set equality (canonical text, or SHA-256 for hash-only models), enumeration-order drift (informational), and parity of the failed-assertion sets and unsat-core text; it exits 0 only when every model is exit-equal and set-equal.  Excluded, skipped, and compile-error models have no directory and are compared through `summary.tsv`.

## Private corpora

The same scripts and toolchain also captured three private Clafer corpora — HOARDE `specs/ple` (22 models), NINJA `specs/ple` (18), and cryptol-agent (11) — compiled from `.cfr` with the Sigil clafer fork.  Instance sets of feature models reveal their structure, so that capture is stored on the private side and is cited here by count only: 51 models, of which 25 complete instance sets (3 stored hash-only; 411,954 instances), 8 UNSAT with unsat cores, 12 excluded by the same 300,001-instance rule, 1 solver error (insufficient scope), and 5 fragments that do not compile stand-alone.

## Provenance

| Item | Value |
|---|---|
| chocosolver source | `bc4cb12a23118d9e5d7f1003d83f2f8bed9cf179` (the 0.4.4 release, byte-identical to upstream `gsdlab/chocosolver` master) |
| jar under test | `target/chocosolver-0.4.4-jar-with-dependencies.jar` from `mvn -DskipTests package`, SHA-256 `60a9a4f4540cf4982ffe03440dafdbf36b1899a6a4401d8a4ab769b4872a6fc9`; class content identical outside `META-INF` to the jar built on 2026-09-10 for the clafer harness |
| `choco-solver:4.0.0` | Maven Central artifact, SHA-1 `aec0dc6a0e6a19c13efbe9d90a73bdaaf0508f2a` (SHA-256 `c7c3e8ace465f04e3ddd8e4383cd4c664251b77215b5dc04fe528872a822c5bb`) |
| JDK / Maven | OpenJDK 21.0.2 / Apache Maven 3.9.16 |
| Platform | aarch64 macOS (Darwin 25.6).  chocosolver is pure JVM; the first GitHub Actions capture of the build-modernization stage will confirm x86_64 Linux parity against this reference |
| clafer compiler (the three `.cfr` models) | Sigil clafer fork, commit `cefa7aa35f3b32c1811b2283fe715ed32081e7ae`, `Clafer 0.5.1` |
| test suite | `test-suite.txt`: 742 tests, 0 failures, 0 errors, 3 skipped (`@Ignore` in the 0.4.4 sources) |

---

*HOARDE Claude (working with Frank Zeyda)*

<!--
Local Variables:
auto-fill-mode: nil
End:
-->

# Verification status

What has actually been run, as against what has been claimed. Keep the
distinction — the docs have twice overstated this.

As of 2026-09-10.

| | Windows x86-64 | macOS arm64 | Linux x86-64 |
|---|---|---|---|
| Static library builds | yes | yes | yes |
| MEX link | yes | yes | yes |
| `just mex-test` (offline) | yes | **unconfirmed** | yes, 10/10 |
| Live deployment | yes | yes | yes |
| `native-libs` list confirmed | yes | yes | yes |

Live means `nominalexample_alldemos` completing 7 of 7 against the deployment
from an installed `.mltbx`: macOS arm64 and Linux x86-64 both on 2026-09-10,
macOS also via the HELLOWORLD.md walkthrough.

The macOS `just mex-test` cell stays unconfirmed. A live run exercises
strictly more than the offline smoke test, but nobody has said that command
itself was run, and this table records what was run rather than what follows
from it.

## Outstanding

- **macOS smoke test.** The macOS work claimed "verified end to end" without
  stating whether `just mex-test` was run. A merge resolution briefly asserted
  it had been, for all three platforms; that was an overstatement and was
  walked back. Ask before writing it down as fact.
- ~~Live API on macOS and Linux.~~ Done — all three platforms have run the
  full suite against a real deployment: auth, listings, `datasetByRid`,
  channel metadata, `write`, streaming, `ingest`, `fetch` both modes,
  `export`, SQL query and export.
- **MATLAB below R2026a.** Untested everywhere. README claims R2021a as the
  floor based on syntax used, not on a real install. `toNanos.m` and
  `fromNanos.m` rely on `convertTo(..., 'epochtime', ...)`, which is newer than
  the `arguments` blocks and is the actual constraint.

## Linux specifics (2026-09-09)

Fedora 44 WSL2, rustc 1.98.1, gcc 16.1.1, MATLAB R2026a Update 5, just 1.55.1.

- `cargo build --release` → `libnominal_ffi.a`, 591 MB, ~3m03s with fat LTO
- `nominalmex.mexa64`, 102 MB
- `cargo test --workspace` → 11 passed, 2 ignored
- `cargo clippy -- -D warnings`, `cargo fmt --check` → clean
- `just lint-matlab` → 0 issues across 31 files
- `just mex-test` → 10 passed, 0 failed

`ldd` on the built `.mexa64` reports `libmx.so`, `libmex.so` and `libmat.so`
as not found. That is expected — MATLAB supplies them to the process at load
time. Not a defect, do not "fix" it.

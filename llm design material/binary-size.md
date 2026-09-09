# Gateway binary size

**The Linux and macOS gateways were ~3x the Windows one because the static
symbol table was never stripped. Not because of debug info.**

Fixed 2026-09-09 by `stripSymbols()` in `build.m`, called after `mex()` for
release builds on non-Windows hosts.

## Measurements

Linux gateway, before the fix:

| | bytes |
|---|---|
| original | 106,882,232 |
| `strip --strip-debug` (DWARF only) | 100,850,808 |
| `strip --strip-all` | 53,862,560 |

Raw sizes across platforms, same commit:

| | bytes |
|---|---|
| `nominalmex.mexa64` | 106,882,232 |
| `nominalmex.mexmaca64` | 93,463,880 |
| `nominalmex.mexw64` | 34,503,168 |

Dominant ELF sections before stripping:

| Section | bytes |
|---|---|
| `.strtab` | 41,499,897 |
| `.text` | 37,418,432 |
| `.eh_frame` | 6,524,744 |
| `.symtab` | 5,537,520 |
| `.rodata` | 2,599,520 |
| `.debug_*` (all) | ~5,900,000 |

So 47 MB of symbol names and 6 MB of DWARF. `nominal-api-conjure` contributes
3,574 generated files' worth of mangled Rust symbols, which is where a 41 MB
string table comes from.

## Why cargo cannot fix this

`[profile.release] strip = true` is already set in the workspace `Cargo.toml`,
and `libnominal_ffi.a` *still* contains `.debug_info`, `.debug_str` and a full
symbol table. That is correct behaviour, not a bug:

- A `staticlib` must keep its symbols or the linker could not resolve anything
  against it.
- Cargo's `strip` applies to artifacts cargo links. A staticlib has no link
  step, so there is nothing for it to act on.
- The final link is performed by MATLAB's `mex`, outside cargo entirely.

Stripping is only meaningful after `mex` links. Hence `build.m`, not
`Cargo.toml`. Do not "fix" this by changing the cargo profile —
`strip = "debuginfo"` in particular is strictly weaker than the `strip = true`
already there, and would recover ~6 MB of a ~72 MB gap even if it did apply.

## Safety

`strip --strip-all` does not touch `.dynsym`, so `mexFunction@@MEX` stays
exported — verified with `readelf --dyn-syms`, 274 dynamic FUNC symbols
remaining. Smoke test passes 10/10 against the stripped gateway.

The strip is gated on `options.Profile == "release"`, matching the existing
profile intent (`release` sets `strip = true`, `fast` sets `strip = false`).
`build(Profile="fast")` therefore keeps symbols for debugging.

`stripSymbols()` warns rather than errors on failure: a missing `strip` costs
size, not correctness.

## macOS

Uses `strip -S -x`, which keeps global symbols. **Untested** as of 2026-09-09 —
implemented from the Linux result, not verified on a Mac. Needs
`just mex-macos-arm64 && just mex-test` on that host. Expect roughly 93 MB to
somewhere near 50 MB.

## The remaining gap

Stripped Linux is 53.9 MB against Windows' 34.5 MB, still 1.56x. Not
investigated. Likely contributors:

- `.eh_frame` + `.gcc_except_table` = 8.3 MB of DWARF unwind tables. Windows
  uses `.pdata`/`.xdata` for SEH, which is more compact.
- MSVC links with `/OPT:ICF` and `/OPT:REF` by default, folding identical
  COMDATs. Rust monomorphisation generates many duplicate functions. GNU ld
  does not do this without `--icf`, which needs gold or lld.

`-Wl,--gc-sections` and `--icf=all` are the obvious next levers, both carrying
more risk than a strip. Nobody has asked for it.

## Do not mistake compression for evidence

An early hypothesis was that embedded DWARF explained the gap, supported by
Windows compressing worst (2.84x vs 4.45x). That inference does not
discriminate: mangled symbol strings are long and highly repetitive, so they
compress at least as well as DWARF. Both hypotheses predict the same
compression signature. The `strip --strip-debug` versus `--strip-all`
comparison is what actually separates them.

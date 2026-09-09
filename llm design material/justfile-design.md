# justfile design

## The MATLAB variable, and why $MATLAB is not read

The justfile reads `MATLAB_ROOT` (install directory, executable derived from it)
or `MATLAB_BIN` (the executable itself). `just matlab=...` still overrides both.

It used to read `MATLAB` as the path to the *executable*. That collides with the
near-universal convention that `$MATLAB` is the installation **root** — so
anyone setting it the conventional way made `just` try to execute a directory,
with an error naming neither cause. Do not reintroduce `$MATLAB`.

Resolution order, verified 2026-09-09:

| Environment | Result |
|---|---|
| `MATLAB_BIN` set | `MATLAB_BIN` (wins over root) |
| `MATLAB_ROOT` set | `<root>/bin/matlab[.exe]` |
| neither | bare `matlab` / `matlab.exe` |
| legacy `MATLAB=<root>` | ignored — bare name, no breakage |
| `just matlab=/x` | `/x` |

`matlab_exe` uses `os()` to pick `matlab.exe` on Windows. Recipes run through
bash, so paths need forward slashes; backslashes are eaten as escapes.

## Recipe listing is generated, not hand-written

`default` is `[private]` and runs `@just --list`. There used to be a `help`
recipe echoing a hand-maintained list. It was deleted because:

- It had drifted to 18 of 30 recipes. `build-linux-x64` was among the missing,
  which is how a Linux build went unnoticed as unexercised.
- It didn't suppress command echo, so `just` printed every `echo` command
  alongside its output.

Do not reintroduce a hand-maintained list.

## just behaviours this depends on

- **No `default` recipe → `just` runs the first recipe in the file**, whatever
  it is named. `default` is convention, not magic. It runs even if that recipe
  is `[private]`. If the first recipe takes a required argument, `just` errors
  instead. Consequence here: `default` must stay physically first, or bare
  `just` would run `header` and rewrite the generated header.
- **A recipe's description is the *last* contiguous comment line above it.** A
  multi-line comment block gets truncated to its final line, which reads as a
  mid-sentence fragment in `--list`. Put a blank line between a long block and
  the one-line description. This bit `lint-rust` and `lint-matlab`.
- `[group('name')]` groups recipes in `--list`. `[private]` hides them.
- Verified against just 1.55.1.

## Platform handling

Recipes are named per platform (`mex-win64`, `mex-macos-arm64`,
`mex-linux-x64`) but `build.m`'s `platformSettings()` already detects the host
via `ispc`/`ismac`, so the suffixes largely duplicate that.

A MEX gateway cannot be cross-compiled — it links against the host MATLAB — so
host detection is the correct model, not a workaround. These could collapse to
`just build` / `just mex` with `alias mex-win64 := mex` for muscle memory,
which the file already does for `mex-test-win64`. Not done as of 2026-09-09:
it rewrites nearly every line, and a parallel session was editing the file.

`just` also supports `[linux]`/`[macos]`/`[windows]` attributes (same recipe
name defined per platform) and `import`/`mod` for real multi-file splits, if a
per-platform split is ever actually wanted.

# Building and installing

Building produces one file: `matlab/+nominal/private/nominalmex.mexw64` (or
`.mexa64` / `.mexmaci64`). The Rust library is linked into it statically, so
there is no accompanying DLL, nothing to register, and nothing to put on
`PATH`. Installing means getting `matlab/` onto the MATLAB path.

Once it is built, see [USAGE.md](USAGE.md) for authenticating and using it.

## Prerequisites

| | |
|---|---|
| Rust | stable, plus the target triple for your platform |
| MATLAB | R2021a or newer, with a configured C compiler — check with `mex -setup C` |
| [`just`](https://github.com/casey/just) | runs the recipes below |
| [`cbindgen`](https://github.com/mozilla/cbindgen) | only if you change the Rust FFI surface |

## Building

From the repository root:

```
just              # same as just mex-win64
```

That builds the Rust static library, then compiles `matlab/src/nominalmex.c`
against it. If MATLAB is not on `PATH`, point the recipe at it — recipes run
through bash, so use forward slashes:

```
just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
```

Then check it:

```
just mex-test     # offline smoke test, no network needed
```

### Other platforms

`build.m` picks its cargo target and linker flags from the host it runs on, so
the recipes differ only in which static library they build first:

```
just mex-win64          just mex-macos-arm64      just mex-linux-x64
just mex-win64-fast     just mex-macos-arm64-fast just mex-macos-x64
```

**Only the Windows path has been verified end to end.** The macOS and Linux
system-library lists in `platformSettings()` are the usual set for this
dependency tree, not a tested configuration. On a new host, get the
authoritative list and reconcile:

```
just native-libs
```

A Rust staticlib does not record its own dependencies the way a shared library
does, which is why that list has to be maintained by hand. Re-run it after a
dependency bump, or whenever a link reports an unresolved symbol.

### The `-fast` variants

`release` uses fat LTO, which re-optimises the whole dependency graph on every
edit — around two minutes per rebuild. The `fast` profile turns LTO off and
drops to `opt-level = 2`, which is the right trade while iterating. Ship the
release build.

### Regenerating the header

`crates/ffi/include/nominal_ffi.h` is generated. Never hand-edit it:

```
just header
```

## The edit-build-test loop

What to run depends on which layer you touched.

| Changed | Run |
|---|---|
| `matlab/+nominal/*.m`, `matlab/examples/*.m` | nothing — but see the caching note below |
| `matlab/src/nominalmex.c` | `just mex-win64-fast` |
| `crates/ffi/src/*.rs` | `just mex-win64-fast` |
| A Rust export added, renamed or removed | `just header` **first**, then `just mex-win64-fast` |

Then `just lint` (clippy and MATLAB `checkcode`), `just test` (Rust), and
`just mex-test` (the offline MATLAB smoke test).

`just header` before the rebuild is the one that catches people out: the C
gateway includes the generated header, so a new `nominal_*` export does not
exist as far as the compiler is concerned until cbindgen has run.

### MATLAB caches compiled functions

An open MATLAB session keeps compiled copies of the `.m` files it has run. It
usually notices a changed file, but **not reliably when the change came from
outside the MATLAB editor** — a text editor, a git checkout, or an agent
writing files. The symptom is a stack trace whose line numbers and source text
do not match the file on disk.

Before re-running anything after an external edit:

```matlab
clear functions      % drop cached .m code
rehash path          % if you added or renamed a file
```

`clear functions` is enough for edits to existing files, and unlike `clear all`
it leaves your workspace variables — including whatever the demos published —
intact. `clear mex` additionally unloads the gateway, which is what you want
before overwriting the binary with a rebuild.

## Installing

### This session only

```matlab
addpath('C:\sw\nominal-matlab\matlab')
```

Add the **parent** folder, not `matlab\+nominal`. MATLAB discovers a package
folder from its parent, and warns if you path a `+folder` directly.

### Every session, on this machine

Put the same line in `startup.m`, in your `userpath` folder — find it by
running `userpath`, typically `~/Documents/MATLAB`:

```matlab
% <userpath>/startup.m
addpath('C:\sw\nominal-matlab\matlab');
```

Preferable to `savepath`, which rewrites a generated `pathdef.m` that often
needs admin rights and is not something you can read or keep in version
control.

### As an installable toolbox, for other people

This is the real answer to "install it". Packaging produces a single `.mltbx`
that colleagues double-click: it registers under **Add-Ons**, manages the path
itself, and supports versioning and uninstall.

```
just package
```

That builds a release gateway, then runs `tools/package.m` to write
`dist/NominalForMATLAB-<version>.mltbx`. Install it with
`matlab.addons.install("dist/NominalForMATLAB-0.1.0.mltbx")`, or by
double-clicking.

The version comes from the workspace `Cargo.toml`, so bump it there. The
packaged platforms come from which MEX binaries are sitting in
`+nominal/private/` at the time — a toolbox can carry all of them at once
(`nominalmex.mexw64`, `.mexa64`, `.mexmaci64` side by side; MATLAB picks by
`mexext`), so to ship a multi-platform build, collect each host's gateway into
that folder before packaging. `just package` only builds the Windows one
itself.

Everything else the packager decides — the fixed identifier UUID, which folders
land on the installed path, the `MinimumMatlabRelease` floor — is set and
explained in [tools/package.m](tools/package.m).

## Build artifacts and version control

`nominalmex.mexw64` and its siblings are gitignored, as is `dist/`. Static
linking took the gateway from 44 KB to roughly 35 MB, and git keeps every
version, so committing a rebuild each time would grow the repository fast.
A fresh clone therefore has no gateway until you run `just` — and releases
carry the `.mltbx` rather than the loose binary.

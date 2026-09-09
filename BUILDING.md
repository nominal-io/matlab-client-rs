# Building and installing

Building produces one file: `matlab/+nominal/private/nominalmex.mexw64` (or
`.mexa64` / `.mexmaca64`). The Rust library is linked into it statically, so
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

On a minimal Linux image the MathWorks installer needs GUI libraries that are
not installed by default — its UI is embedded Chromium. Without them `./install`
exits with status 42 and prints nothing, in silent mode as well as interactive.
On Fedora:

```
sudo dnf install alsa-lib atk at-spi2-atk at-spi2-core mesa-libgbm \
                 libglvnd-glx libXcomposite libXdamage libXfixes libXrandr
```

Nothing in this repository needs OpenSSL — TLS is rustls throughout — so a
build that fails in `openssl-sys` means a dependency has re-enabled reqwest's
`default-tls` feature. Fix the feature flags rather than installing OpenSSL.

## Building

From the repository root, run the recipe for your platform — `just` on its own
lists them:

```
just mex-win64    # or mex-macos-arm64, or mex-linux-x64
```

That builds the Rust static library, then compiles `matlab/src/nominalmex.c`
against it.

If MATLAB is not on `PATH`, set `MATLAB_ROOT` to the installation directory and
the recipes derive the executable from it:

```
export MATLAB_ROOT='C:/Program Files/MATLAB/R2026a'    # Windows
export MATLAB_ROOT=/usr/local/MATLAB/R2026a            # Linux
export MATLAB_ROOT=/Applications/MATLAB_R2026a.app     # macOS
```

For an install that does not follow the usual `<root>/bin/matlab` layout, set
`MATLAB_BIN` to the executable itself instead; it takes precedence. Either way
the recipes run through bash, so use forward slashes — backslashes are eaten as
escapes before the path reaches the executable. A one-off still works too:

```
just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
```

Note that `MATLAB` itself is not read. It used to be, as the path to the
executable — but nearly everything else in the ecosystem uses `$MATLAB` for the
installation *root*, and setting it that way made `just` try to execute a
directory. `MATLAB_ROOT` is that conventional meaning, spelled unambiguously.

Then check it:

```
just mex-test     # offline smoke test, no network needed
```

### Other platforms

`build.m` picks its cargo target and linker flags from the host it runs on, so
the recipes differ only in which static library they build first:

```
just mex-win64          just mex-macos-arm64      just mex-linux-x64
just mex-win64-fast     just mex-macos-arm64-fast
```

Windows x86-64, Apple silicon and Linux x86-64. Intel macOS is not a target —
`build.m` errors on one rather than building a triple that has never been
linked.

**All three platforms have been verified end to end** — Windows x86-64, Apple
silicon and Linux x86-64, each through the static library, the MEX link and the
offline smoke test. The system-library lists in `platformSettings()` are
therefore observed rather than guessed. They are still per-host and still hand
maintained, so on a new host — or after a dependency bump changes the graph —
get the authoritative list and reconcile:

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
`+nominal/private/` at the time.

One `.mltbx` can carry every platform at once — MATLAB picks by `mexext` — but
`just package` builds only the Windows gateway. For a multi-platform build, see
[PACKAGING.md](PACKAGING.md), which uses `just package-only`.

Everything else the packager decides — the fixed identifier UUID, which folders
land on the installed path, the `MinimumMatlabRelease` floor — is set and
explained in [tools/package.m](tools/package.m).

## Build artifacts and version control

`nominalmex.mexw64` and its siblings are gitignored, as is `dist/`. Static
linking makes the gateway large, and git keeps every version, so committing a
rebuild each time would grow the repository fast.
A fresh clone therefore has no gateway until you run `just` — and releases
carry the `.mltbx` rather than the loose binary.

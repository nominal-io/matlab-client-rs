# Building and installing

Building produces one file: `matlab/+nominal/private/nominalmex.mexw64` (or
`.mexa64` / `.mexmaca64`). The Rust library is linked in statically, so there
is no DLL and nothing to put on `PATH`. Installing means getting `matlab/` onto
the MATLAB path.

Once it is built, see [USAGE.md](USAGE.md).

## Prerequisites

| | |
|---|---|
| Rust | stable, plus the target triple for your platform |
| MATLAB | R2021a or newer, with a configured C compiler (check with `mex -setup C`) |
| [`just`](https://github.com/casey/just) | runs the recipes below |
| [`cbindgen`](https://github.com/mozilla/cbindgen) | only if you change the Rust FFI surface |

On a minimal Linux image the MathWorks installer needs GUI libraries that are
not installed by default. Without them `./install` exits with status 42 and
prints nothing, even in silent mode. On Fedora:

```
sudo dnf install alsa-lib atk at-spi2-atk at-spi2-core mesa-libgbm \
                 libglvnd-glx libXcomposite libXdamage libXfixes libXrandr
```

Nothing here needs OpenSSL; TLS is rustls throughout. A build that fails in
`openssl-sys` means a dependency has re-enabled reqwest's `default-tls`
feature. Fix the feature flags, do not install OpenSSL.

## Building

From the repository root, run the recipe for your platform. `just` on its own
lists them:

```
just mex-win64    # or mex-macos-arm64, or mex-linux-x64
```

That builds the Rust static library, then compiles `matlab/src/nominalmex.c`
against it.

If MATLAB is not on `PATH`, set `MATLAB_ROOT` to the installation directory:

```
export MATLAB_ROOT='C:/Program Files/MATLAB/R2026a'    # Windows
export MATLAB_ROOT=/usr/local/MATLAB/R2026a            # Linux
export MATLAB_ROOT=/Applications/MATLAB_R2026a.app     # macOS
```

For an install that does not follow the usual `<root>/bin/matlab` layout, set
`MATLAB_BIN` to the executable itself; it takes precedence. The recipes run
through bash, so use forward slashes. A one-off works too:

```
just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
```

`MATLAB` itself is not read: most tools use `$MATLAB` for the install root, so
`MATLAB_ROOT` spells that out.

Then check it:

```
just mex-test     # offline smoke test, no network needed
```

### Other platforms

`build.m` picks its cargo target and linker flags from the host, so the recipes
differ only in which static library they build first:

```
just mex-win64          just mex-macos-arm64      just mex-linux-x64
just mex-win64-fast     just mex-macos-arm64-fast
```

Windows x86-64, Apple silicon and Linux x86-64 have all been built and linked.
Intel macOS is not a target; `build.m` errors on one.

The system-library lists in `platformSettings()` are hand maintained, because
a Rust staticlib does not record its own dependencies. On a new host, after a
dependency bump, or when a link reports an unresolved symbol, get the real list
and reconcile:

```
just native-libs
```

### The `-fast` variants

`release` uses fat LTO, which re-optimises the whole dependency graph on every
edit, around two minutes per rebuild. The `fast` profile turns LTO off and
drops to `opt-level = 2`. Use it while iterating; ship the release build.

### Regenerating the header

`crates/ffi/include/nominal_ffi.h` is generated. Never hand-edit it:

```
just header
```

## The edit-build-test loop

| Changed | Run |
|---|---|
| `matlab/+nominal/*.m`, `matlab/examples/*.m` | nothing, but see the caching note below |
| `matlab/src/nominalmex.c` | `just mex-win64-fast` |
| `crates/ffi/src/*.rs` | `just mex-win64-fast` |
| A Rust export added, renamed or removed | `just header` **first**, then `just mex-win64-fast` |

Then `just lint` (clippy and MATLAB `checkcode`), `just test` (Rust), and
`just mex-test` (the offline MATLAB smoke test).

`just header` before the rebuild is the step people forget. The C gateway
includes the generated header, so a new `nominal_*` export does not exist as
far as the compiler is concerned until cbindgen has run.

### MATLAB caches compiled functions

An open MATLAB session keeps compiled copies of the `.m` files it has run, and
does not reliably notice a change made outside the MATLAB editor (a text
editor, a git checkout, an agent). The symptom is a stack trace whose line
numbers and source text do not match the file on disk.

Before re-running anything after an external edit:

```matlab
clear functions      % drop cached .m code
rehash path          % if you added or renamed a file
```

`clear functions` leaves your workspace variables intact, unlike `clear all`.
`clear mex` also unloads the gateway, which you want before overwriting the
binary with a rebuild.

## Installing

### This session only

```matlab
addpath('C:\sw\nominal-matlab\matlab')
```

Add the **parent** folder, not `matlab\+nominal`. MATLAB warns if you path a
`+folder` directly.

### Every session, on this machine

Put the same line in `startup.m`, in your `userpath` folder (run `userpath` to
find it, typically `~/Documents/MATLAB`):

```matlab
% <userpath>/startup.m
addpath('C:\sw\nominal-matlab\matlab');
```

This beats `savepath`, which rewrites a generated `pathdef.m` that often needs
admin rights.

### As an installable toolbox, for other people

Packaging produces a single `.mltbx` that colleagues double-click. It registers
under **Add-Ons**, manages the path itself, and supports versioning and
uninstall.

```
just package
```

That builds a release gateway, then runs `tools/package.m` to write
`dist/NominalForMATLAB-<version>.mltbx`. Install it with
`matlab.addons.install("dist/NominalForMATLAB-0.1.0.mltbx")` or by
double-clicking.

The version comes from the workspace `Cargo.toml`, so bump it there. The
packaged platforms are whichever MEX binaries are in `+nominal/private/` at the
time.

`just package` builds only the Windows gateway. For one `.mltbx` carrying every
platform, see [PACKAGING.md](PACKAGING.md).

The packager's other decisions (the fixed identifier UUID, which folders land
on the installed path, the `MinimumMatlabRelease` floor) are set and explained
in [tools/package.m](tools/package.m).

## Build artifacts and version control

`nominalmex.mexw64` and its siblings are gitignored, as is `dist/`. Static
linking makes the gateway large, so committing rebuilds would grow the
repository fast. A fresh clone has no gateway until you run `just`, and
releases carry the `.mltbx`, not the loose binary.

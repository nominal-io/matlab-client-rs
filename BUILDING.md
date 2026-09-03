# Building and installing

Building produces one file: `matlab/+nominal/private/nominalmex.mexw64` (or
`.mexa64` / `.mexmaci64`). The Rust library is linked into it statically, so
there is no accompanying DLL, nothing to register, and nothing to put on
`PATH`. Installing means getting `matlab/` onto the MATLAB path.

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

```matlab
opts = matlab.addons.toolbox.ToolboxOptions("matlab", "<a-uuid>");
opts.ToolboxName          = "Nominal for MATLAB";
opts.ToolboxVersion       = "0.1.0";
opts.Summary              = "Native MATLAB client for Nominal";
opts.MinimumMatlabRelease = "R2021a";

% Only the platforms whose MEX binary is actually in the folder. MATLAB then
% refuses to install elsewhere, rather than installing and failing on the
% first call.
opts.SupportedPlatforms.Win64        = true;
opts.SupportedPlatforms.Maci64       = false;
opts.SupportedPlatforms.Glnxa64      = false;
opts.SupportedPlatforms.MatlabOnline = false;

opts.OutputFile = "NominalForMATLAB.mltbx";
matlab.addons.toolbox.packageToolbox(opts);
```

Install it with `matlab.addons.install("NominalForMATLAB.mltbx")`, or by
double-clicking.

Three things to get right:

**Keep `examples/` off the installed path.** It exports `connect.m` — a generic
name very likely to collide with a user's own code or another toolbox. Either
exclude `examples/` and `tests/` from `ToolboxMatlabPath`, or move the helper
into the package as `nominal.connect` first.

**A toolbox can carry every platform at once.** Put `nominalmex.mexw64`,
`.mexa64` and `.mexmaci64` side by side in `+nominal/private/` and MATLAB picks
by `mexext`. Set the matching `SupportedPlatforms` flags as they land.

**`MinimumMatlabRelease` is a claim, not a check.** R2021a is the floor implied
by the `Name=Value` call syntax used throughout, but nothing below R2026a has
been tested — see the Requirements section of the README.

## Build artifacts and version control

`matlab/+nominal/private/nominalmex.mexw64` is currently tracked in git, and
static linking took it from 44 KB to roughly 35 MB. Git keeps every version, so
committing a rebuild each time will grow the repository quickly. It is a build
output and belongs in `.gitignore`, with releases carrying the `.mltbx`
instead.

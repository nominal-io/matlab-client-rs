# Packaging a multi-platform toolbox

How to get one `.mltbx` that installs on Windows, macOS and Linux.

MEX binaries cannot be cross-compiled — the link needs the MATLAB installed on
the target platform — so each gateway is built on its own machine. A `.mltbx`
can then carry all of them at once: MATLAB picks the right one by `mexext` at
call time. The result is a single file you hand to anyone.

For installing the finished file, see [HELLOWORLD.md](HELLOWORLD.md). For what
the build is doing, see [BUILDING.md](BUILDING.md).

## Before you start

On every machine:

- The **same commit**. Different source in different binaries is the one
  failure mode this process can't detect — the package will build happily and
  behave differently per platform.
- **Rust** (`rustup`, stable) and **`just`**.
- **MATLAB R2021a or newer**, with a C compiler configured (`mex -setup C`).
- **`cbindgen`** — `cargo install cbindgen` — for the `header` step.

If `matlab` isn't on `PATH`, pass it in. Recipes run through `sh`, so use
forward slashes even on Windows:

```
just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
just matlab='/Applications/MATLAB_R2024b.app/bin/matlab' mex-macos-arm64
```

## 1. Build the gateway on each machine

One command per host. Each builds the Rust static library in release, then
links it into a MEX file.

| Machine | Command | Produces |
|---|---|---|
| Windows x86-64 | `just mex-win64` | `nominalmex.mexw64` |
| macOS Apple silicon | `just mex-macos-arm64` | `nominalmex.mexmaca64` |
| macOS Intel | `just mex-macos-x64` | `nominalmex.mexmaci64` |
| Linux x86-64 | `just mex-linux-x64` | `nominalmex.mexa64` |

All four land in `matlab/+nominal/private/`.

Don't run bare `just` off Windows — the default recipe is `mex-win64`, and it
will try to build for a Windows target on whatever host you're on.

The two macOS rows need two physical Macs. An Apple silicon machine can produce
an Intel *library* with `rustup target add x86_64-apple-darwin`, but the MEX
link still needs an Intel MATLAB to link against.

Sanity-check each build before moving on — no network needed:

```
just mex-test
```

## 2. Collect the binaries onto one machine

Pick whichever machine you'll package on. Copy the other hosts' gateways into
its checkout, alongside the one already there:

```
matlab/+nominal/private/
├── nominalmex.mexw64        from the Windows box
├── nominalmex.mexmaca64     from the Apple silicon Mac
├── nominalmex.mexmaci64     from the Intel Mac
└── nominalmex.mexa64        from the Linux box
```

Copy only these files. They're gitignored, so `git pull` won't disturb them and
you can't accidentally commit them.

## 3. Package, once

```
just package-only
```

Writes `dist/NominalForMATLAB-<version>.mltbx` and prints what it claimed:

```
Packaging Nominal for MATLAB 0.1.0
  platforms: Win64, Glnxa64, Mac
Wrote .../dist/NominalForMATLAB-0.1.0.mltbx (…)
```

Expect it to be large. Each gateway is around 35 MB with the Rust library
statically linked in, and a multi-platform box carries one per platform —
Windows alone compresses to roughly 12 MB.

Check the platforms line. `tools/package.m` derives `SupportedPlatforms` from the
binaries actually present, so a platform missing from it is a gateway you
forgot to copy — and MATLAB will refuse to install on that platform rather
than installing and failing on the first call. Both macOS variants map to the
single `Mac` flag.

**Use `package-only`, not `package`.** `just package` depends on `mex-win64`,
so it rebuilds the Windows gateway and works only on Windows. `package-only`
packages what's in the tree and builds nothing, which is the whole point here.
The tradeoff is that it will happily package a `-fast` gateway, so make sure
step 1 used the release recipes above.

The version comes from `[workspace.package]` in the root `Cargo.toml` — bump it
there, not in `tools/package.m`.

## 4. Verify

Install on each platform and check the gateway loads:

```matlab
matlab.addons.install("NominalForMATLAB-0.1.0.mltbx")
nominal.now()          % reaches native code; fails loudly if the MEX is wrong
```

`nominal.now()` is the cheapest call that actually crosses into the library, so
it distinguishes "toolbox installed" from "toolbox works" without credentials
or a network.

## Platform status

Only the Windows path has been built and exercised end to end. The macOS and
Linux recipes are written but unverified — specifically, `platformSettings()`
in `matlab/build.m` names each platform's system libraries by hand, because a
Rust staticlib doesn't record its own dependencies, and those lists are guesses
off Windows.

If a MEX link fails with unresolved symbols, get the real list from the host
that's failing and reconcile it against `platformSettings()`:

```
just native-libs
```

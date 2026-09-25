# Packaging a multi-platform toolbox

How to get one `.mltbx` that installs on Windows, macOS and Linux.

MEX binaries cannot be cross-compiled, so each gateway is built on its own
machine. One `.mltbx` can then carry all of them; MATLAB picks the right one by
`mexext` at call time.

For installing the finished file, see [HELLOWORLD.md](HELLOWORLD.md). For what
the build is doing, see [BUILDING.md](BUILDING.md).

## Before you start

On every machine:

- The **same commit**. Different source in different binaries is the one
  failure this process cannot detect.
- **Rust** (`rustup`, stable) and **`just`**.
- **MATLAB R2021a or newer**, with a C compiler configured (`mex -setup C`).
- **`cbindgen`** (`cargo install cbindgen`) for the `header` step.

If `matlab` isn't on `PATH`, pass it in. Recipes run through `sh`, so use
forward slashes even on Windows:

```
just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
just matlab='/Applications/MATLAB_R2024b.app/bin/matlab' mex-macos-arm64
```

## 1. Build the gateway on each machine

| Machine | Command | Produces |
|---|---|---|
| Windows x86-64 | `just mex-win64` | `nominalmex.mexw64` |
| macOS Apple silicon | `just mex-macos-arm64` | `nominalmex.mexmaca64` |
| Linux x86-64 | `just mex-linux-x64` | `nominalmex.mexa64` |

All three land in `matlab/+nominal/private/`.

Don't run bare `just` off Windows. The default recipe is `mex-win64`.

Intel macOS is not supported; `build.m` refuses to run on one.

Sanity-check each build before moving on, no network needed:

```
just mex-test
```

## 2. Collect the binaries onto one machine

Pick the machine you'll package on. Copy the other hosts' gateways into its
checkout:

```
matlab/+nominal/private/
├── nominalmex.mexw64        from the Windows box
├── nominalmex.mexmaca64     from the Apple silicon Mac
└── nominalmex.mexa64        from the Linux box
```

They're gitignored, so `git pull` won't disturb them and you can't commit them
by accident.

## 3. Package, once

```
just package-only
```

Writes `dist/NominalForMATLAB-<version>.mltbx` and prints what it included:

```
Packaging Nominal for MATLAB 0.1.0
  platforms: Win64, Glnxa64, Mac
Wrote .../dist/NominalForMATLAB-0.1.0.mltbx (…)
```

Expect it to be large. Each gateway is around 35 MB with the Rust library
linked in, and Windows alone compresses to roughly 12 MB.

Check the platforms line. It is derived from the binaries actually present, so
a missing platform is a gateway you forgot to copy. MATLAB refuses to install
the toolbox on a platform it does not list.

**Use `package-only`, not `package`.** `just package` rebuilds the Windows
gateway and works only on Windows. `package-only` packages what is in the tree
and builds nothing. It will also happily package a `-fast` gateway, so make
sure step 1 used the release recipes.

The version comes from `[workspace.package]` in the root `Cargo.toml`. Bump it
there.

## 4. Verify

Install on each platform and check the gateway loads:

```matlab
matlab.addons.install("NominalForMATLAB-0.1.0.mltbx")
nominal.now()          % reaches native code; fails loudly if the MEX is wrong
```

`nominal.now()` is the cheapest call that crosses into the library, so it
tells "installed" from "works" without credentials or a network.

## Platform status

All three gateways have been built and linked on real hardware, and all three
have run the full demo suite against the live API.

If a MEX link fails with unresolved symbols, the hand-maintained library list
in `platformSettings()` in `matlab/build.m` is out of date for that host. Get
the real list and reconcile:

```
just native-libs
```

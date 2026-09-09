# Installing MATLAB on a minimal Linux host

Notes from getting R2026a onto Fedora 44 (WSL2) on 2026-09-09. The graphical
installer cannot start on a stock minimal image, and fails in a way that looks
like success.

## `./install` exits 42 and prints nothing

`./install` is a shell wrapper that execs `bin/glnxa64/MathWorksProductInstaller`.
That binary's UI is embedded Chromium (CEF). On a minimal image the CEF
libraries are missing, so it exits with status **42** and no message at all —
`/tmp/mathworks_<user>.log` gets a system-info header and stops.

This is easy to misread as "the installer ran and silently succeeded".

`ldd` on the main binary shows nothing missing; the gap is in `libcef.so`,
`libmwcefclientlib.so` and `libmwcef_common.so`. Fedora packages:

```
sudo dnf install alsa-lib atk at-spi2-atk at-spi2-core mesa-libgbm \
                 libglvnd-glx libXcomposite libXdamage libXfixes libXrandr
```

Silent mode (`-inputFile`) does **not** avoid this — it reads the input file,
then dies at the same point. There is no GUI-free path through this installer.

Red herrings: `libQt6*`, `libicu*`, `libPocoFoundation`, `libmwboost_*`,
`libssl-mw`, `libxcb-*` and `libxkbcommon-x11` also show as unresolved under
`ldd`, but MATLAB bundles all of those in `bin/glnxa64` and resolves them at
runtime. Only the ten above are genuine system gaps.

## The GUI login then hangs

With the libraries installed the UI appears, but the MathWorks account login
hung. Not diagnosed — `mpm` was used instead.

## mpm is the better route

`mpm` (MathWorks Package Manager) skips both the GUI and the login:

```
./mpm install --products MATLAB --release R2026a
```

Installed to `/usr/local/MATLAB/R2026a`. It ships alongside the installer in
the same download folder.

Note the `archives/` directory in a network installer holds only ~16 MB / 2
files, so `mpm --source` is not usable there — it downloads products.

## mpm does not license

Deliberate. After `mpm install`, MATLAB reports:

```
MathWorks Licensing Error 1 / Unable to find a license for MATLAB. / Error Code: -1.2
```

This install uses **Login Named User** licensing — no `.lic` file anywhere,
including on the licensed Windows install (checked `<matlabroot>/licenses`,
`C:\ProgramData\MathWorks`). So there is no license file to copy across; it
authenticates against a MathWorks account and caches a token. Activation was
done interactively.

Diagnosing license type is worth doing before offering solutions: absence of
any `.lic` under both the install root and `ProgramData` means LNU, not a
network or file-based license, and rules out "just point it at the license
server".

## Environment afterwards

- `~/.bashrc` exports `MATLAB_ROOT=/usr/local/MATLAB/R2026a` and **appends**
  `$MATLAB_ROOT/bin` to `PATH`. Appended, not prepended, because that directory
  also carries `mex`, `mbuild` and `mcc`.
- MATLAB warns `Unable to locate a personal folder for $documents/MATLAB` on
  every invocation if `~/Documents` does not exist. `mkdir -p
  ~/Documents/MATLAB` fixes it; that is also where `startup.m` goes.
- `mex` picked up gcc 16.1.1 without complaint, which is far newer than
  MathWorks documents as supported. It links and the smoke test passes; treat
  it as working-but-untested-upstream.

#!/usr/bin/env just --justfile

# MATLAB is often not on PATH. Override with the full path to matlab.exe.
# Recipes run through bash, so use forward slashes — backslashes are eaten as
# escapes before the path ever reaches the executable:
#   just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
matlab := env_var_or_default("MATLAB", "matlab")

# Default target: the thing you actually load in MATLAB.
default: help



# Generate C header from Rust code
header:
    cbindgen crates/ffi --output crates/ffi/include/nominal_ffi.h

# A static library on its own is not a deliverable — nothing loads it until a
# MEX gateway links it in — so every build- recipe here has a matching arm in
# build.m. Add the two together or not at all.
#
# Only the Windows path has been verified end to end. The macOS and Linux
# recipes build, but their system-library lists in build.m are unconfirmed;
# run `just native-libs` on that host and reconcile if the MEX link complains.

# Build the static library the MEX gateway links in
build-win64:
    cargo build --release --target x86_64-pc-windows-msvc -p nominal-ffi

# Same, without LTO (fast edit-build loop)
build-win64-fast:
    cargo build --profile fast --target x86_64-pc-windows-msvc -p nominal-ffi

# macOS, Apple silicon
build-macos-arm64:
    cargo build --release --target aarch64-apple-darwin -p nominal-ffi

# Same, without LTO
build-macos-arm64-fast:
    cargo build --profile fast --target aarch64-apple-darwin -p nominal-ffi

# Linux x86_64
build-linux-x64:
    cargo build --release --target x86_64-unknown-linux-gnu -p nominal-ffi

# build.m picks the target and linker flags from the host it runs on, so the
# mex- recipes differ only in which static library they build first.

# Build the MATLAB MEX gateway
mex-win64: build-win64 header
    "{{matlab}}" -batch "cd matlab; build"

# Same, against the no-LTO library build
mex-win64-fast: build-win64-fast header
    "{{matlab}}" -batch "cd matlab; build(Profile='fast')"

mex-macos-arm64: build-macos-arm64 header
    "{{matlab}}" -batch "cd matlab; build"

mex-macos-arm64-fast: build-macos-arm64-fast header
    "{{matlab}}" -batch "cd matlab; build(Profile='fast')"

mex-linux-x64: build-linux-x64 header
    "{{matlab}}" -batch "cd matlab; build"

# tools/package.m holds the packaging decisions — which paths are exposed,
# which platforms are claimed. Both recipes below run it; they differ only in
# whether they build a gateway first.
#
# `package` depends on the release gateway, so a packaged toolbox is never a
# -fast build — but that also makes it Windows-only. `package-only` builds
# nothing, which is what a multi-platform box needs: build on each host,
# collect the .mex* files into one checkout, then package there. Only the
# platforms with a binary present are claimed. See PACKAGING.md.

# Build a Windows .mltbx into dist/
package: mex-win64
    "{{matlab}}" -batch "run('tools/package.m')"

# Package the gateways already in +nominal/private/, building none
package-only:
    "{{matlab}}" -batch "run('tools/package.m')"

# Exercise the MATLAB layer (no network required). Host-independent.
mex-test:
    "{{matlab}}" -batch "cd matlab; addpath(pwd); addpath(fullfile(pwd,'tests')); nominaltest_smoketest"

# Kept as an alias: the old name is in the README and in muscle memory.
mex-test-win64: mex-test

# Run tests
test:
    cargo test --workspace

# Lint everything: Rust and MATLAB
lint: lint-rust lint-matlab

# Formatter and clippy. Separate from lint-matlab because it is fast enough to
# run constantly, where starting MATLAB is not.
lint-rust:
    cargo fmt --check
    cargo clippy --workspace --all-targets -- -D warnings

# MATLAB's static analyser — the counterpart to clippy for the other half.
# Catches syntax errors, unset outputs, and names shadowing builtins.
lint-matlab:
    "{{matlab}}" -batch "run('tools/lintmatlab.m')"

# Format code
fmt:
    cargo fmt --all


# A Rust staticlib does not record its own dependencies, so build.m has to name
# them. Run this on the host you are building for and reconcile the result
# against platformSettings() in build.m — after a dependency bump, or whenever
# a MEX link reports an unresolved symbol. No --target: it reports for the host.

# Print the system libraries this host's MEX link needs
native-libs:
    cargo rustc --release -p nominal-ffi --crate-type staticlib -- --print native-static-libs

dev-build-win-fast: header build-win64-fast mex-win64-fast
dev-build-win: header build-win64 mex-win64

# Clean build artifacts
clean:
    cargo clean

# Show help
help:
    echo "Available targets:"
    echo "  just mex-win64         - Build the MATLAB gateway (the default)"
    echo "  just mex-win64-fast    - Same, against the no-LTO library build"
    echo "  just mex-macos-arm64   - Gateway on Apple silicon (unverified)"
    echo "  just mex-linux-x64     - Gateway on Linux x86_64 (unverified)"
    echo "  just build-win64       - Just the static library, without the gateway"
    echo "  just package           - Build a Windows .mltbx into dist/"
    echo "  just package-only      - Package existing gateways, build none"
    echo "  just mex-test          - Run the MATLAB smoke test"
    echo "  just native-libs       - Print the system libraries the MEX link needs"
    echo "  just test              - Run tests"
    echo "  just lint              - Lint Rust and MATLAB"
    echo "  just lint-rust         - Just fmt + clippy (fast)"
    echo "  just lint-matlab       - Just MATLAB checkcode"
    echo "  just fmt               - Format code"
    echo "  just clean             - Clean build artifacts"

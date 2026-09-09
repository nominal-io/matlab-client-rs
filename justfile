#!/usr/bin/env just --justfile

# MATLAB is often not on PATH. Two environment variables are read, and an
# explicit `just matlab=...` still overrides both:
#
#   MATLAB_ROOT  the installation directory — what $MATLAB means nearly
#                everywhere else. The executable is derived from it.
#                  export MATLAB_ROOT=/usr/local/MATLAB/R2026a
#   MATLAB_BIN   the executable itself, for an install that does not follow the
#                usual <root>/bin/matlab layout.
#                  export MATLAB_BIN='C:/Program Files/MATLAB/R2026a/bin/matlab.exe'
#
# Recipes run through bash, so use forward slashes in either — backslashes are
# eaten as escapes before the path ever reaches the executable.
#
# $MATLAB itself is deliberately *not* read. This file used to take it as the
# path to the executable, which collides with the near-universal convention
# that $MATLAB is the install root: setting it the conventional way made just
# try to execute a directory, and the resulting error named neither cause.
matlab_root := env_var_or_default("MATLAB_ROOT", "")
matlab_bin := env_var_or_default("MATLAB_BIN", "")

# os() is how a recipe stays one recipe across platforms rather than three.
matlab_exe := if os() == "windows" { "matlab.exe" } else { "matlab" }

matlab := if matlab_bin != "" {
    matlab_bin
} else if matlab_root != "" {
    matlab_root / "bin" / matlab_exe
} else {
    matlab_exe
}

# mex links macOS gateways with -mmacosx-version-min set to this, so cargo has
# to build the static library against the same floor. Left to itself cargo
# targets the host, and the gateway then advertises this version in its
# LC_BUILD_VERSION while containing objects built against a much newer SDK —
# it loads fine on the build machine and is undefined anywhere older. Check
# MACOSX_DEPLOYMENT_TARGET in <MATLAB>/bin/maca64/mexopts/clang_maca64.xml
# after a MATLAB upgrade; MathWorks moves it between releases.
macos_target := "13.3"

# Default target: the thing you actually load in MATLAB.
default: help



# Generate C header from Rust code
header:
    cbindgen crates/ffi --output crates/ffi/include/nominal_ffi.h

# A static library on its own is not a deliverable — nothing loads it until a
# MEX gateway links it in — so every build- recipe here has a matching arm in
# build.m. Add the two together or not at all.
#
# Windows x86-64, macOS arm64 and Linux x86-64 have all been verified end to
# end, so the system-library lists in build.m are observed rather than guessed.
# They are still hand maintained: run `just native-libs` on the host and
# reconcile whenever a MEX link reports an unresolved symbol.

# Build the static library the MEX gateway links in
build-win64:
    cargo build --release --target x86_64-pc-windows-msvc -p nominal-ffi

# Same, without LTO (fast edit-build loop)
build-win64-fast:
    cargo build --profile fast --target x86_64-pc-windows-msvc -p nominal-ffi

# macOS, Apple silicon
build-macos-arm64:
    MACOSX_DEPLOYMENT_TARGET={{macos_target}} cargo build --release --target aarch64-apple-darwin -p nominal-ffi

# Same, without LTO
build-macos-arm64-fast:
    MACOSX_DEPLOYMENT_TARGET={{macos_target}} cargo build --profile fast --target aarch64-apple-darwin -p nominal-ffi

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


# macOS only. MATLAB's mex config gates on a preference that only full Xcode
# ever writes, so on a Command Line Tools-only host it reports
#
#     Xcode is installed, but its license has not been accepted.
#     Run Xcode and accept its license agreement.
#
# when the truth is that Xcode is not installed at all — there is nothing to
# launch, and `xcodebuild -license accept` ships with Xcode too, so that fails
# the same way. Every other probe in MATLAB's config (xcrun, the SDK path and
# version, clang) is already satisfied by CLT alone; this preference is the only
# gate that fails. See XCODE_AGREED_VERSION in
# <MATLAB>/bin/maca64/mexopts/clang_maca64.xml.
#
# The value only has to parse as a version above 4.3 to pass that check. It is
# written to the per-user domain, which MATLAB reads before the system one, so
# no sudo is needed and nothing outside your account changes. Running this
# asserts you have read and agreed to the agreement it prints — read it first.
#
# Note this leaves you on a toolchain MathWorks does not test against, since
# they document full Xcode as the macOS requirement. Nothing in this build
# needs Xcode proper, but a tool that shells out to xcodebuild still will.

# Satisfy MATLAB's Xcode-license check on a Command Line Tools-only macOS host
accept-xcode-license:
    @echo "This records agreement to the Xcode and Apple SDKs Agreement:"
    @echo "    https://www.apple.com/legal/sla/docs/xcode.pdf"
    @echo ""
    defaults write com.apple.dt.Xcode IDEXcodeVersionForAgreedToGMLicense 26.0
    @echo "Recorded. Verify with: just mex-setup"

# Undo accept-xcode-license
revoke-xcode-accept:
    @if defaults read com.apple.dt.Xcode IDEXcodeVersionForAgreedToGMLicense >/dev/null 2>&1; then \
        defaults delete com.apple.dt.Xcode IDEXcodeVersionForAgreedToGMLicense; \
        echo "Removed. mex will report no supported compiler until you accept again."; \
    else \
        echo "Nothing to remove — not set in your user domain."; \
    fi

# Report which compiler mex is configured to use
mex-setup:
    "{{matlab}}" -batch "mex -setup C"


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
    echo "  just mex-win64         - Build the MATLAB gateway"
    echo "  just mex-win64-fast    - Same, against the no-LTO library build"
    echo "  just mex-macos-arm64   - Gateway on Apple silicon"
    echo "  just mex-linux-x64     - Gateway on Linux x86_64"
    echo "  just build-win64       - Just the static library, without the gateway"
    echo "  just package           - Build a Windows .mltbx into dist/"
    echo "  just package-only      - Package existing gateways, build none"
    echo "  just mex-test          - Run the MATLAB smoke test"
    echo "  just native-libs       - Print the system libraries the MEX link needs"
    echo "  just mex-setup         - Report which compiler mex is configured to use"
    echo "  just accept-xcode-license - Clear MATLAB's Xcode-license check on macOS"
    echo "                              (undo with just revoke-xcode-accept)"
    echo "  just test              - Run tests"
    echo "  just lint              - Lint Rust and MATLAB"
    echo "  just lint-rust         - Just fmt + clippy (fast)"
    echo "  just lint-matlab       - Just MATLAB checkcode"
    echo "  just fmt               - Format code"
    echo "  just clean             - Clean build artifacts"

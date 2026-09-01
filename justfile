#!/usr/bin/env just --justfile

# MATLAB is often not on PATH. Override with the full path to matlab.exe.
# Recipes run through bash, so use forward slashes — backslashes are eaten as
# escapes before the path ever reaches the executable:
#   just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
matlab := env_var_or_default("MATLAB", "matlab")

# Default target
default: build-all

# The targets are the platforms MathWorks ships MATLAB for. There is no 32-bit
# Windows or Linux ARM64 build because there is no MATLAB to load one.

# Build the static library for Windows x86_64
build-win64:
    cargo build --release --target x86_64-pc-windows-msvc -p nominal-ffi

# Build for Windows x86_64 without LTO (fast edit-build loop)
build-win64-fast:
    cargo build --profile fast --target x86_64-pc-windows-msvc -p nominal-ffi

# Build for Linux x86_64
build-linux-x64:
    cargo build --release --target x86_64-unknown-linux-gnu -p nominal-ffi

# Build for macOS ARM64
build-macos-arm64:
    cargo build --release --target aarch64-apple-darwin -p nominal-ffi

# Build all targets
build-all: build-win64 build-linux-x64 build-macos-arm64

# Build the MATLAB MEX gateway (Windows only — build.m targets MSVC paths)
mex-win64: build-win64
    "{{matlab}}" -batch "cd matlab; build"

# Same, against the no-LTO library build
mex-win64-fast: build-win64-fast
    "{{matlab}}" -batch "cd matlab; build(Profile='fast')"

# Exercise the MATLAB layer (no network required)
mex-test-win64:
    "{{matlab}}" -batch "cd matlab; addpath(pwd); addpath(fullfile(pwd,'tests')); smoketest"

# Run tests
test:
    cargo test --workspace

# Run clippy linter
lint:
    cargo fmt --check
    cargo clippy --workspace --all-targets -- -D warnings

# Format code
fmt:
    cargo fmt --all

# Generate C header from Rust code
header:
    cbindgen crates/ffi --output crates/ffi/include/nominal_ffi.h

# The system libraries build.m has to name, since a Rust staticlib does not
# record its own dependencies. Re-run after a dependency bump if the MEX link
# reports an unresolved external symbol.
native-libs:
    cargo rustc --release --target x86_64-pc-windows-msvc -p nominal-ffi --crate-type staticlib -- --print native-static-libs

dev-build-win-fast: header build-win64-fast mex-win64-fast
dev-build-win: header build-win64 mex-win64

# Clean build artifacts
clean:
    cargo clean

# Show help
help:
    echo "Available targets:"
    echo "  just build-win64       - Build the static library for Windows x86_64"
    echo "  just build-win64-fast  - Same, no LTO (fast iteration)"
    echo "  just build-linux-x64   - Build for Linux x86_64"
    echo "  just build-macos-arm64 - Build for macOS ARM64"
    echo "  just build-all         - Build all targets (default)"
    echo "  just mex-win64         - Build the MATLAB MEX gateway (Windows only)"
    echo "  just mex-win64-fast    - Same, against the no-LTO library build"
    echo "  just mex-test-win64    - Run the MATLAB smoke test"
    echo "  just native-libs       - Print the system libraries the MEX link needs"
    echo "  just test              - Run tests"
    echo "  just lint              - Run formatter + clippy"
    echo "  just fmt               - Format code"
    echo "  just clean             - Clean build artifacts"

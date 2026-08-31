#!/usr/bin/env just --justfile

# MATLAB is often not on PATH. Override with the full path to matlab.exe.
# Recipes run through bash, so use forward slashes — backslashes are eaten as
# escapes before the path ever reaches the executable:
#   just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
matlab := env_var_or_default("MATLAB", "matlab")

# Default target
default: build-all

# Build for Windows x86_64`
build-win64:
    cargo build --release --target x86_64-pc-windows-msvc -p nominal-ffi
    mkdir -p bin
    cp target/x86_64-pc-windows-msvc/release/nominal_ffi.dll bin/nominalClient_64.dll

# Build for Windows x86_64 without LTO (fast edit-build loop)
build-win64-fast:
    cargo build --profile fast --target x86_64-pc-windows-msvc -p nominal-ffi
    mkdir -p bin
    cp target/x86_64-pc-windows-msvc/fast/nominal_ffi.dll bin/nominalClient_64.dll

# Build for Windows x86 (32-bit)
build-win32:
    cargo build --release --target i686-pc-windows-msvc -p nominal-ffi
    mkdir -p bin
    cp target/i686-pc-windows-msvc/release/nominal_ffi.dll bin/nominalClient_32.dll

# Build for Linux x86_64
build-linux-x64:
    cargo build --release --target x86_64-unknown-linux-gnu -p nominal-ffi
    mkdir -p bin
    cp target/x86_64-unknown-linux-gnu/release/libnominal_ffi.so bin/nominalClient_64.so

# Build for Linux ARM64
build-linux-arm64:
    cargo build --release --target aarch64-unknown-linux-gnu -p nominal-ffi
    mkdir -p bin
    cp target/aarch64-unknown-linux-gnu/release/libnominal_ffi.so bin/nominalClient_arm64.so

# Build for macOS ARM64
build-macos-arm64:
    cargo build --release --target aarch64-apple-darwin -p nominal-ffi || true
    mkdir -p bin
    cp target/aarch64-apple-darwin/release/libnominal_ffi.dylib bin/nominalClient_arm64.dylib || true

# Build all targets
build-all: build-win64 build-win32 build-linux-x64 build-linux-arm64 build-macos-arm64

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


dev-build-win-fast: header build-win64-fast mex-win64-fast
dev-build-win: header build-win64 mex-win64

# Clean build artifacts
clean:
    cargo clean
    rm -rf bin

# Show help
help:
    echo "Available targets:"
    echo "  just build-win64       - Build for Windows x86_64"
    echo "  just build-win64-fast  - Build for Windows x86_64, no LTO (fast iteration)"
    echo "  just build-win32       - Build for Windows x86"
    echo "  just build-linux-x64   - Build for Linux x86_64"
    echo "  just build-linux-arm64 - Build for Linux ARM64"
    echo "  just build-macos-arm64 - Build for macOS ARM64"
    echo "  just build-all         - Build all targets (default)"
    echo "  just mex-win64         - Build the MATLAB MEX gateway (Windows only)"
    echo "  just mex-win64-fast    - Same, against the no-LTO library build"
    echo "  just mex-test-win64    - Run the MATLAB smoke test"
    echo "  just test              - Run tests"
    echo "  just lint              - Run formatter + clippy"
    echo "  just fmt               - Format code"
    echo "  just clean             - Clean build artifacts"

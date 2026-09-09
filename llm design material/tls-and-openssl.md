# TLS, and why OpenSSL must stay out of the graph

**Rule: `reqwest` in `crates/ffi/Cargo.toml` must keep `default-features = false`.**
If a build ever fails in `openssl-sys` looking for `openssl.pc`, the fix is
feature flags, not installing OpenSSL.

## What went wrong (2026-09-09)

`crates/ffi/Cargo.toml` declared:

```toml
reqwest = { version = "0.12", features = ["rustls-tls-native-roots"] }
```

No `default-features = false`. reqwest 0.12's default feature set includes
`default-tls`, which pulls `hyper-tls` → `native-tls` → `openssl` +
`openssl-sys`.

Cargo features **unify across the whole graph**. `nominal` 0.7.1 carefully sets
`default-features = false` on its own reqwest dependency, but that was undone by
this crate leaving defaults on — the union of features is what gets built. So
the entire tree got native-tls back.

Platform-dependent symptom, which is why it survived so long:

- **Windows:** native-tls binds to schannel. Builds fine. Nobody notices.
- **macOS:** native-tls binds to Secure Transport / Security.framework, which
  rustls already needs. Builds fine. Nobody notices.
- **Linux:** native-tls binds to OpenSSL. `openssl-sys` requires a system
  `openssl.pc`, absent on a minimal Fedora image, and the build dies.

Two TLS stacks were being compiled. One was used.

## Why not just install openssl-devel

It would have worked, and it was the user's first instinct. Rejected because:

1. It links a second, unused TLS stack into a 591 MB archive and the shipped
   MEX binary — dead weight plus CVE surface to track in a released client.
2. It makes Linux the only platform needing a system OpenSSL, so prerequisites
   diverge from Windows and macOS for no functional gain.
3. It treats the symptom. The manifest bug would remain, silently costing build
   time on every platform.

## Verification that TLS is still enforced

The concern with removing a TLS feature is silently disabling verification. It
is not disabled — rustls is the only backend and it is doing real work. Checked
directly with a temporary integration test (since deleted):

| Endpoint | Result |
|---|---|
| `https://example.com` | 200 — valid cert accepted, trust store loaded |
| `https://expired.badssl.com` | refused |
| `https://self-signed.badssl.com` | refused |
| `https://wrong.host.badssl.com` | refused |

`rustls` and `rustls-native-certs` (system trust store) both remain in the
graph, reached via `conjure-runtime-rustls-platform-verifier` and
`hyper-rustls`. `rustls-tls-native-roots` is still the requested feature, and
`-native-roots` is what makes it read the OS trust store.

If you ever need to re-verify, the test is four requests: one good cert must
succeed and three bad ones must fail. A passing good-cert request alone proves
nothing.

## Effect on other platforms

Removing native-tls dropped 144 lines from `Cargo.lock`. Confirmed against
`--target aarch64-apple-darwin` that `security-framework` and
`system-configuration` are still present, so the macOS framework list in
`build.m` remains justified — the removal did not invalidate it.

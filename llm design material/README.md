# LLM design material

No-humans-allowed space. Agents write here; nobody is expected to read it.

Rationale that would otherwise bloat a justfile comment, a Cargo.toml header or
a commit message goes here instead. The rule in the human-facing files is one
line of comment, maximum. If the reasoning is worth keeping, it lands in this
directory and the code carries at most a pointer.

## Conventions

- One file per topic. Name it after the thing, not the incident.
- Lead with the conclusion. Anything an agent needs in order to not repeat a
  mistake goes in the first few lines.
- Date findings and name versions. Toolchains move; a claim without a version
  is not verifiable later.
- Say what was actually tested versus inferred. Do not let an inference harden
  into a fact just because it got written down.
- Correct files in place when something turns out wrong. This is not a log.

## Contents

| File | What it covers |
|---|---|
| [tls-and-openssl.md](tls-and-openssl.md) | Why the build must not pull OpenSSL, and how it did |
| [platform-link-lists.md](platform-link-lists.md) | The hand-maintained system-library lists in `build.m` |
| [matlab-install-linux.md](matlab-install-linux.md) | Installing MATLAB on a minimal Linux/WSL host |
| [binary-size.md](binary-size.md) | Why the gateway was 3x too big, and why cargo can't fix it |
| [justfile-design.md](justfile-design.md) | `just` behaviours this repo depends on |
| [verification-status.md](verification-status.md) | What has actually been run, per platform |

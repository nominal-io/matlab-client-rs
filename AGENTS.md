# Nominal for MATLAB

A MATLAB toolbox for Nominal: a Rust core behind a MEX gateway. [BUILDING.md](BUILDING.md) covers the layout, builds, tests and docs.

- Before writing or editing anything in `docs/`, a README, or help text in `matlab/+nominal`, load the `nominal-docs:nominal-docs` skill. It holds the writing rules. This file adds only what is specific to this repo.
- If that skill isn't available, stop and tell your human. To install it in Claude Code, run `claude plugin marketplace add nominal-io/nominal-sphinx-theme`, then `claude plugin install nominal-docs@nominal`. Other agents can read it at https://github.com/nominal-io/nominal-sphinx-theme/blob/main/skills/nominal-docs/SKILL.md.
- The repo is public, including `%` comments.

## Docs

- The help text in `matlab/+nominal` is the source for both MATLAB's `help` and the reference pages. Edit the help text, not `docs/ref/`, which is generated.
- The skill has no MATLAB docstring file. The help-text convention is in [BUILDING.md](BUILDING.md#docs).
- Help-text examples use concrete values, as MathWorks help does. Guides and the cheat sheet use placeholders for lookups of existing data.
- Examples connect with `nominal.Client.fromProfile()`, not `NOMINAL_TOKEN`.
- Links to the Nominal docs hub use the `{hub}` role. Its base address is `HUB` in `docs/conf.py`.
- After editing `matlab/doc/GettingStarted.m`, run `just gettingstarted` to regenerate the `.mlx`.
- Run `just build-docs` before calling docs work done. Warnings fail the build, as in CI.

# Authenticating

{.lead}
Credentials come from a profile on disk, shared with the `nom` CLI and the Python client.

The profile lives in `~/.config/nominal/config.yml` (`%USERPROFILE%\.config\nominal\config.yml`
on Windows), the same file the
[Python client](https://docs.nominal.io/core/sdk/python-client/authentication) uses. Set it up
once, in a terminal:

```shell
nom config profile add default -t <api-token>

# or, if `nom` is not on the path:
python -m nominal.cli config profile add default
```

Then:

```matlab
c = nominal.Client.fromProfile();          % Python: NominalClient.from_profile("default")
c = nominal.Client.fromProfile("staging"); % any named profile
```

A profile carries the base URL, the token, and optionally a workspace RID. If you already use
the Python client or the CLI on this machine, MATLAB is already set up.

## A token directly

Prefer the profile: a token in a script ends up in version control.

```matlab
c = nominal.Client.fromToken("<api-token>");   % Python: NominalClient.from_token(...)
```

## Either, for CI

For code that runs both on a workstation and in CI:

```matlab
c = nominal.Client.connect();              % profile, else NOMINAL_TOKEN
```

The profile wins. `NOMINAL_TOKEN` carries no base URL or workspace, so the fallback means
**Nominal production with no workspace scope**, whatever the profile said. It raises a
`nominal:profileFallback` warning when that happens.

:::{dropdown} Migrating from the old config file
If this machine still has `~/.nominal.yml` with an `environments:` block, `fromProfile`
detects it and tells you to run:

```shell
nom config migrate
```
:::

## Checking it worked

```matlab
c.whoAmI()
```

Calls the API, so a bad token fails here rather than at the first real call.

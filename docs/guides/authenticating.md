# Authenticating

{.lead}
Connect with a profile: your API key, base URL and workspace, stored in the config file that
Nominal's other clients also read.

If Nominal's Python client or CLI already works on this machine, you have a profile already, so
skip to [Connecting](#connecting). Otherwise, set one up.

```{nominal-snippet} api-keys-setup
```

## Connecting

```matlab
c = nominal.Client.fromProfile();            % the profile called "default"
c = nominal.Client.fromProfile("staging");   % any other profile
```

## With an API key in code

A key written into a script ends up in version control, so use a profile where you can.
Without a profile, pass all three values:

```matlab
c = nominal.Client.fromToken("<api-key>", BaseUrl="<base-url>", Workspace="<workspace-rid>");
```

## In CI

`connect` reads the profile when there is one, and otherwise the API key in the
`NOMINAL_TOKEN` environment variable:

```matlab
c = nominal.Client.connect();
```

`NOMINAL_TOKEN` holds only the key, so without a profile the client reaches Nominal production
with no workspace. `connect` raises a `nominal:profileFallback` warning when it falls back.

:::{dropdown} Migrating from the old config file
If this machine still has `~/.nominal.yml` with an `environments:` block, `fromProfile`
detects it and tells you to run:

```shell
nom config migrate
```
:::

## Checking the connection

`whoAmI` makes a request to Nominal, so a bad key fails here instead of at the first real call.

```matlab
c.whoAmI()
```

# Hello world

You have been handed a `NominalForMATLAB-<version>.mltbx` and you already have a
Nominal profile on disk. This is everything from there to running code.

Nothing here needs the source repo, a compiler, or Rust. If you want to *build*
the toolbox rather than install one, see [BUILDING.md](BUILDING.md) instead.

## 1. Install

```matlab
matlab.addons.install("C:\path\to\NominalForMATLAB-0.1.0.mltbx")
```

Double-clicking the file in Explorer or Finder does the same thing.

An installed toolbox manages its own path, so there is no `addpath` to run and
nothing to add to `startup.m`. It survives restarts.

Check it took:

```matlab
matlab.addons.toolbox.installedToolboxes
```

```
       Name: 'Nominal for MATLAB'
    Version: '0.1.0'
       Guid: 'b7e4c2a1-5d3f-4e88-9a12-6f0c3d7b8e45'
```

## 2. Credentials

Nothing to set. The client reads the same profile the `nom` CLI and the Python
client use:

| | |
|---|---|
| Linux, macOS | `~/.config/nominal/config.yml` |
| Windows | `%USERPROFILE%\.config\nominal\config.yml` |

`NOMINAL_TOKEN` exists only as a fallback for machines with no profile — CI,
mostly. If it ever fires it warns, so you will know.

## 3. Hello world

```matlab
client = nominal.Client.connect();
disp(client.whoAmI())
delete(client)
```

If that prints your name, everything works. Skip to section 5.

`connect` tries the profile first. To be explicit about which credential you
are using, call `nominal.Client.fromProfile()` or `nominal.Client.fromToken()` —
neither can silently pick the other.

## 4. Run the bundled examples

The demos ship inside the toolbox but are **not** on the path, so that filenames
like `rundemo` do not become global function names in your session. Add them
deliberately:

```matlab
addpath(fullfile(fileparts(fileparts(which('nominal.Client'))), 'examples'))
```

That resolves the install folder wherever MATLAB put it, which on Windows is
under `%APPDATA%\MathWorks\MATLAB Add-Ons\Toolboxes\`. Then:

```matlab
nominalexample_alldemos          % everything, against one throwaway asset
```

Or one at a time:

| | |
|---|---|
| `nominalexample_assetdemo` | assets: create, fetch, update, list sources |
| `nominalexample_datasetdemo` | datasets and channel metadata/units |
| `nominalexample_rundemo` | runs: create, update, finish |
| `nominalexample_eventdemo` | events on an asset |
| `nominalexample_uploaddemo` | writing a matrix, and ingesting a CSV |
| `nominalexample_streamdemo(rid)` | live streaming — needs a dataset RID |
| `nominalexample_analysisdemo(rid)` | fetch, export, and SQL — needs a RID |

Every demo leaves its results in the base workspace as a struct, so there are
matrices to inspect when it finishes:

```matlab
nominalexample_uploaddemo
nominalexample_analysisdemo(nominalUpload.WrittenDatasetRid)

plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))
```

The demos create their own throwaway assets named
`nominal-matlab-demo-<timestamp>`, so they are safe to run repeatedly. Pass an
asset name to point one at something that already exists:

```matlab
nominalexample_assetdemo("engine-3")
```

## 5. Your own code

The same loop, without the demo scaffolding: connect, find an asset, add a
dataset, push a matrix, read it back.

```matlab
client = nominal.Client.connect();

% --- find an asset, or create one ---------------------------------------
asset = client.getOrCreateAsset("engine-3");

% --- a dataset under it -------------------------------------------------
% The second argument is the reference name, unique among the asset's
% data sources.
dataset = asset.getOrCreateDataset("Bench run 7", "bench7");

% --- declare units before any data exists -------------------------------
% Optional, but it means the first plot comes out labelled. Units are UCUM
% symbols: "Cel" not "C", "1/min" not "rpm".
dataset.setChannelMetadata("rpm", "double", Unit="1/min");

% --- upload a matrix ----------------------------------------------------
% One column per channel, in the same order as the names.
rows = 500;
t = datetime("now", TimeZone="UTC") - seconds(rows/1000) ...
    + milliseconds(0:rows-1)';
v = [1500 + 10*sin(linspace(0, 6*pi, rows))', ...   % rpm
     700  + (1:rows)' * 0.1, ...                    % egt
     30   + (1:rows)' * 0.05];                      % psi

% Eyeball it before it leaves the machine. One panel per channel, because
% the three do not share a scale.
stackedplot(t, v, DisplayLabels=["rpm" "egt" "psi"])

dataset.write(["rpm" "egt" "psi"], t, v);

% --- read it back -------------------------------------------------------
% fetch returns a timetable, so it plots, resamples and synchronizes with
% no conversion.
back = dataset.fetch("rpm", t(1) - seconds(1), t(end) + seconds(1));
plot(back.Time, back.("rpm"))

% --- SQL, if you want rows rather than a channel ------------------------
% points_double holds every point this dataset has ever taken, so bound the
% query to the window just written or you get whatever sorts first — old
% rows from earlier runs. In the warehouse ts is a timestamp column, not the
% int64 nanoseconds it comes back as, so the bounds go in as literals. The
% millisecond of slack covers the format truncating rather than rounding.
lo = string(t(1)   - milliseconds(1), "yyyy-MM-dd HH:mm:ss.SSS");
hi = string(t(end) + milliseconds(1), "yyyy-MM-dd HH:mm:ss.SSS");

rowsOut = client.query( ...
    "SELECT ts, channel, value FROM points_double " + ...
    "WHERE dataset_rid = '" + dataset.Rid + "' " + ...
    "AND ts BETWEEN TIMESTAMP '" + lo + "' AND TIMESTAMP '" + hi + "' " + ...
    "ORDER BY ts LIMIT " + 3*rows);   % three channels, rows apiece

% Timestamps arrive as int64 nanoseconds. Convert them and the table reads
% as it stands.
rowsOut.ts = nominal.fromNanos(rowsOut.ts);
disp(head(rowsOut))

% To plot it, pivot first. These rows are long — one row per channel per
% instant — so value against ts would interleave all three into a sawtooth.
wide = unstack(rowsOut, "value", "channel");
stackedplot(wide.ts, wide{:, 2:end}, ...
            DisplayLabels=wide.Properties.VariableNames(2:end))

% --- done ---------------------------------------------------------------
delete(dataset);
delete(asset);
delete(client);
```

Every object is a handle with a native resource behind it. `delete` releases it
immediately; otherwise MATLAB does so whenever it collects the variable.
`nominal.shutdown()` releases everything and stops the worker threads — worth
calling at the end of a long script, and not needed otherwise.

For the full object and method reference, the other workflows (streaming,
ingest, export, decimated fetch), and how authentication resolves, see
[USAGE.md](USAGE.md).

## Uninstalling

By **name** or GUID, not by the `.mltbx` filename:

```matlab
matlab.addons.uninstall("Nominal for MATLAB")
```

To pick a specific version when several are installed, or to remove all of
them:

```matlab
matlab.addons.uninstall("Nominal for MATLAB", "0.1.0")
matlab.addons.uninstall("Nominal for MATLAB", "All")
```

Installing a newer `.mltbx` with the same identifier upgrades in place, so
uninstalling first is not necessary to update.

## Requirements

- **MATLAB R2021a or newer.** The client uses `Name=Value` call syntax
  throughout, which R2021a introduced.
- **A supported platform.** The `.mltbx` declares the platforms whose native
  gateway is inside it; MATLAB refuses to install elsewhere rather than
  installing and failing on the first call.
- No MathWorks toolboxes beyond base MATLAB.

# Hello world

You have been handed a `NominalForMATLAB-<version>.mltbx` and you have a
Nominal profile on disk. This gets you from there to running code. No source
repo, compiler or Rust needed. To *build* the toolbox instead, see
[BUILDING.md](BUILDING.md).

## 1. Install

```matlab
matlab.addons.install("C:\path\to\NominalForMATLAB-0.1.0.mltbx")
```

Double-clicking the file does the same thing. An installed toolbox manages its
own path, so there is no `addpath` to run. It survives restarts.

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

`NOMINAL_TOKEN` is a fallback for machines with no profile, mostly CI. It warns
when used.

## 3. Hello world

```matlab
client = nominal.Client.connect();
disp(client.whoAmI())
delete(client)
```

If that prints your name, everything works. Skip to section 5.

`connect` tries the profile first, then `NOMINAL_TOKEN`. To be explicit, call
`nominal.Client.fromProfile()` or `nominal.Client.fromToken()`.

## 4. Run the bundled examples

The demos ship inside the toolbox but are **not** on the path. Add them:

```matlab
addpath(fullfile(fileparts(fileparts(which('nominal.Client'))), 'examples'))
```

Then:

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
| `nominalexample_streamdemo(rid)` | live streaming. Needs a dataset RID |
| `nominalexample_analysisdemo(rid)` | fetch, export, and SQL. Needs a RID |

Every demo leaves its results in the base workspace as a struct:

```matlab
nominalexample_uploaddemo
nominalexample_analysisdemo(nominalUpload.WrittenDatasetRid)

plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))
```

The demos create throwaway assets named `nominal-matlab-demo-<timestamp>`, so
they are safe to run repeatedly. Pass an asset name to use an existing one:

```matlab
nominalexample_assetdemo("engine-3")
```

## 5. Your own code

Connect, find an asset, add a dataset, push a matrix, read it back. The same
code as a live script, with plots inline:
[helloworldlive.mlx](hello%20world/helloworldlive.mlx), in the repo.

```matlab
client = nominal.Client.connect();

% --- find an asset, or create one ---------------------------------------
asset = client.getOrCreateAsset("engine-3");

% --- a dataset under it -------------------------------------------------
dataset = asset.getOrCreateDataset("Bench run 7");

% --- declare units before any data exists -------------------------------
% Optional, but the first plot comes out labelled. Units are UCUM symbols:
% "Cel" not "C", "1/min" not "rpm".
dataset.setChannelMetadata("rpm", "double", Unit="1/min");

% --- upload a matrix ----------------------------------------------------
% One column per channel, in the same order as the names.
rows = 500;
t = datetime("now", TimeZone="UTC") - seconds(rows/1000) ...
    + milliseconds(0:rows-1)';
v = [1500 + 10*sin(linspace(0, 6*pi, rows))', ...   % rpm
     700  + (1:rows)' * 0.1, ...                    % egt
     30   + (1:rows)' * 0.05];                      % psi

% Look before it leaves the machine. One panel per channel, since they do
% not share a scale.
stackedplot(t, v, DisplayLabels=["rpm" "egt" "psi"])

dataset.write(["rpm" "egt" "psi"], t, v);

% --- read it back -------------------------------------------------------
% fetch returns a timetable, so it plots, resamples and synchronizes directly.
back = dataset.fetch("rpm", t(1) - seconds(1), t(end) + seconds(1));
plot(back.Time, back.("rpm"))

% --- SQL, if you want rows rather than a channel ------------------------
% points_double holds every point this dataset has ever taken, so bound the
% query to the window just written. ts is a timestamp column in the
% warehouse, so the bounds go in as literals. The millisecond of slack
% covers the format truncating rather than rounding.
lo = string(t(1)   - milliseconds(1), "yyyy-MM-dd HH:mm:ss.SSS");
hi = string(t(end) + milliseconds(1), "yyyy-MM-dd HH:mm:ss.SSS");

rowsOut = client.query( ...
    "SELECT ts, channel, value FROM points_double " + ...
    "WHERE dataset_rid = '" + dataset.Rid + "' " + ...
    "AND ts BETWEEN TIMESTAMP '" + lo + "' AND TIMESTAMP '" + hi + "' " + ...
    "ORDER BY ts LIMIT " + 3*rows);   % three channels, rows apiece

% Timestamps come back as int64 nanoseconds.
rowsOut.ts = nominal.fromNanos(rowsOut.ts);
disp(head(rowsOut))

% The rows are long (one per channel per instant), so pivot before plotting.
wide = unstack(rowsOut, "value", "channel");
stackedplot(wide.ts, wide{:, 2:end}, ...
            DisplayLabels=wide.Properties.VariableNames(2:end))

% --- done ---------------------------------------------------------------
delete(dataset);
delete(asset);
delete(client);
```

Every object is a handle with a native resource behind it. `delete` releases
it immediately; otherwise MATLAB does so when it collects the variable.
`nominal.shutdown()` releases everything and stops the worker threads. Call it
at the end of a long script if you like; it is not needed otherwise.

For the full object and method reference and the other workflows (streaming,
ingest, export, decimated fetch), see [USAGE.md](USAGE.md).

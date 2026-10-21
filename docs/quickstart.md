# Quickstart

{.lead}
From a `.mltbx` file to running code. You need MATLAB R2021a or newer, on Windows x86-64,
Apple silicon or Linux x86-64.

## 1. Install

Download `NominalForMATLAB-<version>.mltbx` from the latest release on the
[releases page](https://github.com/nominal-io/matlab-client-rs/releases), then double-click it to
install. To install from a script instead:

```matlab
matlab.addons.install("<folder>\NominalForMATLAB-<version>.mltbx")
```

The installed toolbox puts itself on the MATLAB path and stays installed across restarts.

To check the install:

```matlab
matlab.addons.toolbox.installedToolboxes
```

```
       Name: 'Nominal for MATLAB'
    Version: '<version>'
       Guid: 'b7e4c2a1-5d3f-4e88-9a12-6f0c3d7b8e45'
```

## 2. Credentials

The toolbox reads its credentials from a profile, the same config file Nominal's other
clients use. If you don't have a profile yet, follow
{hub}`API keys setup <quickstart/quickstart/api-keys-setup/>` to create one.

## 3. Hello world

```matlab
client = nominal.Client.fromProfile();
disp(client.whoAmI())   % prints your name once the toolbox can reach Nominal
delete(client)
```

## 4. Your own code

Connect, find an asset, add a dataset, write a matrix, read it back. The toolbox's Getting
Started guide in the Add-On Manager runs the same loop a section at a time.

```matlab
client = nominal.Client.fromProfile();

% --- find an asset, or create one ---------------------------------------
asset = client.getOrCreateAsset("engine-3");

% --- a dataset under it -------------------------------------------------
dataset = asset.getOrCreateDataset("Bench run 7");

% --- declare units before any data exists -------------------------------
% Optional, but the first plot comes out labelled. Units are UCUM symbols:
% "Cel" not "C", "1/min" not "rpm".
dataset.setChannelMetadata("rpm", "double", Unit="1/min");

% --- write a matrix -----------------------------------------------------
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
% query to the window just written. In SQL, ts is a timestamp, so the
% bounds go in as literals. The millisecond of slack covers the format
% truncating rather than rounding.
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
% Optional. MATLAB also frees these when the variables are cleared.
delete(dataset);
delete(asset);
delete(client);
```

## Next

- [Examples](examples/index.md): the bundled demos, which cover streaming, ingest, export and SQL.
- [Cheat sheet](guides/cheatsheet.md): the objects and their methods on one page.
- [Reference](ref/index.md): the full help text.

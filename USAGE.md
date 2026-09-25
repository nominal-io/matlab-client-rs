# Using the Nominal MATLAB client

Authenticating, the objects, and the common workflows. For building and
installing, see [BUILDING.md](BUILDING.md).

## Quick start

With the gateway built and a profile set up (see
[Authenticating](#authenticating)), this is the whole loop: connect, find an
asset, add a dataset, push a matrix, read it back.

```matlab
addpath('C:\sw\nominal-matlab\matlab')

client = nominal.Client.connect();
fprintf('Connected as %s\n', client.whoAmI());

% --- find an asset ------------------------------------------------------
% Always pass a name filter. With none, this fetches every asset in the
% workspace.
found = client.assets("engine");
asset = client.assetByRid(found.Rid(1));

% --- see what is attached, then add a dataset ---------------------------
disp(asset.datasources())
dataset = asset.getOrCreateDataset("Bench run 7", "bench7");

% --- upload a matrix ----------------------------------------------------
rows = 500;
t = datetime("now", TimeZone="UTC") - seconds(rows/1000) ...
    + milliseconds(0:rows-1)';
v = [1500 + 10*sin(linspace(0, 6*pi, rows))', ...   % rpm
     700  + (1:rows)' * 0.1, ...                    % egt
     30   + (1:rows)' * 0.05];                      % psi

dataset.write(["rpm" "egt" "psi"], t, v);

% --- read it back -------------------------------------------------------
back = dataset.fetch("rpm", t(1) - seconds(1), t(end) + seconds(1));
plot(back.Time, back.("rpm"))

% --- done ---------------------------------------------------------------
delete(dataset);
delete(asset);
delete(client);
```

The demos in [matlab/examples/](matlab/examples/) run all of this for real:
`nominalexample_uploaddemo` writes, `nominalexample_analysisdemo` reads, and
`nominalexample_alldemos` runs everything. Each leaves its results in the base
workspace.

The demo folder is not on the installed toolbox's path. Add it yourself if you
want to run them. The `nominalexample_` prefix keeps the demos from taking
names like `connect` in your session.

## Authenticating

Credentials come from a profile on disk, the same `~/.config/nominal/config.yml`
the `nom` CLI and the
[Python client](https://docs.nominal.io/core/sdk/python-client/authentication)
use. Set it up once, in a terminal:

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

A profile carries the base URL, the token, and optionally a workspace RID. If
you already use the Python client or the CLI on this machine, MATLAB is already
set up.

Or pass a token directly. Prefer the profile: a token in a script ends up in
version control.

```matlab
c = nominal.Client.fromToken("<api-token>");   % Python: NominalClient.from_token(...)
```

For code that runs both on a workstation and in CI:

```matlab
c = nominal.Client.connect();              % profile, else NOMINAL_TOKEN
```

The profile wins. `NOMINAL_TOKEN` carries no base URL or workspace, so the
fallback means **Nominal production with no workspace scope**, whatever the
profile said. It raises a `nominal:profileFallback` warning when that happens.

<details>
<summary>Migrating from the old config file</summary>

If this machine still has `~/.nominal.yml` with an `environments:` block,
`fromProfile` detects it and tells you to run:

```shell
nom config migrate
```

</details>

## Objects and methods

Everything starts from a `nominal.Client`. Objects hand you other objects, so
you rarely construct anything directly.

### Client — `c = nominal.Client.fromProfile()`

| Action | MATLAB |
|---|---|
| Connect from a stored profile | `nominal.Client.fromProfile()` |
| Connect from a token | `nominal.Client.fromToken(token)` |
| Either, whichever is available | `nominal.Client.connect()` |
| Who am I (also a credential check) | `c.whoAmI()` |
| Search assets by name | `c.assets("engine")` |
| Search datasets by name | `c.datasets("telemetry")` |
| List *every* asset (slow, unpaginated) | `c.assets()` |
| List *every* dataset (slow, unpaginated) | `c.datasets()` |
| Get an asset by RID | `c.assetByRid(rid)` |
| Get an asset by name, creating if absent | `c.getOrCreateAsset(name)` |
| Get a dataset by RID | `c.datasetByRid(rid)` |
| Get a run by RID | `c.runByRid(rid)` |
| Create an event | `c.createEvent(assetRids, name)` |
| Upload and ingest a CSV or Parquet file | `c.ingest(path, TimestampColumn=…)` |
| Run a SQL query | `c.query(sql)` |
| SQL result too big for memory | `c.queryExportUrl(sql)` |
| Workspace / base URL | `c.WorkspaceRid`, `c.BaseUrl` |

### Asset — `a = c.getOrCreateAsset("engine-3")`

| Action | MATLAB |
|---|---|
| Identity and metadata | `a.Rid`, `a.Name`, `a.Description`, `a.Url`, `a.Labels` |
| Read one property | `a.property("phase")` |
| Everything attached to it | `a.datasources()` |
| …re-read from the server | `a.datasources(Refresh=true)` |
| A dataset already on it, by name | `a.getAttachedDataset(name)` |
| Attach a dataset you already have | `a.addDataset(ds)`, `a.addDataset(ds, "can")` |
| Ensure it has a dataset of that name | `a.getOrCreateDataset(name)` |
| …without adopting an existing one | `a.getOrCreateDataset(name, AttachExisting=false)` |
| Start a run on it | `a.run(name)`, `a.run(name, startTime)` |
| Change metadata | `a.update(Name=…, Description=…, Labels=…, Properties=…)` |

An asset handle is a **snapshot** taken when it was fetched. `update()` returns
a new object instead of changing the one you have, and `datasources()` does not
show a dataset attached since the fetch until you pass `Refresh=true`.

Dataset names are not unique in Nominal, so `getOrCreateDataset` resolves in
three steps and prints which one it took:

1. A dataset of that name already on the asset is returned.
2. Otherwise a dataset of that exact name elsewhere in the workspace is
   **attached** to the asset and returned.
3. Otherwise one is created.

Step 2 is how "the dataset for serial 12345678" finds the one a colleague
already made. Because it changes your asset based on a name match, you can turn
it off with `AttachExisting=false`. If several datasets share the name, it
errors and lists their RIDs. Attach the one you meant with
`a.addDataset(c.datasetByRid(rid))`.

`refName` is the dataset's name within the asset. It is only used when
attaching, and you can leave it out: a free one is chosen (`"default"` on an
asset with none, otherwise the dataset's own name). Supply one when an asset
has two sources measuring the same thing, such as a CAN log and a test rig both
reporting `engine temp`, and you want to tell them apart.

### Dataset — `ds = a.getOrCreateDataset("telemetry", "tlm")`

| Action | MATLAB |
|---|---|
| Identity and metadata | `ds.Rid`, `ds.Name`, `ds.Description`, `ds.Labels` |
| Read one property | `ds.property("script")` |
| What channels are in it | `ds.channels()` |
| Open a live stream | `ds.stream()` |
| Write a block already in memory | `ds.write(channels, t, V)` |
| Read one channel back | `ds.fetch("rpm", t0, t1)` |
| Read it decimated, for plotting | `ds.fetch("rpm", t0, t1, Buckets=2000)` |
| Export channels to a file | `ds.export("out.mat", channels, t0, t1)` |
| Export to a download link instead | `ds.exportUrl(channels, t0, t1)` |
| Read one channel's units | `ds.channelMetadata("rpm")` |
| Declare a channel's units | `ds.setChannelMetadata("rpm", "double", Unit="1/min")` |
| Change metadata | `ds.update(Name=…, Labels=…, Properties=…)` |

### Run — `r = a.run("burn-12")`

| Action | MATLAB |
|---|---|
| Identity and metadata | `r.Rid`, `r.Name`, `r.Description`, `r.Url`, `r.Number`, `r.Labels` |
| Timing | `r.StartTime`, `r.EndTime` |
| Read one property | `r.property("operator")` |
| Attach a dataset (*see Known gaps*) | `r.addDataset(refName, ds)` |
| Close it | `r.finish()`, `r.finish(endTime)` |
| Change metadata | `r.update(Name=…, Labels=…, Properties=…)` |

### Stream and Channel — `s = ds.stream()`

| Action | MATLAB |
|---|---|
| Get a write address for a channel | `s.channel("rpm")` |
| Push an N-by-C block across channels | `s.push(channels, t, V)` |
| Push one channel | `ch.push(t, v)` |
| Tag every later point on an address | `ch.tag("bank", "1")` |
| Flush and close | `delete(s)` |

### Event — `e = c.createEvent(rids, "overspeed")`

| Action | MATLAB |
|---|---|
| Read it back | `e.Rid`, `e.Name`, `e.Type`, `e.Timestamp`, `e.Duration`, `e.AssetRids` |

### IngestJob — `job = c.ingest("flight.csv", …)`

| Action | MATLAB |
|---|---|
| Where the data is landing | `job.DatasetRid` |
| Check progress | `job.status()` |
| Block until it finishes | `job.wait()` |

### Free functions

| Action | MATLAB |
|---|---|
| Current time, full nanosecond precision | `nominal.now()` |
| datetime → int64 nanoseconds | `nominal.toNanos(dt)`, `nominal.toNanosVector(dt)` |
| int64 nanoseconds → UTC datetime | `nominal.fromNanos(nanos)` |
| Release everything, stop worker threads | `nominal.shutdown()` |

## Common workflows

### Getting data in

**I have a `.mat` file I want in Nominal.** Load it and push the matrix. No
intermediate file, no ingest job.

```matlab
load("flight12.mat");                      % gives t (datetime) and V (N-by-3)
c  = nominal.Client.fromProfile();
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12", "flight12");
ds.write(["rpm" "egt" "psi"], t, V);
```

**I have a CSV or Parquet file on disk.** Hand Nominal the path and let it
parse.

```matlab
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12", "flight12");

job = c.ingest("flight12.csv", TimestampColumn="time", Dataset=ds);
job.wait();                                % raises if the ingest fails
```

Create the dataset under the asset first and pass `Dataset=`. `NewDataset=`
also works but creates a dataset attached to no asset; attach it afterwards
with `a.addDataset(c.datasetByRid(job.DatasetRid))`. `job.wait()` **raises**
when the ingest fails, so wrap it in `try` if you want to report the failure
instead.

Timestamps default to ISO 8601. For a numeric column:
`c.ingest(path, TimestampColumn="t", Kind="epoch", Unit="milliseconds", …)`.

**I want to stream live from a test loop.** Open a stream once, push blocks as
they fill.

```matlab
s     = ds.stream();
chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];
while acquiring
    [t, block] = readFromDAQ();            % t is N-by-1, block is N-by-3
    s.push(chans, t, block);
end
delete(s);                                 % flushes; blocks until it lands
```

**I want to know which script produced this data.** Properties and labels are
free text, so record the provenance on the dataset.

```matlab
ds.update(Properties=struct(script="reduce_flight.m", ...
                            version="2.4.1", ...
                            matlab=string(version("-release")), ...
                            operator=c.whoAmI()), ...
          Labels=["flight-test" "reduced"]);
```

**I want the channels to carry units.** This is an upsert and works before any
data exists, so declare units ahead of a stream and the first plot comes out
labelled.

```matlab
ds.setChannelMetadata("rpm", "double", Unit="1/min");
ds.setChannelMetadata("egt", "double", Unit="Cel", Description="Exhaust gas temp");
```

Units are UCUM symbols, not free text: `Cel` not `C` (which is coulomb), `1/min`
not `rpm`, `[psi]` in brackets. A symbol UCUM cannot parse is accepted but
stored display-only, with no conversions.

**I want this test bracketed as a run.** A run is a time window over an asset.

```matlab
r = a.run("burn-12", datetime("now", TimeZone="UTC"));
% ... test happens ...
r = r.finish();
```

Nothing attaches the data. A run's data sources **are** its asset's, live, so a
dataset added to the asset after the run was created is already on the run.
`r.addDataset(...)` exists but cannot succeed for a run made this way; see
[Known gaps](README.md#known-gaps).

**I want to flag something that happened.** Events mark a moment or an
interval on an asset.

```matlab
c.createEvent(a.Rid, "overspeed", Type="error", ...
              Timestamp=datetime("now", TimeZone="UTC"), Duration=seconds(3));
```

### Getting data out

**I do not know the RID of anything.** Search by name. Both return tables.

```matlab
c.assets("engine")                         % name contains "engine"
ds = c.datasetByRid(c.datasets("telemetry").Rid(1));
ds.channels()                              % what is inside it
```

Always pass a filter. With no argument, `c.assets()` and `c.datasets()` fetch
every asset or dataset in the workspace in one call, and there is no page size
to pass.

**I want a channel in my workspace to work on.** `fetch` returns a timetable,
so it plots and resamples directly.

```matlab
t1 = datetime("now", TimeZone="UTC");
t0 = t1 - hours(2);

tt = ds.fetch("rpm", t0, t1);
plot(tt.Time, tt.("rpm"))

hourly = retime(tt, "regular", "mean", TimeStep=minutes(1));
```

For plotting a wide window, let the server decimate:

```matlab
tt = ds.fetch("rpm", t0, t1, Buckets=2000);
```

Decimated points are bucket **means**, so the extremes are gone. Use the
undecimated fetch if you need them.

Several channels line up with `synchronize`:

```matlab
rpm = ds.fetch("rpm", t0, t1);
egt = ds.fetch("egt", t0, t1);
both = synchronize(rpm, egt);
```

**I want everything under this run in a `.mat` file.** Export moves the whole
window in one request. A run's data sources are its asset's, so get the dataset
from the asset.

```matlab
r  = c.runByRid(runRid);
a  = c.assetByRid(assetRid);
ds = c.datasetByRid(a.datasources().Rid(1));

ds.export("burn12.mat", ds.channels().Name', r.StartTime, r.EndTime);
```

CSV and Arrow are the other formats: `Format="csv"`. `ds.exportUrl(...)`
returns a time-limited download URL instead of a file, for handing to a browser
or something that is not MATLAB.

**I have a SQL query.** Results come back as a table.

```matlab
t = c.query("SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + ds.Rid + "' ORDER BY ts LIMIT 1000");
t.ts = nominal.fromNanos(t.ts);          % timestamps arrive as int64 ns
```

The SQL tables are the warehouse's own, so the column names differ from the
MATLAB classes.

**Telemetry tables** (`points_double`, `points_int`, `points_string`,
`points_struct`, `logs`, `channels`) *must* filter on `dataset_rid` or the
query is rejected. `points_double` has `ts`, `channel`, `value` and
`dataset_rid`.

**Metadata tables** (`assets`, `runs`, `run_assets`, `datasets`, `events`) have
no such requirement, so `datasets` is another way to find a RID. They are
capped at 10,000 rows.

Results over 1 GiB need `c.queryExportUrl(sql)`, which returns a CSV download
link with no size cap.

## Streaming: prefer the matrix push

`nominal.Stream.push` takes an N-by-C matrix, one column per channel, with one
shared timestamp column. MATLAB stores matrices column-major, so the data goes
to the library with no copy. Preallocate a matrix, fill it in a loop, push it.

`push` blocks when the stream saturates. If points arrive faster than the
network drains them, it waits instead of queueing without bound. Produce on a
separate thread if your acquisition loop cannot stall.

## Shutdown

You do not need to call `nominal.shutdown()`. `clear mex`, `clear all` and
quitting MATLAB all shut the library down cleanly first.

Call it when you want the teardown at a known point, such as the end of a long
script. It invalidates every outstanding handle. The next call builds a fresh
runtime, so the library is usable again immediately.

# Using the Nominal MATLAB client

Authenticating, what the objects are, and the workflows they add up to. For
building the gateway and installing it, see [BUILDING.md](BUILDING.md).

## Quick start

Assuming the gateway is built and a profile is set up — see
[BUILDING.md](BUILDING.md) and [Authenticating](#authenticating) — this is the
whole loop: connect, find an asset, add a dataset under it, push a matrix, read
it back, shut down.

```matlab
addpath('C:\sw\nominal-matlab\matlab')

client = nominal.Client.connect();
fprintf('Connected as %s\n', client.whoAmI());

% --- find an asset ------------------------------------------------------
% Search by name. With no filter this fetches every asset in the workspace,
% which on a real deployment is tens of thousands of rows.
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
% fetch returns a timetable, so it plots and resamples with no conversion.
back = dataset.fetch("rpm", t(1) - seconds(1), t(end) + seconds(1));
plot(back.Time, back.("rpm"))

% --- done ---------------------------------------------------------------
delete(dataset);
delete(asset);
delete(client);
```

`connect` tries the stored profile first and falls back to `NOMINAL_TOKEN`,
which is what makes the same script run on a workstation and in CI. Reach for
`fromProfile` or `fromToken` when you know which you have — see
[Authenticating](#authenticating) for why the fallback warns.

The demos in [matlab/examples/](matlab/examples/) run all of this for real:
`nominalexample_uploaddemo` for the write half,
`nominalexample_analysisdemo` for the read half, and
`nominalexample_alldemos` for everything. Each leaves its results in the base
workspace, so there is something to inspect afterwards.

The `nominalexample_` prefix is deliberate. That folder is not on the installed
toolbox's path, so adding it is a decision you make — and when you do, every
filename in it becomes a global function name. Prefixing keeps the demos from
claiming names like `rundemo` or `connect` in your session.

## Authenticating

Credentials come from a profile on disk — the same
`~/.config/nominal/config.yml` the `nom` CLI and the
[Python client](https://docs.nominal.io/core/sdk/python-client/authentication)
use. Set it up once, in a terminal:

```shell
nom config profile add default -t <api-token>

# or, if `nom` is not on the path:
python -m nominal.cli config profile add default
```

Then the MATLAB call is the counterpart of the Python one:

```matlab
c = nominal.Client.fromProfile();          % Python: NominalClient.from_profile("default")
c = nominal.Client.fromProfile("staging"); % any named profile
```

A profile carries the base URL, the token, and optionally a workspace RID, so
nothing else needs passing — and a self-hosted stack or a staging environment
is a profile name rather than a code change. If you already use the Python
client or the CLI on this machine, MATLAB is already set up.

Failing that, a token directly:

```matlab
c = nominal.Client.fromToken("<api-token>");   % Python: NominalClient.from_token(...)
```

Prefer the profile. A token in a script is a token in version control
eventually.

Or let it pick, for code that has to run in both places:

```matlab
c = nominal.Client.connect();              % profile, else NOMINAL_TOKEN
```

The profile wins. It carries a base URL and a workspace; `NOMINAL_TOKEN`
carries neither, so falling back to it means **Nominal production with no
workspace scope**, whatever the profile said. A staging profile that fails to
load would otherwise send you somewhere else without a word, so the fallback
raises a `nominal:profileFallback` warning when it happens.

<details>
<summary>Migrating from the old config file</summary>

If this machine predates profiles it may still have `~/.nominal.yml` with an
`environments:` block. `fromProfile` detects that and tells you to run:

```shell
nom config migrate
```

</details>

## Objects and methods

Everything is reached from a `nominal.Client`. Objects hand you other objects,
so you rarely construct anything directly.

### Client — `c = nominal.Client.fromProfile()`

| Action | MATLAB |
|---|---|
| Connect from a stored profile | `nominal.Client.fromProfile()` |
| Connect from a token | `nominal.Client.fromToken(token)` |
| Either, whichever is available | `nominal.Client.connect()` |
| Who am I (also a credential check) | `c.whoAmI()` |
| Search assets by name | `c.assets("engine")` |
| Search datasets by name | `c.datasets("telemetry")` |
| List *every* asset — slow, unpaginated | `c.assets()` |
| List *every* dataset — slow, unpaginated | `c.datasets()` |
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
| Ensure it has a dataset of that name | `a.getOrCreateDataset(name, refName)` |
| …without adopting an existing one | `a.getOrCreateDataset(name, refName, AttachExisting=false)` |
| Start a run on it | `a.run(name)`, `a.run(name, startTime)` |
| Change metadata | `a.update(Name=…, Description=…, Labels=…, Properties=…)` |

An asset handle is a **snapshot**, taken when it was fetched — which is why
`update()` returns a new object rather than changing the one you have. That
applies to `datasources()` too, so a dataset attached since the fetch is not
listed until you pass `Refresh=true`, which costs one request and leaves the
handle itself untouched.

A bare name is not unique in Nominal, so `getOrCreateDataset` resolves in three
steps and prints which one it took: a dataset of that name already on the asset
is returned untouched; otherwise one of that exact name elsewhere in the
workspace is **attached** to the asset; otherwise one is created. That middle
step is what makes "the dataset for serial 12345678" find the one a colleague
already made — and because it changes your asset on the strength of a name
match, it announces itself and can be switched off with `AttachExisting=false`.

If several datasets share the name, it errors and lists their RIDs rather than
picking one. `refName` is used only when attaching, never to decide which
dataset you meant.

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
| Attach a dataset — *see Known gaps* | `r.addDataset(refName, ds)` |
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

**I have a `.mat` file I want in Nominal.** Load it and push the matrix — no
intermediate file, no ingest job.

```matlab
load("flight12.mat");                      % gives t (datetime) and V (N-by-3)
c  = nominal.Client.fromProfile();
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12", "flight12");
ds.write(["rpm" "egt" "psi"], t, V);
```

**I have a CSV or Parquet file on disk.** Hand Nominal the path and let it do
the parsing.

```matlab
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12", "flight12");

job = c.ingest("flight12.csv", TimestampColumn="time", Dataset=ds);
job.wait();                                % raises if the ingest fails
```

Create the dataset under the asset first and pass `Dataset=`. `NewDataset=`
also works, but the dataset it creates is attached to no asset — and this
client cannot attach one afterwards, because the C ABI exposes no
add-datasource call. `job.wait()` **raises** when the ingest itself fails, so
wrap it if a failure is an outcome you want to report rather than throw.

Timestamps default to ISO 8601. For a numeric column say so:
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
arbitrary text, so record the provenance alongside the channels.

```matlab
ds.update(Properties=struct(script="reduce_flight.m", ...
                            version="2.4.1", ...
                            matlab=string(version("-release")), ...
                            operator=c.whoAmI()), ...
          Labels=["flight-test" "reduced"]);
```

`c.whoAmI()` is the authenticated Nominal user, which is more useful here than
the OS login — it identifies who the data belongs to in the system you are
reading it back from.

**I want the channels to carry units.** This is an upsert, so it works before
any data exists — declare units ahead of a stream and the plots come out right
the first time.

```matlab
ds.setChannelMetadata("rpm", "double", Unit="1/min");
ds.setChannelMetadata("egt", "double", Unit="Cel", Description="Exhaust gas temp");
```

Units are UCUM symbols, not free text: `Cel` rather than `C` (UCUM reserves
that for coulomb), `1/min` rather than `rpm`, `[psi]` in brackets because UCUM
brackets the customary units it names. A symbol UCUM cannot parse is still
accepted, but is stored display-only and supports no conversions.

**I want this test bracketed as a run.** A run is a time window over an asset,
with datasets attached.

```matlab
r = a.run("burn-12", datetime("now", TimeZone="UTC"));
% ... test happens ...
r = r.finish();
```

Nothing attaches the data: a run's data sources **are** its asset's, live. A
dataset added to the asset after the run was created is already on the run.
`r.addDataset(...)` exists but cannot succeed for a run made this way — see
[Known gaps](README.md#known-gaps).

**I want to flag something that happened.** Events mark a moment or an interval.

```matlab
c.createEvent(a.Rid, "overspeed", Type="error", ...
              Timestamp=datetime("now", TimeZone="UTC"), Duration=seconds(3));
```

### Getting data out

**I do not know the RID of anything.** Search by name; both come back as
tables.

```matlab
c.assets("engine")                         % name contains "engine"
ds = c.datasetByRid(c.datasets("telemetry").Rid(1));
ds.channels()                              % what is inside it
```

Pass a filter. `c.assets()` and `c.datasets()` with no argument fetch every
asset or dataset in the workspace in a single unpaginated call — tens of
thousands of rows on a real deployment, and there is no limit or page size to
pass.

**I want a channel in my workspace to work on.** `fetch` gives a timetable, so
it plots and resamples with no conversion.

```matlab
t1 = datetime("now", TimeZone="UTC");
t0 = t1 - hours(2);

tt = ds.fetch("rpm", t0, t1);
plot(tt.Time, tt.("rpm"))

hourly = retime(tt, "regular", "mean", TimeStep=minutes(1));
```

For plotting a wide window, ask the server to decimate rather than moving
every sample:

```matlab
tt = ds.fetch("rpm", t0, t1, Buckets=2000);
```

Decimated points are bucket **means** — bucketing has already discarded the
extremes, so reach for the undecimated fetch if you need them.

Several channels line up with `synchronize`:

```matlab
rpm = ds.fetch("rpm", t0, t1);
egt = ds.fetch("egt", t0, t1);
both = synchronize(rpm, egt);
```

**I want everything under this run in a `.mat` file.** Export moves the whole
window in one request rather than paging.

```matlab
r  = c.runByRid(runRid);
ds = c.datasetByRid(r.datasources().Rid(1));

ds.export("burn12.mat", ds.channels().Name', r.StartTime, r.EndTime);
```

CSV and Arrow are the other two formats: `Format="csv"`. If the file is more
useful as a link than as bytes — handing it to a browser, or to something that
is not MATLAB — `ds.exportUrl(...)` returns a time-limited download URL
instead.

**I have a SQL query.** Results come back as a table.

```matlab
t = c.query("SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + ds.Rid + "' ORDER BY ts LIMIT 1000");
t.ts = nominal.fromNanos(t.ts);          % timestamps arrive as int64 ns
```

The SQL surface is the warehouse's own tables, not the object model, so the
column names are not the ones the MATLAB classes use.

**Telemetry tables** — `points_double`, `points_int`, `points_string`,
`points_struct`, `logs`, `channels` — *must* filter on `dataset_rid`, or the
query is rejected before it runs. `points_double` carries `ts`, `channel`,
`value` and `dataset_rid`.

**Metadata tables** — `assets`, `runs`, `run_assets`, `datasets`, `events` —
have no such requirement, which makes `datasets` a way to find a RID when you
have none. They are capped at 10,000 rows.

Anything over 1 GiB needs `c.queryExportUrl(sql)`, which returns a CSV download
link with no size cap.

## Streaming: prefer the matrix push

`nominal.Stream.push` takes an N-by-C matrix, one column per channel, sharing a
timestamp column. MATLAB stores matrices column-major, so each channel's samples
are already contiguous and go to the library with no copy or transpose.

That means MATLAB's natural pattern — preallocate a matrix, fill it in a loop,
push it — is already the efficient one.

Pushing blocks when the stream saturates. If points arrive faster than the
network drains them, `push` waits rather than queueing without bound. Produce on
a separate thread if your acquisition loop cannot stall.

## Shutdown

`clear mex`, `clear all`, and quitting MATLAB all unload the gateway. The
library owns worker threads that would outlive an unloaded module and take
MATLAB down with them, so the gateway registers a `mexAtExit` hook that shuts it
down first.

You therefore do not need to call `nominal.shutdown()`. Do so when you want the
teardown at a known point — before a `clear mex` during development, or at the
end of a long script. It invalidates every outstanding handle but is not a
one-way door: the next call builds a fresh runtime.

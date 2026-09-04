# Nominal for MATLAB

An object-oriented MATLAB client for [Nominal](https://nominal.io).

The Nominal Rust SDK is wrapped in a C ABI (`crates/ffi`) and linked into a
single MEX gateway, so MATLAB talks to native code rather than shelling out to
Python. One binary, no runtime dependencies, no interpreter in the middle.

```matlab
addpath('matlab')

c  = nominal.Client.fromProfile();
a  = c.getOrCreateAsset("engine-3");
ds = a.getOrCreateDataset("telemetry", "tlm");
s  = ds.stream();

chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];

t = nominal.now() + int64(0:999)' * 1000000;   % 1 ms apart
v = randn(1000, 3);                            % one column per channel
s.push(chans, t, v);

delete(s);   % flush now, rather than whenever s is collected
```

## Building and installing

From the repository root:

```
just                       # build the gateway
just mex-test              # offline smoke test
```

Then put `matlab/` on the MATLAB path:

```matlab
addpath('C:\sw\nominal-matlab\matlab')
```

Add the **parent** folder, not `matlab\+nominal` — MATLAB finds a package from
its parent. The result is a single binary, `+nominal/private/nominalmex.mexw64`,
with the Rust code linked inside it: no DLL to locate, nothing to register.

See **[BUILDING.md](BUILDING.md)** for prerequisites, the other platforms,
making the path permanent via `startup.m`, and packaging an installable
`.mltbx` toolbox for colleagues.

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
| Get a dataset under it, creating if absent | `a.getOrCreateDataset(name, refName)` |
| Start a run on it | `a.run(name)`, `a.run(name, startTime)` |
| Change metadata | `a.update(Name=…, Description=…, Labels=…, Properties=…)` |

### Dataset — `ds = a.getOrCreateDataset("telemetry", "tlm")`

| Action | MATLAB |
|---|---|
| Identity | `ds.Rid`, `ds.Name` |
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
| Attach a dataset | `r.addDataset(refName, ds)` |
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

**I want this test bracketed as a run.** A run is a time window over an asset,
with datasets attached.

```matlab
r = a.run("burn-12", datetime("now", TimeZone="UTC"));
r.addDataset("tlm", ds);
% ... test happens ...
r = r.finish();
```

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

## What it gives you over the raw C API

**Handles free themselves.** Every class derives from a `handle` base with a
destructor, so `delete()` runs when a variable goes out of scope. There are no
`_free` calls to forget. Objects alias rather than copy, so passing one to a
function does not create a second owner of the same handle.

**Errors are exceptions.** Status codes become `MException`s carrying the
library's own message, with identifiers you can catch selectively:

```matlab
try
    a = c.getOrCreateAsset("engine-3");
catch e
    switch e.identifier
        case 'nominal:apiError',      % the server rejected it
        case 'nominal:invalidHandle', % used after release or shutdown
    end
end
```

**Wrong-type arguments fail immediately.** `arguments` blocks declare the
expected class, so passing a `Dataset` where a `Stream` belongs is an error at
the call site naming both — rather than an integer quietly going somewhere it
should not.

**Strings and string handles are invisible.** Getters return MATLAB `string`;
the allocate/length/copy/free dance stays in the gateway.

**Times are `datetime`.** Anything taking an instant accepts a zoned `datetime`
or an `int64` nanosecond count, and times coming back are UTC `datetime`. Note
`datetime` does not resolve to nanoseconds, so use `nominal.now()` and raw
`int64` when full precision matters — a round trip through `datetime` is lossy.

Plain doubles are refused for timestamps. A double holds integers exactly only
to 2^53, which in nanoseconds runs out about 104 days after 1970, so any real
timestamp passed as a double would be silently rounded. `0` is accepted, since
it is the "now" sentinel for run times.

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

## Layout

```
crates/ffi/                     Rust: the Nominal SDK behind a C ABI
├── src/                        one module per resource kind
└── include/nominal_ffi.h       generated by cbindgen — `just header`

matlab/
├── build.m                     compile the gateway
├── examples/                   runnable demos, one per area
├── tests/smoketest.m           offline checks, no network needed
├── src/nominalmex.c            single MEX gateway; all commands dispatch here
└── +nominal/
    ├── Resource.m              handle ownership, destructors, display
    ├── Client.m  Asset.m  Dataset.m  Run.m
    ├── Stream.m  Channel.m  Event.m  ChannelMetadata.m  IngestJob.m
    ├── now.m  toNanos.m  toNanosVector.m  fromNanos.m
    ├── shutdown.m
    └── private/
        ├── nominalmex.mexw64   gateway + Rust library, in one binary
        └── structsToTable.m    listing -> table, shared by the classes
```

One gateway rather than one MEX per function: `mexAtExit` must be registered
exactly once, and a binary per command would mean dozens of files each carrying
a copy of the shutdown plumbing.

`nominalmex` lives in `private/` deliberately. It does no argument checking of
its own and calling it directly bypasses every guarantee the classes make.

## Requirements

**MATLAB R2021a or newer.** The floor is the `Name=Value` call syntax used
throughout — `c.assets()` and friends are fine much further back, but
`ds.fetch("rpm", t0, t1, Buckets=2000)` is not. The older `'Buckets', 2000`
form works everywhere and is a drop-in substitute if you need it.

This has not been tested below R2026a. The `arguments` blocks the classes use
are R2019b, but [toNanos.m](matlab/+nominal/toNanos.m) and
[fromNanos.m](matlab/+nominal/fromNanos.m) rely on `convertTo(..., 'epochtime', ...)`,
which is newer — going below R2021a needs that checked against a real install
rather than assumed.

**Windows x86-64 is the only platform verified end to end.** `build.m` picks
its cargo target and linker flags from the host, and there are `just` recipes
for Apple silicon, Intel macOS and Linux x86-64 — but only the Windows link has
actually been run. The system-library lists for the others are the usual set
for this dependency tree, not a tested configuration. On a new host:

```
just native-libs        # authoritative list for that platform
just mex-macos-arm64    # or mex-linux-x64, mex-macos-x64
```

and reconcile `platformSettings()` in [build.m](matlab/build.m) if the link
reports an unresolved symbol.

## Known gaps

- **String channels.** `nominal_streamchannel_push_strings` exists in the C ABI
  but has no MEX command, so streams carry doubles only.
- **Events cannot be listed or searched**, only created and read back from the
  object you get at creation. The C ABI has no list endpoint to expose.
- **Video and connection data sources** appear in `a.datasources()` with the
  right `Type`, but there is nothing to do with one from here.
- **Listings cannot be limited or paged.** `nominal_asset_list` and
  `nominal_dataset_list` take a client and nothing else, so `c.assets()` and
  `c.datasets()` are all-or-nothing — on a large workspace that is tens of
  thousands of rows and several seconds. Search by name instead. Adding a
  limit means a parameter on the C ABI, not just a MATLAB change.
- **`mxCreateString` and non-ASCII text.** Strings going *in* are converted
  explicitly with `mxArrayToUTF8String`; strings coming *back* go through
  `mxCreateString`, which may interpret bytes in the platform codepage rather
  than as UTF-8. Untested — an asset named with non-ASCII characters is the
  check.

## Status

Built on R2026a with MSVC. `just mex-test` runs the offline smoke test:
class loading, private-folder MEX resolution, `arguments` validation,
whitespace trimming, empty-means-absent, exception identifiers, and destructor
release.

The HTTP path is exercised — authentication, listings, and strings coming back
out all work against a live deployment. Streaming has been run from MATLAB and
lands data. **Fetch, export, ingest, and SQL are newly wired and have not been
run against a live deployment yet.**

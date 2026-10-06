# Cheat sheet

{.lead}
Every object and method on one page. Everything starts from a `nominal.Client`; objects
hand you other objects, so you rarely construct anything directly.

## Client

`c = nominal.Client.fromProfile()`

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
| Create an asset, even if the name exists | `c.createAsset(name)` |
| Get a dataset by RID | `c.datasetByRid(rid)` |
| Create a dataset attached to no asset | `c.createDataset(name)` |
| Get a run by RID | `c.runByRid(rid)` |
| Create an event | `c.createEvent(assetRids, name)` |
| …with properties | `c.createEvent(rids, name, Properties=struct(status="pass"))` |
| Upload and ingest a CSV or Parquet file | `c.ingest(path, TimestampColumn=…)` |
| …tagging every point in it | `c.ingest(path, …, Tags=struct(UUT="A"))` |
| Run a SQL query | `c.query(sql)` |
| SQL result too big for memory | `c.queryExportUrl(sql)` |
| Workspace / base URL | `c.WorkspaceRid`, `c.BaseUrl` |

## Asset

`a = c.getOrCreateAsset("engine-3")`

| Action | MATLAB |
|---|---|
| Identity and metadata | `a.Rid`, `a.Name`, `a.Description`, `a.Url`, `a.Labels` |
| Read one property | `a.property("phase")` |
| Everything attached to it | `a.datasources()` |
| …re-read from the server | `a.datasources(Refresh=true)` |
| A dataset already on it, by name | `a.getAttachedDataset(name)` |
| Attach a dataset you already have | `a.addDataset(ds)`, `a.addDataset(ds, "can")` |
| …only the series with these tags | `a.addDataset(ds, Tags=struct(UUT="A"))` |
| …a tag key that isn't a field name | `a.addDataset(ds, Tags=dictionary("test-stand", "3"))` |
| Rename a reference name | `a.renameRefName("default", "tlm")` |
| Detach a data source | `a.removeDataset("can")` |
| Ensure it has a dataset of that name | `a.getOrCreateDataset(name)` |
| …without adopting an existing one | `a.getOrCreateDataset(name, AttachExisting=false)` |
| Start a run on it | `a.run(name)`, `a.run(name, startTime)` |
| Change metadata | `a.update(Name=…, Description=…, Labels=…, Properties=…)` |

An asset handle is a **snapshot** taken when it was fetched. `update()` returns a new object
instead of changing the one you have, and `datasources()` does not show a dataset attached
since the fetch until you pass `Refresh=true`.

Dataset names are not unique in Nominal, so `getOrCreateDataset` resolves in three steps and
prints which one it took:

1. A dataset of that name already on the asset is returned.
2. Otherwise a dataset of that exact name elsewhere in the workspace is **attached** to the
   asset and returned.
3. Otherwise one is created.

Step 2 is how "the dataset for serial 12345678" finds the one a colleague already made. Because
it changes your asset based on a name match, you can turn it off with `AttachExisting=false`.
If several datasets share the name, it errors and lists their RIDs. Attach the one you meant
with `a.addDataset(c.datasetByRid(rid))`.

`refName` is the dataset's name within the asset. It is only used when attaching, and you can
leave it out: a free one is chosen (`"default"` on an asset with none, otherwise the dataset's
own name). Supply one when an asset has two sources measuring the same thing, such as a CAN
log and a test rig both reporting `engine temp`, and you want to tell them apart.

An asset holds a dataset once per tag filter. Attaching it again with the same `Tags` moves it
to the new `refName`; with different `Tags` it is added alongside.

## Dataset

`ds = a.getOrCreateDataset("telemetry", "tlm")`

| Action | MATLAB |
|---|---|
| Identity and metadata | `ds.Rid`, `ds.Name`, `ds.Description`, `ds.Labels` |
| Read one property | `ds.property("script")` |
| What channels are in it | `ds.channels()` |
| Which assets hold it | `ds.assets()` |
| Open a live stream | `ds.stream()` |
| Write a block already in memory | `ds.write(channels, t, V)` |
| …tagging every point | `ds.write(channels, t, V, Tags=struct(UUT="A"))` |
| Read one channel back | `ds.fetch("rpm", t0, t1)` |
| Read it decimated, for plotting | `ds.fetch("rpm", t0, t1, Buckets=2000)` |
| …one tag set, when it has several | `ds.fetch("rpm", t0, t1, Tags=struct(UUT="A"))` |
| Export channels to a file | `ds.export("out.mat", channels, t0, t1)` |
| Export to a download link instead | `ds.exportUrl(channels, t0, t1)` |
| Read one channel's units | `ds.channelMetadata("rpm")` |
| Declare a channel's units | `ds.setChannelMetadata("rpm", "double", Unit="1/min")` |
| Change metadata | `ds.update(Name=…, Labels=…, Properties=…)` |

## Run

`r = a.run("burn-12")`

| Action | MATLAB |
|---|---|
| Identity and metadata | `r.Rid`, `r.Name`, `r.Description`, `r.Url`, `r.Number`, `r.Labels` |
| Timing | `r.StartTime`, `r.EndTime` |
| Assets it belongs to | `r.AssetRids` |
| Put it on another asset too | `r = r.addAsset(dut)` |
| Take it off one | `r = r.removeAsset(dut)` |
| Read one property | `r.property("operator")` |
| Attach a dataset (see [Known gaps](behavior.md#known-gaps)) | `r.addDataset(refName, ds)` |
| Close it | `r.finish()`, `r.finish(endTime)` |
| Change metadata | `r.update(Name=…, Labels=…, Properties=…)` |

## Stream and Channel

`s = ds.stream()`

| Action | MATLAB |
|---|---|
| Get a write address for a channel | `s.channel("rpm")` |
| Push an N-by-C block across channels | `s.push(channels, t, V)` |
| Push one channel | `ch.push(t, v)` |
| Tag every later point on an address | `ch.tag("bank", "1")` |
| Flush and close | `delete(s)` |

## Event

`e = c.createEvent(rids, "overspeed")`

| Action | MATLAB |
|---|---|
| Read it back | `e.Rid`, `e.Name`, `e.Type`, `e.Timestamp`, `e.Duration`, `e.AssetRids` |
| Read one property | `e.property("status")` |

## IngestJob

`job = c.ingest("flight.csv", …)`

| Action | MATLAB |
|---|---|
| Where the data is landing | `job.DatasetRid` |
| Check progress | `job.status()` |
| Block until it finishes | `job.wait()` |

## Free functions

| Action | MATLAB |
|---|---|
| Current time, full nanosecond precision | `nominal.now()` |
| datetime → int64 nanoseconds | `nominal.toNanos(dt)`, `nominal.toNanosVector(dt)` |
| int64 nanoseconds → UTC datetime | `nominal.fromNanos(nanos)` |
| Release everything, stop worker threads | `nominal.shutdown()` |

# Getting data out

{.lead}
Search by name, fetch a channel as a timetable, export a window to a file, or run SQL.

## Finding a RID

Search by name. Both return tables.

```matlab
c.assets("engine")                         % name contains "engine"
ds = c.datasetByRid(c.datasets("telemetry").Rid(1));
ds.channels()                              % what is inside it
```

Always pass a filter. With no argument, `c.assets()` and `c.datasets()` fetch every asset or
dataset in the workspace in one call, and there is no page size to pass.

## A channel in your workspace

`fetch` returns a timetable, so it plots and resamples directly.

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

Decimated points are bucket **means**, so the extremes are gone. Use the undecimated fetch if
you need them.

Several channels line up with `synchronize`:

```matlab
rpm = ds.fetch("rpm", t0, t1);
egt = ds.fetch("egt", t0, t1);
both = synchronize(rpm, egt);
```

Only numeric channels (double, int64, uint64) can be fetched or exported. A string channel in
an export list fails the whole request.

## Everything under a run, in a `.mat` file

Export moves the whole window in one request. A run's data sources are its asset's, so get
the dataset from the asset.

```matlab
r  = c.runByRid(runRid);
a  = c.assetByRid(assetRid);
ds = c.datasetByRid(a.datasources().Rid(1));

ds.export("burn12.mat", ds.channels().Name', r.StartTime, r.EndTime);
```

CSV and Arrow are the other formats: `Format="csv"`. `ds.exportUrl(...)` returns a time-limited
download URL instead of a file, for handing to a browser or something that is not MATLAB.

## SQL

Results come back as a table.

```matlab
t = c.query("SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + ds.Rid + "' ORDER BY ts LIMIT 1000");
t.ts = nominal.fromNanos(t.ts);          % timestamps arrive as int64 ns
```

The SQL tables are the warehouse's own, so the column names differ from the MATLAB classes.

**Telemetry tables** (`points_double`, `points_int`, `points_string`, `points_struct`, `logs`,
`channels`) *must* filter on `dataset_rid` or the query is rejected. `points_double` has `ts`,
`channel`, `value` and `dataset_rid`.

**Metadata tables** (`assets`, `runs`, `run_assets`, `datasets`, `events`) have no such
requirement, so `datasets` is another way to find a RID. They are capped at 10,000 rows.

Results over 1 GiB need `c.queryExportUrl(sql)`, which returns a CSV download link with no
size cap.

# Getting data out

{.lead}
Read data from Nominal into a timetable, a file on disk, or a SQL result table.

## Finding a dataset

`c.assets` and `c.datasets` return every asset or dataset whose name contains the text you pass,
ignoring case, as a table that includes each match's RID.

```matlab
c.assets("<search text>")
ds = c.datasetByRid(c.datasets("<search text>").Rid(1));
ds.channels()                              % the channels in the dataset
```

Always pass search text. With no argument, `c.assets()` and `c.datasets()` return every asset or
dataset in the workspace in one call.

## Reading a channel

`fetch` reads one numeric channel into a timetable.

```matlab
t1 = datetime("now", TimeZone="UTC");
t0 = t1 - hours(2);

tt = ds.fetch("<channel>", t0, t1);
plot(tt.Time, tt.(1))
```

To plot a wide window, have Nominal reduce it to roughly a given number of points:

```matlab
tt = ds.fetch("<channel>", t0, t1, Buckets=2000);
```

Each of those points is the mean of its bucket, so short spikes are smoothed out. Fetch without
`Buckets` when you need them.

`synchronize` lines up channels on one time axis:

```matlab
ch1  = ds.fetch("<channel 1>", t0, t1);
ch2  = ds.fetch("<channel 2>", t0, t1);
both = synchronize(ch1, ch2);
```

## Through an asset or a run

`a.fetch` and `r.fetch` read a channel from one of their data sources, with that source's tag
filter and time offset applied. `r.fetch` reads from the run's start to its end.

```matlab
tt = a.fetch("<channel>", t0, t1);         % from the data source called "default"
tt = r.fetch("<channel>", RefName="<ref name>");
```

## A run's data in a `.mat` file

`export` writes a time window to a file in one request. A run shows its asset's data sources,
so get the dataset from the asset.

```matlab
r  = c.runByRid("<run rid>");
a  = c.assetByRid(r.AssetRids(1));
ds = c.datasetByRid(a.datasources().Rid(1));

% export takes numeric channels only. A string channel fails the whole export.
ch      = ds.channels();
numeric = ch.Name(ismember(ch.DataType, ["double" "int" "uint"]))';
ds.export("run.mat", numeric, r.StartTime, r.EndTime);
```

Pass `Format="csv"` or `Format="arrow"` for the other formats. `ds.exportUrl` returns a
time-limited download link instead of a file.

## SQL

`c.query` runs a query and returns a table.

```matlab
t = c.query("SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + ds.Rid + "' ORDER BY ts LIMIT 100");
t.ts = nominal.fromNanos(t.ts);            % timestamps come back as int64 nanoseconds
```

Queries on telemetry tables must filter on `dataset_rid`. The
{hub}`SQL reference <sql/reference/schema/>` lists the tables and their columns.

Results over 1 GiB need `c.queryExportUrl(sql)`, which returns a download link to a CSV file.

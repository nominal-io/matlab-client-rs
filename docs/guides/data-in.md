# Getting data in

{.lead}
A matrix in memory, a file on disk, or a live stream. Plus units, provenance, runs and events.

## A `.mat` file

Load it and push the matrix. No intermediate file, no ingest job.

```matlab
load("flight12.mat");                      % gives t (datetime) and V (N-by-3)
c  = nominal.Client.fromProfile();
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12", "flight12");
ds.write(["rpm" "egt" "psi"], t, V);
```

## A CSV or Parquet file

Hand Nominal the path and let it parse.

```matlab
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12", "flight12");

job = c.ingest("flight12.csv", TimestampColumn="time", Dataset=ds);
job.wait();                                % raises if the ingest fails
```

Create the dataset under the asset first and pass `Dataset=`. `NewDataset=` also works but
creates a dataset attached to no asset; attach it afterwards with
`a.addDataset(c.datasetByRid(job.DatasetRid))`. `job.wait()` **raises** when the ingest fails,
so wrap it in `try` if you want to report the failure instead.

Timestamps default to ISO 8601. For a numeric column:
`c.ingest(path, TimestampColumn="t", Kind="epoch", Unit="milliseconds", …)`.

## A live stream

Open a stream once, push blocks as they fill.

```matlab
s     = ds.stream();
chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];
while acquiring
    [t, block] = readFromDAQ();            % t is N-by-1, block is N-by-3
    s.push(chans, t, block);
end
delete(s);                                 % flushes; blocks until it lands
```

See [Streaming](streaming.md) for the matrix-push pattern and backpressure.

## Which script produced this data

Properties and labels are free text, so record the provenance on the dataset.

```matlab
ds.update(Properties=struct(script="reduce_flight.m", ...
                            version="2.4.1", ...
                            matlab=string(version("-release")), ...
                            operator=c.whoAmI()), ...
          Labels=["flight-test" "reduced"]);
```

## Units on channels

`setChannelMetadata` is an upsert and works before any data exists, so declare units ahead of
a stream and the first plot comes out labelled.

```matlab
ds.setChannelMetadata("rpm", "double", Unit="1/min");
ds.setChannelMetadata("egt", "double", Unit="Cel", Description="Exhaust gas temp");
```

Units are UCUM symbols, not free text: `Cel` not `C` (which is coulomb), `1/min` not `rpm`,
`[psi]` in brackets. A symbol UCUM cannot parse is accepted but stored display-only, with no
conversions.

## Bracketing a test as a run

A run is a time window over an asset.

```matlab
r = a.run("burn-12", datetime("now", TimeZone="UTC"));
% ... test happens ...
r = r.finish();
```

Nothing attaches the data. A run's data sources **are** its asset's, live, so a dataset added
to the asset after the run was created is already on the run. `r.addDataset(...)` exists but
cannot succeed for a run made this way; see [Known gaps](behavior.md#known-gaps).

A run can cover more than one asset, such as a test chamber and the unit in it. `removeAsset`
refuses to take off the last one.

```matlab
r = chamber.run("test-42");
r = r.addAsset(dut);
```

## One dataset covering several units

Create it on its own, tag the points by unit, and give each unit's asset its own slice.

```matlab
ds = c.createDataset("bench telemetry");
ds.write("rpm", t, V, Tags=struct(UUT="A"));
unitA.addDataset(ds, Tags=struct(UUT="A"));
unitB.addDataset(ds, Tags=struct(UUT="B"));
ds.assets()                                % both units
```

## Flagging something that happened

Events mark a moment or an interval on an asset.

```matlab
c.createEvent(a.Rid, "overspeed", Type="error", ...
              Timestamp=datetime("now", TimeZone="UTC"), Duration=seconds(3));
```

# Getting data in

{.lead}
Write a matrix from memory, ingest a file from disk, or stream while a test runs.

## A `.mat` file

Load the file and write its matrix to a dataset.

```matlab
load("<file>.mat");                        % a datetime vector t and an N-by-3 matrix V
c  = nominal.Client.fromProfile();
a  = c.getOrCreateAsset("airframe-7");
ds = a.getOrCreateDataset("Flight 12");
ds.write(["rpm" "egt" "psi"], t, V);
```

## A CSV or Parquet file

Nominal parses the file, so pass its path and the name of its time column.

```matlab
ds  = a.getOrCreateDataset("Flight 12");
job = c.ingest("<file>.csv", TimestampColumn="<time column>", Dataset=ds);
job.wait();                                % raises if the ingest fails
```

Timestamps default to ISO 8601. For a numeric time column, say how to read it:

```matlab
job = c.ingest("<file>.csv", TimestampColumn="<time column>", Kind="epoch", Unit="milliseconds", Dataset=ds);
```

## A live stream

Open a stream once and push blocks as they fill.

```matlab
s     = ds.stream();
chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];
while acquiring
    [t, block] = readFromDAQ();            % t is N-by-1, block is N-by-3
    s.push(chans, t, block);
end
delete(s);                                 % flushes and waits until the data lands
```

[Streaming](streaming.md) covers timestamps, tags and closing the stream.

## Which script produced the data

Record provenance as properties and labels on the dataset.

```matlab
ds.update(Properties=struct(script="reduce_flight.m", ...
                            version="2.4.1", ...
                            matlab=string(version("-release")), ...
                            operator=c.whoAmI()), ...
          Labels=["flight-test" "reduced"]);
```

## Units on channels

Declare units before writing, so the first plot comes out labelled. `setChannelMetadata` works
on channels that have no data yet.

```matlab
ds.setChannelMetadata("rpm", "double", Unit="1/min");
ds.setChannelMetadata("egt", "double", Unit="Cel", Description="Exhaust gas temp");
```

Units are UCUM symbols: `Cel` not `C`, `1/min` not `rpm`, and `[psi]` in brackets. Nominal keeps
a symbol that isn't UCUM for display, but can't convert it.

## Bracketing a test as a run

A run marks the time window of a test on an asset. It shows every data source on the asset,
including datasets added later, so there is nothing to attach.

```matlab
r = a.run("burn-12");                      % starts now
% ... the test runs ...
r = r.finish();                            % ends now
```

A run can cover more than one asset, such as a test chamber and the unit in it:

```matlab
r = chamber.run("test-42");
r = r.addAsset(dut);
```

## A run with no asset

Simulation output has no physical system behind it. Keep one dataset per model, tag each
execution's points, and create a run per execution from the dataset.

```matlab
tags = dictionary(["model" "execution-id"], ["A" "7"]);
ds.write("thrust", t, V, Tags=tags);
r = c.createRun("Model A, execution 7", ds, Tags=tags, ...
                StartTime=int64(0), EndTime=int64(60e9));
```

## One dataset covering several units

Create the dataset on its own, tag the points by unit, and give each unit's asset its own
slice.

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

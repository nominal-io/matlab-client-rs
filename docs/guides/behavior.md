# How it behaves

{.lead}
Rules that hold for every object in the toolbox.

**No cleanup calls.** Deleting an object, or clearing the last variable that holds it, releases
everything it holds.

**Errors are exceptions.** A failure raises an `MException` with Nominal's message and an
identifier you can catch:

```matlab
try
    a = c.getOrCreateAsset("<asset name>");
catch e
    switch e.identifier
        case 'nominal:apiError'          % Nominal rejected the request
        case 'nominal:released'          % the object was deleted
        case 'nominal:invalidHandle'     % the object was used after nominal.shutdown()
    end
end
```

**Wrong-type arguments fail at the call site.** Passing a `Dataset` where a `Stream` belongs is
an immediate error that names both.

**Results are tables and timetables.** Listings return a `table`, and `fetch` returns a
`timetable`.

**Times are `datetime` or `int64` nanoseconds.** Anything that takes an instant accepts a zoned
`datetime` or an `int64` nanosecond count, and times come back as UTC `datetime`. `datetime`
doesn't hold nanoseconds, so use `nominal.now()` and `int64` when you need full precision.
Plain doubles are refused for timestamps because they can't hold a present-day nanosecond count
exactly. `int64(0)` is the epoch. Leave a run or event time out to mean now.

**Objects are snapshots.** `update()` returns a new object and leaves the one you have
unchanged. `a.datasources()` asks Nominal once and reuses the answer, so a dataset attached
after that first call is not listed until you pass `Refresh=true`.

**Labels and Properties replace, they do not merge.** Read the existing ones first if you mean
to add. To change one property and keep the rest, use `setProperty` or `removeProperty`.

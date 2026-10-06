# How it behaves

{.lead}
The rules that hold across every object, and the gaps you may hit.

**Objects free themselves.** Every object is a handle that releases its native resource when
it goes out of scope. Copies alias the same resource.

**Errors are exceptions.** Failures raise `MException`s with the library's message and an
identifier you can catch on:

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

**Wrong-type arguments fail at the call site.** Passing a `Dataset` where a `Stream` belongs
is an immediate error naming both.

**Results are tables and timetables.** Listings return a `table`; `fetch` returns a
`timetable`, so `sortrows`, `retime` and `synchronize` work directly.

**Times are `datetime`.** Anything taking an instant accepts a zoned `datetime` or an `int64`
nanosecond count. Times coming back are UTC `datetime`. `datetime` does not resolve to
nanoseconds, so use `nominal.now()` and raw `int64` when full precision matters.

Plain doubles are refused for timestamps: they lose integer precision past 2^53 nanoseconds,
which is 1970 plus 104 days, so a present-day timestamp would be silently rounded. `0` is
accepted as the "now" sentinel for run and event times.

**Handles are snapshots.** `update()` returns a new object instead of changing the one you
have. `a.datasources()` does not show a dataset attached since the handle was fetched until
you pass `Refresh=true`.

**Labels and Properties replace, they do not merge.** Read the existing ones first if you mean
to add.

## Requirements

**MATLAB R2021a or newer.** The floor is the `Name=Value` call syntax, as in
`ds.fetch("rpm", t0, t1, Buckets=2000)`. The older `'Buckets', 2000` form works in any release
if you need it. Nothing below R2026a has actually been tested.

**Windows x86-64, Apple silicon and Linux x86-64.** Intel macOS is not supported.

## Known gaps

- **String channels.** Streams carry doubles only.
- **Events cannot be listed or searched.** You can create one and read back the object you got.
- **`Run` has no `datasources()`.** A run's data sources are its asset's, so use
  `a.datasources()`.
- **`Run.addDataset` cannot succeed** for a run made with `asset.run()`, which is the only kind
  this client creates. A run's data sources are its asset's, live, so there is nothing to
  attach. Every argument returns an error.
- **Video and connection data sources** show up in `a.datasources()` with the right `Type`,
  but nothing here can act on one beyond renaming or detaching.
- **`a.datasources()` does not show tag filters.** The tags given to `addDataset` are stored
  but not read back.
- **Not available here:** time offsets on attached datasets, asset types, numeric properties,
  and compositions.
- **Listings cannot be limited or paged.** `c.assets()` and `c.datasets()` with no filter
  return everything, which on a large workspace is tens of thousands of rows and several
  seconds. Pass a name filter instead.
- **`count(*)` and other unmapped SQL types** come back as empty strings. Float, integer,
  boolean, string and timestamp columns are supported.

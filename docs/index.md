# Nominal for MATLAB

{.lead}
Get data into and out of [Nominal](https://nominal.io) from MATLAB.

```{toctree}
:hidden:
:caption: Guides

Overview <self>
quickstart
guides/authenticating
guides/cheatsheet
guides/data-in
guides/data-out
guides/streaming
guides/behavior
```

```{toctree}
:hidden:
:caption: Examples

examples/index
```

```{toctree}
:hidden:
:caption: Reference

ref/index
```

```matlab
c  = nominal.Client.fromProfile();
a  = c.getOrCreateAsset("<asset name>");
ds = a.getOrCreateDataset("<dataset name>");

ds.write(["<channel 1>" "<channel 2>"], t, V);   % one column of V per channel
tt = ds.fetch("<channel 1>", t0, t1);            % a timetable
```

::::{grid} 2
:::{grid-item-card} Quickstart
:link: quickstart
:link-type: doc

Install the toolbox, connect, write a matrix, read it back.
:::
:::{grid-item-card} Getting data in
:link: guides/data-in
:link-type: doc

Matrices, CSV and Parquet files, live streams, units, runs, events.
:::
:::{grid-item-card} Getting data out
:link: guides/data-out
:link-type: doc

Search, fetch a timetable, export a file, run SQL.
:::
:::{grid-item-card} Reference
:link: ref/index
:link-type: doc

Every class and method, from the same help text MATLAB shows.
:::
:::{grid-item-card} Examples
:link: examples/index
:link-type: doc

Runnable demos that ship inside the toolbox.
:::
:::{grid-item-card} All Nominal docs
:link: https://nominal-io.github.io/pub-docs/

Every language and product.
:::
::::

Building the toolbox from source is covered in the repository's
[BUILDING.md](https://github.com/nominal-io/matlab-client-rs/blob/main/BUILDING.md).

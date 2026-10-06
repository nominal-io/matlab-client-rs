# Nominal for MATLAB

{.lead}
Get data into and out of [Nominal](https://nominal.io) from MATLAB. One toolbox, no Python,
no DLLs.

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
a  = c.getOrCreateAsset("engine-3");
ds = a.getOrCreateDataset("telemetry", "tlm");

ds.write(["rpm" "egt" "psi"], t, V);       % push a matrix
tt = ds.fetch("rpm", t0, t1);              % get a timetable back
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
:link: https://dev.nominal.io/

Every language and product.
:::
::::

Building the toolbox from source is covered in the repository's
[BUILDING.md](https://github.com/nominal-io/nominal-matlab/blob/main/BUILDING.md).

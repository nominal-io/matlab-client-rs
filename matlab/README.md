# Nominal for MATLAB

An object-oriented MATLAB client over the Nominal C ABI.

```matlab
addpath('matlab')

c  = nominal.Client(getenv("NOMINAL_TOKEN"));
a  = c.asset("engine-3");
ds = a.dataset("telemetry", "tlm");
s  = ds.stream();

chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];

t = nominal.now() + int64(0:999)' * 1000000;   % 1 ms apart
v = randn(1000, 3);                            % one column per channel
s.push(chans, t, v);

delete(s);   % flush now, rather than whenever s is collected
```

## Building

From the repository root:

```
just mex-win64
```

That builds the Rust static library first, then compiles `src/nominalmex.c`
into `+nominal/private/`, linking the library in. Requires a configured C
compiler (`mex -setup C`).

The result is a single binary: `+nominal/private/nominalmex.mexw64` carries the
Rust code inside it, so there is no accompanying DLL for Windows to locate and
nothing to set up before first use.

If MATLAB is not on PATH, point the recipe at it — recipes run through bash, so
use forward slashes:

```
just matlab='C:/Program Files/MATLAB/R2026a/bin/matlab.exe' mex-win64
```

Then check it works:

```
just mex-test-win64
```

Or from this folder inside MATLAB:

```matlab
build                     % or build(Profile="fast")
addpath(pwd); addpath(fullfile(pwd,'tests')); smoketest
```

## What it gives you over the raw C API

**Handles free themselves.** Every class derives from a `handle` base with a
destructor, so `delete()` runs when a variable goes out of scope. There are no
`_free` calls to forget. Objects alias rather than copy, so passing one to a
function does not create a second owner of the same handle.

**Errors are exceptions.** Status codes become `MException`s carrying the
library's own message, with identifiers you can catch selectively:

```matlab
try
    a = c.asset("engine-3");
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
matlab/
├── build.m                     compile the gateway
├── src/nominalmex.c            single MEX gateway; all commands dispatch here
└── +nominal/
    ├── Resource.m              handle ownership and destructors
    ├── Client.m  Asset.m  Dataset.m  Run.m
    ├── Stream.m  Channel.m
    ├── now.m  toNanos.m  toNanosVector.m  fromNanos.m
    ├── shutdown.m
    └── private/
        └── nominalmex.mexw64   gateway + Rust library, in one binary
```

One gateway rather than one MEX per function: `mexAtExit` must be registered
exactly once, and a binary per command would mean dozens of files each carrying
a copy of the shutdown plumbing.

`nominalmex` lives in `private/` deliberately. It does no argument checking of
its own and calling it directly bypasses every guarantee the classes make.

## Known gaps

- Windows only so far. The gateway is portable C; `build.m` hard-codes the
  MSVC target path and the `.dll` extension.
- Events are not exposed — the underlying Rust SDK does not support them yet.
- Channel metadata (units, description, data type) is not exposed. When it is,
  it will be `nominal_channelmetadata_*` in C and a separate MATLAB class;
  see `crates/ffi/src/streamchannel.rs` for why it stays separate from the
  stream-side channel.
- Streaming has not been run from MATLAB. It works through the C ABI, but the
  gRPC write path is different from the HTTP one and is unproven from here.

## Status

Built and tested on R2026a with MSVC. `just mex-test-win64` runs ten offline
checks covering class loading, private-folder MEX resolution, `arguments`
validation, whitespace trimming, empty-means-absent, exception identifiers, and
destructor release. All pass.

A live call works too:

```matlab
addpath('C:\sw\nominal-c\matlab')
c = nominal.Client(getenv("NOMINAL_TOKEN"));
disp(c.whoAmI())
```

That covers authentication, the HTTP path, and strings coming back out. The
streaming path from MATLAB is still unexercised.

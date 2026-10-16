# Streaming

{.lead}
Push samples to a dataset while a test runs, one block at a time.

## Pushing a block

`push` takes an N-by-C matrix, one column per channel, and one timestamp column shared by all
of them. Fill a preallocated matrix and push it whole.

```matlab
s     = ds.stream();
chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];

t = zeros(1000, 1, 'int64');
v = zeros(1000, 3);
for i = 1:1000
    t(i)    = nominal.now();
    v(i, :) = readSample();
end
s.push(chans, t, v);
delete(s);                                 % flushes and waits until the data lands
```

`push` blocks when points arrive faster than the network can send them. If your acquisition
loop can't stall, produce the data on a separate thread.

## Timestamps

Use `nominal.now()` and `int64` nanoseconds for streaming timestamps. `datetime` doesn't hold
nanoseconds, so a round trip through it loses precision. Timestamps are taken as given:
`int64(0)` is the epoch.

## Tags

Tag a channel to stamp every point pushed through it from then on:

```matlab
chans(1).tag("bank", "1");
```

Points pushed earlier keep the tags they were sent with. Keep the number of distinct tag values
low: a value that changes with every point belongs in its own channel.

## Closing the stream

Deleting the stream sends what is still buffered and waits until it has landed. MATLAB doesn't
promise when it clears a variable, so call `delete(s)` yourself when the data must be in Nominal
before you move on. The points can take a moment to appear in Nominal after that.

## Shutdown

You don't need to call `nominal.shutdown()`. `clear mex`, `clear all` and quitting MATLAB all
shut the library down first.

Call it to tear everything down at a known point, such as the end of a long script. Every
`nominal` object you hold stops working, and the next call starts the library again.

# Streaming

{.lead}
Push a matrix per block, not a point at a time. And what happens at shutdown.

## Prefer the matrix push

`nominal.Stream.push` takes an N-by-C matrix, one column per channel, with one shared
timestamp column. MATLAB stores matrices column-major, so the data goes to the library with
no copy. Preallocate a matrix, fill it in a loop, push it.

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
delete(s);                                 % flushes; blocks until it lands
```

`push` blocks when the stream saturates. If points arrive faster than the network drains
them, it waits instead of queueing without bound. Produce on a separate thread if your
acquisition loop cannot stall.

## Timestamps

Use `nominal.now()` and `int64` for streaming timestamps. `datetime` does not resolve to
nanoseconds, so a round trip through it is lossy. Streaming timestamps are literal, including
zero. Unlike run and event times, `0` does not mean "now".

## Tags

`ch.tag("bank", "1")` stamps every point pushed through that channel from then on. Tags belong
to points, not to the channel, so earlier points keep the tags they were sent with. Keep tag
cardinality low: anything that changes every point belongs in its own channel.

## Flush and close

Deleting the stream flushes what is still buffered and blocks until it has landed. MATLAB does
not promise when a variable is collected, so call `delete(s)` yourself if you need the data to
be there before moving on. Points take a moment to appear in Nominal afterwards.

## Shutdown

You do not need to call `nominal.shutdown()`. `clear mex`, `clear all` and quitting MATLAB all
shut the library down cleanly first.

Call it when you want the teardown at a known point, such as the end of a long script. It
invalidates every outstanding handle. The next call builds a fresh runtime, so the library is
usable again immediately.

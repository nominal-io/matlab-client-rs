function tt = scopeFetch(client, ownerRid, refName, channel, startTime, endTime, buckets, tags)
%SCOPEFETCH  Read a channel through an asset's or run's data source.
%
%   Shared by Asset.fetch and Run.fetch. The server applies the data
%   source's tag filter and offset; tags narrows further.

    [tagKeys, tagValues] = keyValuePairs(tags, "tag");
    [nanos, values] = nominalmex('scope_fetch', client.Handle, char(ownerRid), ...
        char(refName), char(channel), nominal.toNanos(startTime), ...
        nominal.toNanos(endTime), int32(buckets), tagKeys, tagValues);
    tt = seriesTimetable(nanos, values, channel);
end

function results = nominalexample_analysisdemo(datasetRid)
%NOMINALEXAMPLE_ANALYSISDEMO  Reading data out: discovery, fetch, export, SQL.
%
%   nominalexample_analysisdemo("ri.catalog....")
%   results = nominalexample_analysisdemo("ri.catalog....")
%
%   Needs credentials. Read-only apart from the file it writes into the current
%   folder, so it is safe to point at real data.
%
%   Everything fetched is returned as a struct, and also left in the base
%   workspace as `nominalAnalysis`:
%
%       nominalexample_analysisdemo(rid)
%       plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))
%       head(nominalAnalysis.Points)
%
%   Fields: Dataset, Channels, Samples, Decimated, Aligned, Points,
%   ExportFile, StartTime, StopTime. A field a step could not fill is empty.
%
%   To find a dataset RID:
%
%       c   = nominalexample_connect();
%       rid = c.datasets("telemetry").Rid(1);
%       nominalexample_analysisdemo(rid)
%
%   The other demos put data in. This one takes it back out:
%
%     Discovery   - a dataset and its channels, as tables.
%     Fetch       - one channel into a timetable; decimated for wide windows.
%     Export      - the whole window to a .mat file in one request.
%     SQL         - a query against the warehouse, returned as a table.
%
%   See also NOMINAL.DATASET/FETCH, NOMINAL.CLIENT/QUERY,
%   NOMINALEXAMPLE_CONNECT

    arguments
        datasetRid (1,1) string
    end

    % Every field starts empty; a failed or skipped step leaves it that way.
    results = struct( ...
        'Dataset',    "", ...
        'Channels',   table(), ...
        'Samples',    timetable(), ...
        'Decimated',  timetable(), ...
        'Aligned',    timetable(), ...
        'Points',     table(), ...
        'ExportFile', "", ...
        'StartTime',  NaT("TimeZone", "UTC"), ...
        'StopTime',   NaT("TimeZone", "UTC"));

    client = nominalexample_connect();
    fprintf('\n');

    % 1 ------------------------------------------------------- discovery
    %
    % Listings are tables, so they filter with ordinary logical indexing.
    fprintf('--- Discovery ---\n');

    dataset = client.datasetByRid(datasetRid);
    results.Dataset = dataset.Name;
    fprintf('Dataset: %s\n\n', dataset.Name);

    results.Channels = dataset.channels();
    if isempty(results.Channels)
        fprintf('No channels yet — run nominalexample_streamdemo first.\n');
        nominalexample_publish(results, "nominalAnalysis");
        delete(dataset); delete(client);
        return
    end
    disp(head(results.Channels, 10));

    % Only numeric channels (double, int64, uint64) can be fetched or exported.
    % Anything else is rejected with Compute:ChannelHasWrongType.
    numericChannels = results.Channels( ...
        ismember(results.Channels.DataType, ["double" "int64" "uint64"]), :);

    if isempty(numericChannels)
        fprintf('\nNo numeric channels — nothing here can be fetched.\n');
        nominalexample_publish(results, "nominalAnalysis");
        delete(dataset); delete(client);
        return
    end
    if height(numericChannels) < height(results.Channels)
        fprintf('%d of %d channels are numeric; the rest cannot be fetched.\n', ...
                height(numericChannels), height(results.Channels));
    end

    % 2 ----------------------------------------------------------- fetch
    %
    % A day-wide window to catch whatever the write demos left. The window is
    % inclusive at both ends; a second of slack past now catches a sample
    % written moments ago.
    results.StopTime  = datetime("now", TimeZone="UTC") + seconds(1);
    results.StartTime = results.StopTime - days(1);

    % A declared channel need not have data (setChannelMetadata is an upsert),
    % so take the first numeric channel that returns samples.
    %
    % The timetable has one variable, named after the channel; .(1) addresses
    % it without knowing the name.
    firstChannelName = numericChannels.Name(1);
    for candidate = numericChannels.Name'
        samples = dataset.fetch(candidate, results.StartTime, results.StopTime);
        if height(samples) > 0
            firstChannelName = candidate;
            results.Samples = samples;
            break
        end
    end

    fprintf('\n--- Fetch: %s ---\n', firstChannelName);
    fprintf('%d samples\n', height(results.Samples));
    if height(results.Samples) == 0
        fprintf('  (no numeric channel has data in this window yet — streamed\n');
        fprintf('   points take a moment to land)\n');
    end

    % Window for anything bucketed; narrowed below once the samples show where
    % the data is. Also used by the synchronize step.
    bucketStart = results.StartTime;
    bucketStop = results.StopTime;

    if height(results.Samples) > 0
        sampleValues = results.Samples.(1);
        fprintf('  first %s = %g\n', string(results.Samples.Time(1)), sampleValues(1));
        fprintf('  last  %s = %g\n', string(results.Samples.Time(end)), sampleValues(end));

        % Ordinary statistics work directly on the timetable variable.
        fprintf('  mean %g, std %g\n', mean(sampleValues), std(sampleValues));

        % Narrow the window to the data before decimating. Buckets divide the
        % requested window, not the returned samples: 200 buckets across a day
        % would put half a second of samples in one bucket and return one point.
        bucketStart = results.Samples.Time(1);
        bucketStop = results.Samples.Time(end);

        % Ask the server for roughly this many points instead of every sample.
        requestedBuckets = 200;
        results.Decimated = dataset.fetch(firstChannelName, ...
            bucketStart, bucketStop, Buckets=requestedBuckets);
        % Printed as seconds: string(duration) shows a sub-second span as
        % 00:00:00.
        fprintf('  decimated to %d point(s) over %.3f s\n', ...
                height(results.Decimated), seconds(bucketStop - bucketStart));

        % Fewer points than buckets is normal: empty buckets are dropped.
        if height(results.Decimated) < requestedBuckets
            fprintf('    (asked for %d; empty buckets are not returned)\n', ...
                    requestedBuckets);
        end
    end

    % 3 ------------------------------------------- two channels together
    %
    % synchronize unions the row times across channels, so the result has one
    % row per distinct instant. Pick a second numeric channel, different from
    % the first.
    otherChannels = numericChannels.Name(numericChannels.Name ~= firstChannelName);

    if ~isempty(otherChannels) && height(results.Samples) > 0
        fprintf('\n--- Synchronize ---\n');
        secondChannelName = otherChannels(1);

        % The narrowed window again, for the same reason as above.
        firstSamples = dataset.fetch(firstChannelName, ...
            bucketStart, bucketStop, Buckets=100);
        secondSamples = dataset.fetch(secondChannelName, ...
            bucketStart, bucketStop, Buckets=100);

        results.Aligned = synchronize(firstSamples, secondSamples);
        fprintf('%s + %s -> %d rows, %d variables\n', ...
                firstChannelName, secondChannelName, ...
                height(results.Aligned), width(results.Aligned));
    end

    % 4 ---------------------------------------------------------- export
    %
    % Same data as fetch, but one request straight to disk. Use it for wide
    % windows. matfile is the default format.
    fprintf('\n--- Export ---\n');
    results.ExportFile = string(fullfile(pwd, "nominalexample_analysisdemo.mat"));

    % Numeric channels only: a string channel in the list fails the whole
    % request. Transposed because export takes a 1-by-C row of names.
    dataset.export(results.ExportFile, numericChannels.Name', ...
                   results.StartTime, results.StopTime);

    exportFileInfo = dir(results.ExportFile);
    fprintf('Wrote %s (%.1f KB)\n', results.ExportFile, exportFileInfo.bytes / 1024);

    % A download link instead of the bytes.
    try
        downloadUrl = dataset.exportUrl(firstChannelName, ...
            results.StartTime, results.StopTime, Format="csv");
        fprintf('Presigned CSV URL: %s...\n', ...
                extractBefore(downloadUrl, min(60, strlength(downloadUrl))));
    catch exportError
        % Some deployments have no export bucket configured.
        fprintf('exportUrl unavailable: %s\n', exportError.message);
    end

    % 5 ------------------------------------------------------------- SQL
    %
    % The tables are the warehouse's own, not the object model. Telemetry lives
    % in points_double, and a telemetry table must filter on dataset_rid or the
    % query is rejected.
    %
    % Bound the query to the window above as well. points_double holds every
    % point the dataset has ever taken, so without a time filter ORDER BY ts
    % returns the oldest rows in it, which on a re-used dataset is whatever an
    % earlier run wrote. ts is a timestamp column in the warehouse, not the
    % int64 nanoseconds it comes back as, so the bounds go in as literals. The
    % millisecond of slack covers the format truncating rather than rounding.
    lo = string(bucketStart - milliseconds(1), "yyyy-MM-dd HH:mm:ss.SSS");
    hi = string(bucketStop  + milliseconds(1), "yyyy-MM-dd HH:mm:ss.SSS");
    timeFilter = "AND ts BETWEEN TIMESTAMP '" + lo + "' " + ...
                 "AND TIMESTAMP '" + hi + "' ";

    fprintf('\n--- SQL ---\n');
    try
        results.Points = client.query( ...
            "SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + datasetRid + "' " + timeFilter + ...
            "ORDER BY ts LIMIT 100");

        % ts arrives as int64 nanoseconds; convert in place with nominal.fromNanos.
        if height(results.Points) > 0
            results.Points.ts = nominal.fromNanos(results.Points.ts);
        end
        fprintf('%d rows\n', height(results.Points));
        disp(head(results.Points, 5));
    catch queryError
        fprintf('query failed: %s\n  %s\n', queryError.identifier, queryError.message);
    end

    % For a result too large for memory, ask for a CSV download link instead.
    % Telemetry tables only; some deployments have no export bucket.
    try
        csvDownloadUrl = client.queryExportUrl( ...
            "SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + datasetRid + "' " + timeFilter + ...
            "LIMIT 1000");
        fprintf('CSV export URL: %s...\n', ...
                extractBefore(csvDownloadUrl, min(60, strlength(csvDownloadUrl))));
    catch exportUrlError
        fprintf('queryExportUrl failed: %s\n  %s\n', ...
                exportUrlError.identifier, exportUrlError.message);
    end

    % 6 -------------------------------------------------------- teardown
    delete(dataset);
    delete(client);
    nominalexample_publish(results, "nominalAnalysis");
    fprintf('  e.g. plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))\n');
end

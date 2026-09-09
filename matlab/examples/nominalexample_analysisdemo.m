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
%   workspace as `nominalAnalysis` so there is something to poke at afterwards
%   even when the demo is run as a bare statement:
%
%       nominalexample_analysisdemo(rid)
%       plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))
%       head(nominalAnalysis.Points)
%
%   Fields: Dataset, Channels, Samples, Decimated, Aligned, Points,
%   ExportFile, StartTime, StopTime. Anything a step could not produce stays
%   empty rather than missing, so indexing into it never errors.
%
%   To find a dataset RID:
%
%       c   = nominalexample_connect();
%       rid = c.datasets("telemetry").Rid(1);
%       nominalexample_analysisdemo(rid)
%
%   The other demos put data in. This one takes it back out, which is the half
%   most MATLAB users care about:
%
%     Discovery   — find an asset, a dataset, and its channels without knowing
%                   a RID. Everything comes back as a table.
%
%     Fetch       — one channel into a timetable, which plots and resamples
%                   with no conversion. Decimated for wide windows.
%
%     Export      — the whole window straight to a .mat file, in one request
%                   rather than paging.
%
%     SQL         — a query against the warehouse, returned as a table.
%
%   See also NOMINAL.DATASET/FETCH, NOMINAL.CLIENT/QUERY,
%   NOMINALEXAMPLE_CONNECT

    arguments
        datasetRid (1,1) string
    end

    % Everything starts empty, so a step that fails or is skipped leaves a
    % field that still indexes cleanly rather than one that is absent.
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
    % Listings are tables, so they display legibly and filter with ordinary
    % logical indexing. This is the entry point when you have no RID.
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

    % Only numeric channels can be fetched or exported. The compute service
    % rejects anything else with Compute:ChannelHasWrongType, naming DOUBLE,
    % INT64 and UINT64 as the types it will take — so a dataset carrying a
    % string channel breaks any code that picks channels positionally.
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
    % A window wide enough to catch whatever the write demos left behind. The
    % window is inclusive at both ends, and a second of slack past "now" keeps
    % a sample written moments ago from falling outside it.
    results.StopTime  = datetime("now", TimeZone="UTC") + seconds(1);
    results.StartTime = results.StopTime - days(1);

    % A declared channel need not have any data: setChannelMetadata is an
    % upsert, so units can be attached to a channel nothing has written yet.
    % Take the first numeric channel that actually returns samples rather than
    % the first one alphabetically, so the rest of the demo has something to
    % work with.
    %
    % The timetable has exactly one variable, named after the channel. It is
    % addressed positionally below — .(1) — because the channel name is only
    % known at run time.
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

    % The window to use for anything bucketed, narrowed below once the samples
    % show where the data actually is. Declared out here so the synchronize
    % block can use it too, and defaulted so it is always defined.
    bucketStart = results.StartTime;
    bucketStop = results.StopTime;

    if height(results.Samples) > 0
        sampleValues = results.Samples.(1);
        fprintf('  first %s = %g\n', string(results.Samples.Time(1)), sampleValues(1));
        fprintf('  last  %s = %g\n', string(results.Samples.Time(end)), sampleValues(end));

        % A timetable is the point of returning one: this all works directly.
        fprintf('  mean %g, std %g\n', mean(sampleValues), std(sampleValues));

        % Narrow to what the data actually spans before decimating.
        %
        % Buckets divide the *requested* window, not the returned samples. The
        % search window above is a day wide because the demo cannot know when
        % the data was written; asking for 200 buckets across it puts a
        % half-second of samples in one bucket and returns a single point —
        % correct, and useless. Now that the samples are in hand, their own
        % extent is the right window.
        bucketStart = results.Samples.Time(1);
        bucketStop = results.Samples.Time(end);

        % Decimated. Ask the server for roughly this many points rather than
        % moving every sample — for a plot the difference is invisible.
        requestedBuckets = 200;
        results.Decimated = dataset.fetch(firstChannelName, ...
            bucketStart, bucketStop, Buckets=requestedBuckets);
        % Printed as seconds rather than string(duration): the default
        % hh:mm:ss format shows a sub-second span, which this usually is, as
        % a flat 00:00:00.
        fprintf('  decimated to %d point(s) over %.3f s\n', ...
                height(results.Decimated), seconds(bucketStop - bucketStart));

        % Fewer points than buckets is normal: empty buckets are dropped, so
        % asking for more buckets than there are samples cannot invent data.
        if height(results.Decimated) < requestedBuckets
            fprintf('    (asked for %d; empty buckets are not returned)\n', ...
                    requestedBuckets);
        end
    end

    % 3 ------------------------------------------- two channels together
    %
    % synchronize is why fetch returns timetables rather than raw arrays:
    % aligning two channels on independent clocks is one call. It unions the
    % row times and fills the gaps, so the result has one row per distinct
    % instant across both inputs.
    % Numeric channels only, and a different one from the first — picking
    % positionally out of the full channel list is what made this step fail
    % against a dataset carrying a string channel.
    otherChannels = numericChannels.Name(numericChannels.Name ~= firstChannelName);

    if ~isempty(otherChannels) && height(results.Samples) > 0
        fprintf('\n--- Synchronize ---\n');
        secondChannelName = otherChannels(1);

        % The narrowed window again — bucketing across the full day-wide search
        % window would collapse both channels to a single row each.
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
    % Same data as fetch, but one request and straight to disk. This is the
    % right tool for a wide window, and matfile is the default format.
    fprintf('\n--- Export ---\n');
    results.ExportFile = string(fullfile(pwd, "nominalexample_analysisdemo.mat"));

    % Numeric channels only — export goes through the same compute service as
    % fetch, so a string channel in the list fails the whole request.
    %
    % Transposed: Name is a column out of the table, and export takes a 1-by-C
    % row of names.
    dataset.export(results.ExportFile, numericChannels.Name', ...
                   results.StartTime, results.StopTime);

    exportFileInfo = dir(results.ExportFile);
    fprintf('Wrote %s (%.1f KB)\n', results.ExportFile, exportFileInfo.bytes / 1024);

    % A link instead of the bytes, for handing to something that is not MATLAB.
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
    % Telemetry lives in points_double, keyed by dataset_rid and channel. The
    % SQL surface is the warehouse's own tables rather than the object model,
    % so the columns are not the ones these classes expose — and a telemetry
    % table must filter on dataset_rid or the query is rejected before it runs.
    fprintf('\n--- SQL ---\n');
    try
        results.Points = client.query( ...
            "SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + datasetRid + "' " + ...
            "ORDER BY ts LIMIT 100");

        % ts arrives as int64 nanoseconds. Converting in place turns the column
        % into datetimes without disturbing the rest of the table.
        if height(results.Points) > 0
            results.Points.ts = nominal.fromNanos(results.Points.ts);
        end
        fprintf('%d rows\n', height(results.Points));
        disp(head(results.Points, 5));
    catch queryError
        fprintf('query failed: %s\n  %s\n', queryError.identifier, queryError.message);
    end

    % For a result too large to hold in memory, ask for a CSV download link
    % instead of the rows. Telemetry tables only, and some deployments have no
    % export bucket configured.
    try
        csvDownloadUrl = client.queryExportUrl( ...
            "SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + datasetRid + "' LIMIT 1000");
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

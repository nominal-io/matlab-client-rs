function analysisdemo(datasetRid)
%ANALYSISDEMO  Reading data back out: discovery, fetch, export, and SQL.
%
%   analysisdemo("ri.catalog....")
%
%   Needs credentials. Read-only apart from the file it writes into the current
%   folder, so it is safe to point at real data.
%
%   To find a dataset RID:
%
%       c   = connect();
%       rid = c.datasets("telemetry").Rid(1);
%       analysisdemo(rid)
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
%   See also NOMINAL.DATASET/FETCH, NOMINAL.CLIENT/QUERY, CONNECT

    arguments
        datasetRid (1,1) string
    end

    client = connect();
    fprintf('\n');

    % 1 ------------------------------------------------------- discovery
    %
    % Listings are tables, so they display legibly and filter with ordinary
    % logical indexing. This is the entry point when you have no RID.
    fprintf('--- Discovery ---\n');
    fprintf('%d assets, %d datasets visible\n', ...
            height(client.assets()), height(client.datasets()));

    % Searching is a case-insensitive substring match on the name, not a
    % pattern — this is how you find a RID when all you have is a name.
    % (Not named "matches": that is a MATLAB builtin for pattern matching.)
    demoAssets = client.assets("demo");
    fprintf('%d asset(s) matching "demo"\n', height(demoAssets));

    dataset = client.datasetByRid(datasetRid);
    fprintf('Dataset: %s\n\n', dataset.Name);

    channelTable = dataset.channels();
    if isempty(channelTable)
        fprintf('No channels in this dataset yet — run streamdemo first.\n');
        return
    end
    disp(head(channelTable, 10));

    % 2 ----------------------------------------------------------- fetch
    %
    % A window wide enough to catch whatever the write demos left behind. The
    % window is inclusive at both ends, and a second of slack past "now" keeps
    % a sample written moments ago from falling outside it.
    stopTime  = datetime("now", TimeZone="UTC") + seconds(1);
    startTime = stopTime - days(1);

    firstChannelName = channelTable.Name(1);
    fprintf('\n--- Fetch: %s ---\n', firstChannelName);

    % The timetable has exactly one variable, named after the channel. It is
    % addressed positionally here — samples.(1) — because the channel name is
    % only known at run time.
    samples = dataset.fetch(firstChannelName, startTime, stopTime);
    fprintf('%d samples\n', height(samples));

    if height(samples) > 0
        sampleValues = samples.(1);
        fprintf('  first %s = %g\n', string(samples.Time(1)), sampleValues(1));
        fprintf('  last  %s = %g\n', string(samples.Time(end)), sampleValues(end));

        % A timetable is the point of returning one: this all works directly.
        fprintf('  mean %g, std %g\n', mean(sampleValues), std(sampleValues));

        % Decimated. Ask the server for roughly this many points rather than
        % moving every sample — for a plot the difference is invisible.
        decimatedSamples = dataset.fetch(firstChannelName, startTime, stopTime, ...
                                         Buckets=200);
        fprintf('  decimated to %d points\n', height(decimatedSamples));
    end

    % 3 ------------------------------------------- two channels together
    %
    % synchronize is why fetch returns timetables rather than raw arrays:
    % aligning two channels on independent clocks is one call. It unions the
    % row times and fills the gaps, so the result has one row per distinct
    % instant across both inputs.
    if height(channelTable) >= 2
        fprintf('\n--- Synchronize ---\n');
        secondChannelName = channelTable.Name(2);

        firstSamples = dataset.fetch(firstChannelName, startTime, stopTime, ...
                                     Buckets=100);
        secondSamples = dataset.fetch(secondChannelName, startTime, stopTime, ...
                                      Buckets=100);

        alignedSamples = synchronize(firstSamples, secondSamples);
        fprintf('%s + %s -> %d rows, %d variables\n', ...
                firstChannelName, secondChannelName, ...
                height(alignedSamples), width(alignedSamples));
    end

    % 4 ---------------------------------------------------------- export
    %
    % Same data as fetch, but one request and straight to disk. This is the
    % right tool for a wide window, and matfile is the default format.
    fprintf('\n--- Export ---\n');
    exportFilePath = fullfile(pwd, "analysisdemo.mat");

    % Transposed: channelTable.Name is a column out of the table, and export
    % takes a 1-by-C row of names.
    allChannelNames = channelTable.Name';
    dataset.export(exportFilePath, allChannelNames, startTime, stopTime);

    exportFileInfo = dir(exportFilePath);
    fprintf('Wrote %s (%.1f KB)\n', exportFilePath, exportFileInfo.bytes / 1024);

    % A link instead of the bytes, for handing to something that is not MATLAB.
    try
        downloadUrl = dataset.exportUrl(firstChannelName, startTime, stopTime, ...
                                        Format="csv");
        fprintf('Presigned CSV URL: %s...\n', ...
                extractBefore(downloadUrl, min(60, strlength(downloadUrl))));
    catch exportError
        % Some deployments have no export bucket configured.
        fprintf('exportUrl unavailable: %s\n', exportError.message);
    end

    % 5 ------------------------------------------------------------- SQL
    %
    % Timestamps arrive as int64 nanoseconds whatever the warehouse sent, so
    % convert the ones you want to read.
    fprintf('\n--- SQL ---\n');

    % Telemetry lives in points_double, keyed by dataset_rid and channel — the
    % SQL surface is the warehouse's tables, not the object model, so there is
    % no "datasets" or "runs" table to select from here.
    try
        points = client.query( ...
            "SELECT ts, channel, value FROM points_double " + ...
            "WHERE dataset_rid = '" + datasetRid + "' " + ...
            "ORDER BY ts LIMIT 5");

        % ts arrives as int64 nanoseconds. Converting in place turns the column
        % into datetimes without disturbing the rest of the table.
        if height(points) > 0
            points.ts = nominal.fromNanos(points.ts);
        end
        disp(points);
    catch queryError
        % The SQL service always needs a workspace, even where the rest of the
        % API does not — an unscoped client has to name one.
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
    fprintf('\nDone.\n');
end

function results = analysisdemo(datasetRid)
%ANALYSISDEMO  Reading data back out: discovery, fetch, export, and SQL.
%
%   analysisdemo("ri.catalog....")
%   results = analysisdemo("ri.catalog....")
%
%   Needs credentials. Read-only apart from the file it writes into the current
%   folder, so it is safe to point at real data.
%
%   Everything fetched is returned as a struct, and also left in the base
%   workspace as `nominalAnalysis` so there is something to poke at afterwards
%   even when the demo is run as a bare statement:
%
%       analysisdemo(rid)
%       plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))
%       head(nominalAnalysis.Points)
%
%   Fields: Dataset, Channels, Samples, Decimated, Aligned, Points,
%   ExportFile, StartTime, StopTime. Anything a step could not produce stays
%   empty rather than missing, so indexing into it never errors.
%
%   To find a dataset RID:
%
%       c   = nominalconnect();
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
%   See also NOMINAL.DATASET/FETCH, NOMINAL.CLIENT/QUERY, NOMINALCONNECT

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

    client = nominalconnect();
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
        fprintf('No channels in this dataset yet — run streamdemo first.\n');
        nominalpublish(results, "nominalAnalysis");
        delete(dataset); delete(client);
        return
    end
    disp(head(results.Channels, 10));

    % 2 ----------------------------------------------------------- fetch
    %
    % A window wide enough to catch whatever the write demos left behind. The
    % window is inclusive at both ends, and a second of slack past "now" keeps
    % a sample written moments ago from falling outside it.
    results.StopTime  = datetime("now", TimeZone="UTC") + seconds(1);
    results.StartTime = results.StopTime - days(1);

    firstChannelName = results.Channels.Name(1);
    fprintf('\n--- Fetch: %s ---\n', firstChannelName);

    % The timetable has exactly one variable, named after the channel. It is
    % addressed positionally below — .(1) — because the channel name is only
    % known at run time.
    results.Samples = dataset.fetch(firstChannelName, results.StartTime, results.StopTime);
    fprintf('%d samples\n', height(results.Samples));

    if height(results.Samples) > 0
        sampleValues = results.Samples.(1);
        fprintf('  first %s = %g\n', string(results.Samples.Time(1)), sampleValues(1));
        fprintf('  last  %s = %g\n', string(results.Samples.Time(end)), sampleValues(end));

        % A timetable is the point of returning one: this all works directly.
        fprintf('  mean %g, std %g\n', mean(sampleValues), std(sampleValues));

        % Decimated. Ask the server for roughly this many points rather than
        % moving every sample — for a plot the difference is invisible.
        results.Decimated = dataset.fetch(firstChannelName, ...
            results.StartTime, results.StopTime, Buckets=200);
        fprintf('  decimated to %d points\n', height(results.Decimated));
    end

    % 3 ------------------------------------------- two channels together
    %
    % synchronize is why fetch returns timetables rather than raw arrays:
    % aligning two channels on independent clocks is one call. It unions the
    % row times and fills the gaps, so the result has one row per distinct
    % instant across both inputs.
    if height(results.Channels) >= 2
        fprintf('\n--- Synchronize ---\n');
        secondChannelName = results.Channels.Name(2);

        firstSamples = dataset.fetch(firstChannelName, ...
            results.StartTime, results.StopTime, Buckets=100);
        secondSamples = dataset.fetch(secondChannelName, ...
            results.StartTime, results.StopTime, Buckets=100);

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
    results.ExportFile = string(fullfile(pwd, "analysisdemo.mat"));

    % Transposed: Channels.Name is a column out of the table, and export takes
    % a 1-by-C row of names.
    dataset.export(results.ExportFile, results.Channels.Name', ...
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
    nominalpublish(results, "nominalAnalysis");
    fprintf('  e.g. plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))\n');
end

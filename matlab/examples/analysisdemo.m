function analysisdemo(datasetRid)
%ANALYSISDEMO  Reading data back out: discovery, fetch, export, and SQL.
%
%   analysisdemo("ri.catalog....")   % explicit dataset
%   analysisdemo                     % reads NOMINAL_DATASET_RID
%
%   Needs NOMINAL_TOKEN. Read-only apart from the file it writes into the
%   current folder, so it is safe to point at real data.
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
%   See also NOMINAL.DATASET/FETCH, NOMINAL.DATASET/EXPORT, NOMINAL.CLIENT/QUERY

    arguments
        datasetRid (1,1) string = string(getenv("NOMINAL_DATASET_RID"))
    end

    token = string(getenv("NOMINAL_TOKEN"));
    if token == ""
        error('nominal:demo', 'set NOMINAL_TOKEN in the environment');
    end
    if datasetRid == ""
        error('nominal:demo', 'pass a dataset RID, or set NOMINAL_DATASET_RID');
    end

    client = nominal.Client(token);
    fprintf('Connected as %s\n\n', client.whoAmI());

    % 1 ------------------------------------------------------- discovery
    %
    % Listings are tables, so they display legibly and filter with ordinary
    % logical indexing. This is the entry point when you have no RID.
    fprintf('--- Discovery ---\n');
    fprintf('%d assets, %d datasets visible\n', ...
            height(client.assets()), height(client.datasets()));

    % Searching is a case-insensitive substring match on the name, not a
    % pattern — this is how you find a RID when all you have is a name.
    matches = client.assets("demo");
    fprintf('%d asset(s) matching "demo"\n', height(matches));

    dataset = client.datasetByRid(datasetRid);
    fprintf('Dataset: %s\n\n', dataset.Name);

    channels = dataset.channels();
    if isempty(channels)
        fprintf('No channels in this dataset yet — run streamdemo first.\n');
        return
    end
    disp(head(channels, 10));

    % 2 ----------------------------------------------------------- fetch
    %
    % A window wide enough to catch whatever the write demos left behind. The
    % window is inclusive at both ends, and a second of slack past "now" keeps
    % a sample written moments ago from falling outside it.
    stopTime  = datetime("now", TimeZone="UTC") + seconds(1);
    startTime = stopTime - days(1);

    name = channels.Name(1);
    fprintf('\n--- Fetch: %s ---\n', name);

    tt = dataset.fetch(name, startTime, stopTime);
    fprintf('%d samples\n', height(tt));

    if height(tt) > 0
        fprintf('  first %s = %g\n', string(tt.Time(1)), tt.(1)(1));
        fprintf('  last  %s = %g\n', string(tt.Time(end)), tt.(1)(end));

        % A timetable is the point of returning one: this all works directly.
        fprintf('  mean %g, std %g\n', mean(tt.(1)), std(tt.(1)));

        % Decimated. Ask the server for roughly this many points rather than
        % moving every sample — for a plot the difference is invisible.
        thinned = dataset.fetch(name, startTime, stopTime, Buckets=200);
        fprintf('  decimated to %d points\n', height(thinned));
    end

    % 3 ------------------------------------------- two channels together
    %
    % synchronize is why fetch returns timetables rather than raw arrays:
    % aligning two channels on independent clocks is one call.
    if height(channels) >= 2
        fprintf('\n--- Synchronize ---\n');
        a = dataset.fetch(channels.Name(1), startTime, stopTime, Buckets=100);
        b = dataset.fetch(channels.Name(2), startTime, stopTime, Buckets=100);
        both = synchronize(a, b);
        fprintf('%s + %s -> %d rows, %d variables\n', ...
                channels.Name(1), channels.Name(2), height(both), width(both));
    end

    % 4 ---------------------------------------------------------- export
    %
    % Same data as fetch, but one request and straight to disk. This is the
    % right tool for a wide window, and matfile is the default format.
    fprintf('\n--- Export ---\n');
    outFile = fullfile(pwd, "analysisdemo.mat");
    dataset.export(outFile, channels.Name', startTime, stopTime);
    info = dir(outFile);
    fprintf('Wrote %s (%.1f KB)\n', outFile, info.bytes / 1024);

    % A link instead of the bytes, for handing to something that is not MATLAB.
    try
        url = dataset.exportUrl(channels.Name(1), startTime, stopTime, ...
                                Format="csv");
        fprintf('Presigned CSV URL: %s...\n', extractBefore(url, min(60, strlength(url))));
    catch e
        % Some deployments have no export bucket configured.
        fprintf('exportUrl unavailable: %s\n', e.message);
    end

    % 5 ------------------------------------------------------------- SQL
    %
    % Timestamps arrive as int64 nanoseconds whatever the warehouse sent, so
    % convert the ones you want to read.
    fprintf('\n--- SQL ---\n');
    try
        runs = client.query("SELECT name, start_time FROM runs " + ...
                            "ORDER BY start_time DESC LIMIT 5");
        if height(runs) > 0 && any(strcmp(runs.Properties.VariableNames, 'start_time'))
            runs.start_time = nominal.fromNanos(runs.start_time);
        end
        disp(runs);
    catch e
        % The SQL service always needs a workspace, even where the rest of the
        % API does not — an unscoped client has to name one.
        fprintf('query failed: %s\n  %s\n', e.identifier, e.message);
    end

    % For a result too large to hold in memory, ask for a CSV download link
    % instead of the rows.
    %
    % Only queries reading telemetry tables can be exported this way — one
    % touching assets, runs, or datasets cannot — so the query below is the
    % same `runs` one and is expected to be refused. Substitute a telemetry
    % table from your own deployment to see it succeed; the call shape is what
    % this demonstrates.
    try
        link = client.queryExportUrl("SELECT name FROM runs LIMIT 1000");
        fprintf('CSV export URL: %s...\n', extractBefore(link, min(60, strlength(link))));
    catch e
        fprintf('queryExportUrl declined (expected for `runs`): %s\n', e.identifier);
    end

    % 6 -------------------------------------------------------- teardown
    delete(dataset);
    delete(client);
    fprintf('\nDone.\n');
end

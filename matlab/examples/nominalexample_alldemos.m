function nominalexample_alldemos()
%NOMINALEXAMPLE_ALLDEMOS  Run every demo against one throwaway asset.
%
%   Needs credentials. Creates a single asset named
%   nominal-matlab-demo-<timestamp> and runs all seven demos against it, so
%   everything lands in one place rather than scattered across seven assets.
%
%   Order matters: the write demos run first, then streaming, then analysis
%   last so it has something to read back.
%
%   Each demo also runs standalone; see their own help. This exists to
%   exercise the whole surface in one go after a rebuild.
%
%   See also NOMINALEXAMPLE_ASSETDEMO, NOMINALEXAMPLE_DATASETDEMO,
%   NOMINALEXAMPLE_RUNDEMO, NOMINALEXAMPLE_EVENTDEMO,
%   NOMINALEXAMPLE_UPLOADDEMO, NOMINALEXAMPLE_STREAMDEMO,
%   NOMINALEXAMPLE_ANALYSISDEMO, NOMINALEXAMPLE_CONNECT

    % Fail here rather than five demos in, if the credentials are not set up.
    delete(nominalexample_connect());

    assetName = "nominal-matlab-demo-" + string(posixtime(datetime("now")));
    fprintf('Shared asset: %s\n\n', assetName);

    % Three columns: the label for the banner, the base-workspace variable the
    % demo publishes, and a nullary handle that runs it. The middle one is
    % tracked so the summary at the end lists only what actually landed — a
    % demo that failed published nothing.
    demosNeedingOnlyAnAsset = {
        "assets",   "nominalAsset",   @() nominalexample_assetdemo(assetName)
        "datasets", "nominalDataset", @() nominalexample_datasetdemo(assetName)
        "runs",     "nominalRun",     @() nominalexample_rundemo(assetName)
        "events",   "nominalEvents",  @() nominalexample_eventdemo(assetName)
        "upload",   "nominalUpload",  @() nominalexample_uploaddemo(assetName)
    };

    failedDemoNames = strings(1, 0);
    publishedNames = strings(1, 0);

    [failedDemoNames, publishedNames] = ...
        runAll(demosNeedingOnlyAnAsset, failedDemoNames, publishedNames);

    % Streaming and analysis both need a dataset RID. The dataset demo made one
    % under the shared asset; look it up rather than hard-coding one.
    sharedDatasetRid = "";
    try
        client = nominalexample_connect();
        asset = client.getOrCreateAsset(assetName);

        % Refresh=true because this handle was fetched after the write demos
        % ran, but an asset handle is a snapshot — and the demos above
        % attached three datasets between them.
        %
        % datasources() lists videos and connections too, and only a dataset
        % RID can open a stream.
        dataSources = asset.datasources(Refresh=true);
        attachedDatasets = dataSources(dataSources.Type == "dataset", :);

        % Preference order, best story first. Data sources come back sorted by
        % reference name, so without this the choice is just alphabetical.
        %
        %   uploaded  500 rows written by the upload demo, with units declared
        %             on every channel, and all of them numeric
        %   ingested  the CSV — real data, but no units
        %   tlm       units declared but nothing written to those channels;
        %             the streamed demo.* points land here eventually, though
        %             not reliably before this runs. It also carries a string
        %             channel, which nothing downstream can fetch
        %
        % Both of the later two have shown up as an empty or failed analysis
        % run, which is why the order is explicit rather than incidental.
        for refName = ["uploaded" "ingested" "tlm"]
            match = attachedDatasets(attachedDatasets.RefName == refName, :);
            if ~isempty(match)
                sharedDatasetRid = match.Rid(1);
                break
            end
        end
        if sharedDatasetRid == "" && ~isempty(attachedDatasets)
            sharedDatasetRid = attachedDatasets.Rid(1);
        end

        delete(asset);
        delete(client);
    catch lookupError
        fprintf('  could not find a dataset: %s\n', lookupError.message);
    end

    % These two take a dataset rather than an asset, so they run outside the
    % loop above. Analysis goes last, so it reads back what the rest wrote.
    demosNeedingADataset = {
        "streaming", "nominalStream",   @() nominalexample_streamdemo(sharedDatasetRid)
        "analysis",  "nominalAnalysis", @() nominalexample_analysisdemo(sharedDatasetRid)
    };

    skippedDemoNames = strings(1, 0);
    if sharedDatasetRid == ""
        for demoIndex = 1:size(demosNeedingADataset, 1)
            banner(demosNeedingADataset{demoIndex, 1});
            fprintf('  skipped: no dataset on the asset\n\n');
            skippedDemoNames(end+1) = demosNeedingADataset{demoIndex, 1}; %#ok<AGROW>
        end
    else
        [failedDemoNames, publishedNames] = ...
            runAll(demosNeedingADataset, failedDemoNames, publishedNames);
    end

    % A skip is not a pass. Reporting "all demos completed" after quietly
    % running five of seven is how a broken client looks healthy — which is
    % exactly what it did before this was tracked.
    if isempty(failedDemoNames) && isempty(skippedDemoNames)
        fprintf('All demos completed.\n');
    else
        if ~isempty(failedDemoNames)
            fprintf('Failed:  %s\n', join(failedDemoNames, ", "));
        end
        if ~isempty(skippedDemoNames)
            fprintf('Skipped: %s\n', join(skippedDemoNames, ", "));
        end
        fprintf('Completed %d of %d.\n', ...
                7 - numel(failedDemoNames) - numel(skippedDemoNames), 7);
    end
    fprintf('Asset: %s\n', assetName);

    % Only what actually landed: a demo that failed published nothing, and
    % naming a variable that is not there sends you looking for a bug.
    if ~isempty(publishedNames)
        fprintf('\nIn the base workspace: %s\n', join(publishedNames, "  "));
    end

    % Not normally needed — the mexAtExit hook does this on `clear mex` or
    % exit. Called here so a full run ends with the worker threads stopped and
    % every handle released, which is what you want before a rebuild.
    %
    % The base-workspace structs survive it: they are plain data, already
    % copied out of the library's handles.
    nominal.shutdown();
end

function [failed, published] = runAll(demos, failed, published)
%RUNALL  Run a table of demos, recording which failed and which published.
%
%   Columns are label, base-workspace variable, and a nullary handle. Each
%   demo publishes its own results, so nothing is collected here — only the
%   name is noted, and only when the demo got far enough to write it.

    for demoIndex = 1:size(demos, 1)
        label = demos{demoIndex, 1};
        variableName = demos{demoIndex, 2};
        runDemo = demos{demoIndex, 3};

        banner(label);
        try
            runDemo();
            published(end+1) = variableName; %#ok<AGROW>
        catch demoError
            fprintf('\n  FAILED: %s\n  %s\n', demoError.identifier, demoError.message);
            failed(end+1) = label; %#ok<AGROW>
        end
        fprintf('\n');
    end
end

function banner(name)
    fprintf('%s\n=== %s %s\n', repmat('=', 1, 60), name, repmat('=', 1, 50 - strlength(name)));
end

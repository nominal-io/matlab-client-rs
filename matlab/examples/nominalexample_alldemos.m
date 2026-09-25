function nominalexample_alldemos()
%NOMINALEXAMPLE_ALLDEMOS  Run every demo against one throwaway asset.
%
%   Needs credentials. Creates one asset named nominal-matlab-demo-<timestamp>
%   and runs all seven demos against it. The write demos run first, then
%   streaming, then analysis last so it has something to read back.
%
%   Each demo also runs standalone; see their own help.
%
%   See also NOMINALEXAMPLE_ASSETDEMO, NOMINALEXAMPLE_DATASETDEMO,
%   NOMINALEXAMPLE_RUNDEMO, NOMINALEXAMPLE_EVENTDEMO,
%   NOMINALEXAMPLE_UPLOADDEMO, NOMINALEXAMPLE_STREAMDEMO,
%   NOMINALEXAMPLE_ANALYSISDEMO, NOMINALEXAMPLE_CONNECT

    % Fail early if credentials are not set up.
    delete(nominalexample_connect());

    assetName = "nominal-matlab-demo-" + string(posixtime(datetime("now")));
    fprintf('Shared asset: %s\n\n', assetName);

    % Columns: banner label, the base-workspace variable the demo publishes,
    % and a handle that runs it.
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

    % Streaming and analysis need a dataset RID. Look one up on the shared asset.
    sharedDatasetRid = "";
    try
        client = nominalexample_connect();
        asset = client.getOrCreateAsset(assetName);

        % An asset handle is a snapshot; Refresh=true picks up the datasets the
        % demos above attached. datasources() also lists videos and
        % connections, and only a dataset RID can open a stream.
        dataSources = asset.datasources(Refresh=true);
        attachedDatasets = dataSources(dataSources.Type == "dataset", :);

        % Preference order: "uploaded" has 500 numeric rows with units,
        % "ingested" has data but no units, "tlm" has units but may hold no
        % data yet and includes a string channel.
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

    % These two take a dataset RID. Analysis goes last so it reads back what
    % the rest wrote.
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

    % Skipped demos are reported separately; they do not count as passed.
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

    % A demo that failed published nothing, so list only what landed.
    if ~isempty(publishedNames)
        fprintf('\nIn the base workspace: %s\n', join(publishedNames, "  "));
    end

    % Not normally needed; `clear mex` or exit does this. Called here so a full
    % run ends with worker threads stopped and every handle released. The
    % base-workspace structs are plain data and survive it.
    nominal.shutdown();
end

function [failed, published] = runAll(demos, failed, published)
%RUNALL  Run a table of demos, recording which failed and which published.
%
%   Each demo publishes its own results; only the variable name is noted
%   here, and only when the demo completed.

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

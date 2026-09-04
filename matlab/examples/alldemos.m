function alldemos()
%ALLDEMOS  Run every demo against one throwaway asset.
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
%   See also ASSETDEMO, DATASETDEMO, RUNDEMO, EVENTDEMO, UPLOADDEMO,
%   STREAMDEMO, ANALYSISDEMO, NOMINALCONNECT

    % Fail here rather than five demos in, if the credentials are not set up.
    delete(nominalconnect());

    assetName = "nominal-matlab-demo-" + string(posixtime(datetime("now")));
    fprintf('Shared asset: %s\n\n', assetName);

    % Three columns: the label for the banner, the base-workspace variable the
    % demo publishes, and a nullary handle that runs it. The middle one is
    % tracked so the summary at the end lists only what actually landed — a
    % demo that failed published nothing.
    demosNeedingOnlyAnAsset = {
        "assets",   "nominalAsset",   @() assetdemo(assetName)
        "datasets", "nominalDataset", @() datasetdemo(assetName)
        "runs",     "nominalRun",     @() rundemo(assetName)
        "events",   "nominalEvents",  @() eventdemo(assetName)
        "upload",   "nominalUpload",  @() uploaddemo(assetName)
    };

    failedDemoNames = strings(1, 0);
    publishedNames = strings(1, 0);

    [failedDemoNames, publishedNames] = ...
        runAll(demosNeedingOnlyAnAsset, failedDemoNames, publishedNames);

    % Streaming and analysis both need a dataset RID, which datasetdemo created
    % under the shared asset. Look it up rather than hard-coding one.
    sharedDatasetRid = "";
    try
        client = nominalconnect();
        asset = client.getOrCreateAsset(assetName);

        % datasources() lists videos and connections too, and only a dataset
        % RID can open a stream.
        dataSources = asset.datasources();
        attachedDatasets = dataSources(dataSources.Type == "dataset", :);
        if ~isempty(attachedDatasets)
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
        "streaming", "nominalStream",   @() streamdemo(sharedDatasetRid)
        "analysis",  "nominalAnalysis", @() analysisdemo(sharedDatasetRid)
    };

    if sharedDatasetRid == ""
        for demoIndex = 1:size(demosNeedingADataset, 1)
            banner(demosNeedingADataset{demoIndex, 1});
            fprintf('  skipped: no dataset on the asset\n\n');
        end
    else
        [failedDemoNames, publishedNames] = ...
            runAll(demosNeedingADataset, failedDemoNames, publishedNames);
    end

    if isempty(failedDemoNames)
        fprintf('All demos completed.\n');
    else
        fprintf('Failed: %s\n', join(failedDemoNames, ", "));
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

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
%   STREAMDEMO, ANALYSISDEMO, CONNECT

    % Fail here rather than five demos in, if the credentials are not set up.
    delete(connect());

    assetName = "nominal-matlab-demo-" + string(posixtime(datetime("now")));
    fprintf('Shared asset: %s\n\n', assetName);

    % Name paired with a nullary handle that runs it, so the loop below reports
    % which one failed without parsing anything out of the error.
    demosNeedingOnlyAnAsset = {
        "assets",   @() assetdemo(assetName)
        "datasets", @() datasetdemo(assetName)
        "runs",     @() rundemo(assetName)
        "events",   @() eventdemo(assetName)
        "upload",   @() uploaddemo(assetName)
    };

    failedDemoNames = strings(1, 0);
    for demoIndex = 1:size(demosNeedingOnlyAnAsset, 1)
        demoName = demosNeedingOnlyAnAsset{demoIndex, 1};
        runDemo = demosNeedingOnlyAnAsset{demoIndex, 2};

        banner(demoName);
        try
            runDemo();
        catch demoError
            fprintf('\n  FAILED: %s\n  %s\n', demoError.identifier, demoError.message);
            failedDemoNames(end+1) = demoName; %#ok<AGROW>
        end
        fprintf('\n');
    end

    % Streaming and analysis both need a dataset RID, which datasetdemo created
    % under the shared asset. Look it up rather than hard-coding one.
    sharedDatasetRid = "";
    try
        client = connect();
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
        "streaming", @() streamdemo(sharedDatasetRid)
        "analysis",  @() analysisdemo(sharedDatasetRid)
    };

    for demoIndex = 1:size(demosNeedingADataset, 1)
        demoName = demosNeedingADataset{demoIndex, 1};
        runDemo = demosNeedingADataset{demoIndex, 2};

        banner(demoName);
        if sharedDatasetRid == ""
            fprintf('  skipped: no dataset on the asset\n\n');
            continue
        end
        try
            runDemo();
        catch demoError
            fprintf('\n  FAILED: %s\n  %s\n', demoError.identifier, demoError.message);
            failedDemoNames(end+1) = demoName; %#ok<AGROW>
        end
        fprintf('\n');
    end

    if isempty(failedDemoNames)
        fprintf('All demos completed.\n');
    else
        fprintf('Failed: %s\n', join(failedDemoNames, ", "));
    end
    fprintf('Asset: %s\n', assetName);

    % Not normally needed — the mexAtExit hook does this on `clear mex` or
    % exit. Called here so a full run ends with the worker threads stopped and
    % every handle released, which is what you want before a rebuild.
    nominal.shutdown();
end

function banner(name)
    fprintf('%s\n=== %s %s\n', repmat('=', 1, 60), name, repmat('=', 1, 50 - strlength(name)));
end

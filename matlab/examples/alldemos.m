function alldemos()
%ALLDEMOS  Run every demo against one throwaway asset.
%
%   Needs NOMINAL_TOKEN. Creates a single asset named
%   nominal-matlab-demo-<timestamp> and runs each demo against it, so
%   everything ends up in one place rather than scattered across four assets.
%
%   Each demo also runs standalone; see their own help. This exists to
%   exercise the whole surface in one go after a rebuild.
%
%   See also ASSETDEMO, DATASETDEMO, RUNDEMO, EVENTDEMO, STREAMDEMO

    token = string(getenv("NOMINAL_TOKEN"));
    if token == ""
        error('nominal:demo', 'set NOMINAL_TOKEN in the environment');
    end

    assetName = "nominal-matlab-demo-" + string(posixtime(datetime("now")));
    fprintf('Shared asset: %s\n\n', assetName);

    demos = {
        "assets",   @() assetdemo(assetName)
        "datasets", @() datasetdemo(assetName)
        "runs",     @() rundemo(assetName)
        "events",   @() eventdemo(assetName)
    };

    failures = strings(1, 0);
    for i = 1:size(demos, 1)
        name = demos{i, 1};
        banner(name);
        try
            demos{i, 2}();
        catch e
            fprintf('\n  FAILED: %s\n  %s\n', e.identifier, e.message);
            failures(end+1) = name; %#ok<AGROW>
        end
        fprintf('\n');
    end

    % Streaming needs a dataset RID, which datasetdemo created under the shared
    % asset. Look it up rather than hard-coding one.
    banner("streaming");
    try
        client = nominal.Client(token);
        asset = client.asset(assetName);
        sources = asset.datasources();
        datasets = sources(strcmp({sources.Type}, 'dataset'));
        if isempty(datasets)
            fprintf('  skipped: no dataset on the asset\n');
        else
            delete(asset);
            delete(client);
            streamdemo(string(datasets(1).Rid));
        end
    catch e
        fprintf('\n  FAILED: %s\n  %s\n', e.identifier, e.message);
        failures(end+1) = "streaming";
    end

    fprintf('\n');
    if isempty(failures)
        fprintf('All demos completed.\n');
    else
        fprintf('Failed: %s\n', join(failures, ", "));
    end
    fprintf('Asset: %s\n', assetName);
end

function banner(name)
    fprintf('%s\n=== %s %s\n', repmat('=', 1, 60), name, repmat('=', 1, 50 - strlength(name)));
end

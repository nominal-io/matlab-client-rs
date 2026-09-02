function assetdemo(assetName)
%ASSETDEMO  Exercise every asset operation.
%
%   assetdemo                    % uses a timestamped throwaway name
%   assetdemo("engine-3")        % an existing asset
%
%   Needs NOMINAL_TOKEN. With no argument this creates a new asset named
%   nominal-matlab-demo-<timestamp>, so it is safe to run repeatedly; pass a
%   name to work against something that already exists.
%
%   Covers: get-or-create, get by RID, metadata update, all accessors, and
%   listing attached data sources.
%
%   See also NOMINAL.ASSET, DATASETDEMO, RUNDEMO, EVENTDEMO

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = connect();

    % --- get or create ------------------------------------------------
    %
    % Name is not unique in Nominal, so this returns the first exact match and
    % only creates when there is none.
    fprintf('Asset "%s"\n', assetName);
    asset = client.getOrCreateAsset(assetName);
    fprintf('  rid  %s\n', asset.Rid);
    fprintf('  url  %s\n', asset.Url);

    % --- fetch the same asset by RID ----------------------------------
    %
    % Two handles onto the same asset. They are independent objects; releasing
    % one does not affect the other.
    again = client.assetByRid(asset.Rid);
    fprintf('  refetched by rid, name matches: %d\n', again.Name == asset.Name);

    % --- update -------------------------------------------------------
    %
    % Collections replace rather than merge. Passing Labels at all discards
    % whatever the asset had, so read them first if you mean to add.
    existing = asset.Labels;
    fprintf('  labels before: %s\n', join(["(none)" existing], " "));

    updated = asset.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = unique([existing, "matlab-demo"]), ...
        Properties  = struct(source = "assetdemo", language = "matlab"));

    fprintf('  labels after:  %s\n', join(updated.Labels, " "));
    fprintf('  description:   %s\n', updated.Description);
    fprintf('  property source = %s\n', updated.property("source"));

    % The original handle still shows the pre-update state — update returns a
    % new object rather than mutating in place.
    fprintf('  original handle still shows: "%s"\n', asset.Description);

    % --- attached data sources ----------------------------------------
    %
    % Type matters: only a dataset RID can open a stream, so the kind tells
    % you what an endpoint will accept.
    sources = updated.datasources();
    fprintf('  %d data source(s) attached\n', height(sources));
    if ~isempty(sources)
        disp(sources);
    end

    % --- teardown -----------------------------------------------------
    delete(updated);
    delete(again);
    delete(asset);
    delete(client);
    fprintf('Done.\n');
end

function client = connect()
    token = string(getenv("NOMINAL_TOKEN"));
    if token == ""
        error('nominal:demo', 'set NOMINAL_TOKEN in the environment');
    end
    client = nominal.Client(token);
    fprintf('Connected as %s\n', client.whoAmI());
end

function results = nominalexample_assetdemo(assetName)
%NOMINALEXAMPLE_ASSETDEMO  Exercise every asset operation.
%
%   nominalexample_assetdemo                 % timestamped throwaway name
%   nominalexample_assetdemo("engine-3")     % an existing asset
%
%   Needs credentials. With no argument this creates a new asset named
%   nominal-matlab-demo-<timestamp>, so it is safe to run repeatedly; pass a
%   name to work against something that already exists.
%
%   Covers: get-or-create, get by RID, metadata update, all accessors, and
%   listing attached data sources.
%
%   See also NOMINAL.ASSET, NOMINALEXAMPLE_DATASETDEMO,
%   NOMINALEXAMPLE_RUNDEMO, NOMINALEXAMPLE_EVENTDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalexample_connect();

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
    sameAssetByRid = client.assetByRid(asset.Rid);
    fprintf('  refetched by rid, name matches: %d\n', ...
            sameAssetByRid.Name == asset.Name);

    % --- update -------------------------------------------------------
    %
    % Collections replace rather than merge. Passing Labels at all discards
    % whatever the asset had, so read them first if you mean to add.
    labelsBefore = asset.Labels;
    if isempty(labelsBefore)
        fprintf('  labels before: (none)\n');
    else
        fprintf('  labels before: %s\n', join(labelsBefore, " "));
    end

    updatedAsset = asset.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = unique([labelsBefore, "matlab-demo"]), ...
        Properties  = struct(source = "nominalexample_assetdemo", language = "matlab"));

    fprintf('  labels after:  %s\n', join(updatedAsset.Labels, " "));
    fprintf('  description:   %s\n', updatedAsset.Description);
    fprintf('  property source = %s\n', updatedAsset.property("source"));

    % The original handle still shows the pre-update state — update returns a
    % new object rather than mutating in place.
    fprintf('  original handle still shows: "%s"\n', asset.Description);

    % --- attached data sources ----------------------------------------
    %
    % Type matters: only a dataset RID can open a stream, so the kind tells
    % you what an endpoint will accept.
    dataSources = updatedAsset.datasources();
    fprintf('  %d data source(s) attached\n', height(dataSources));
    if ~isempty(dataSources)
        disp(dataSources);
    end

    % --- results ------------------------------------------------------
    %
    % Read off the updated handle while it is still live: the objects are
    % released below, and a released one reports nothing.
    results = struct( ...
        'Rid',         updatedAsset.Rid, ...
        'Name',        updatedAsset.Name, ...
        'Description', updatedAsset.Description, ...
        'Url',         updatedAsset.Url, ...
        'Labels',      updatedAsset.Labels, ...
        'DataSources', dataSources);

    % --- teardown -----------------------------------------------------
    delete(updatedAsset);
    delete(sameAssetByRid);
    delete(asset);
    delete(client);

    nominalexample_publish(results, "nominalAsset");
end

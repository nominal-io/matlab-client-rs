function results = nominalexample_assetdemo(assetName)
%NOMINALEXAMPLE_ASSETDEMO  Exercise every asset operation.
%
%   nominalexample_assetdemo                 % timestamped throwaway name
%   nominalexample_assetdemo("engine-3")     % an existing asset
%
%   Needs credentials. With no argument this creates a new asset named
%   nominal-matlab-demo-<timestamp>; pass a name to use an existing asset.
%
%   Covers: get-or-create, get by RID, metadata update, accessors, and
%   listing attached data sources. Publishes results as nominalAsset.
%
%   See also NOMINAL.ASSET, NOMINALEXAMPLE_DATASETDEMO,
%   NOMINALEXAMPLE_RUNDEMO, NOMINALEXAMPLE_EVENTDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalexample_connect();

    % --- get or create ------------------------------------------------
    %
    % Name is not unique in Nominal. This returns the first exact match and
    % creates only when there is none.
    fprintf('Asset "%s"\n', assetName);
    asset = client.getOrCreateAsset(assetName);
    fprintf('  rid  %s\n', asset.Rid);
    fprintf('  url  %s\n', asset.Url);

    % --- fetch the same asset by RID ----------------------------------
    %
    % Two handles on the same asset are independent objects.
    sameAssetByRid = client.assetByRid(asset.Rid);
    fprintf('  refetched by rid, name matches: %d\n', ...
            sameAssetByRid.Name == asset.Name);

    % --- update -------------------------------------------------------
    %
    % Labels and Properties replace, not merge. Read them first if you mean
    % to add.
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

    % update returns a new object; the original handle still shows the old
    % state.
    fprintf('  original handle still shows: "%s"\n', asset.Description);

    % --- attached data sources ----------------------------------------
    %
    % Check the Type column: only a dataset RID can open a stream. Use
    % datasources(Refresh=true) to see datasets attached after the handle
    % was fetched.
    dataSources = updatedAsset.datasources();
    fprintf('  %d data source(s) attached\n', height(dataSources));
    if ~isempty(dataSources)
        disp(dataSources);
    end

    % --- results ------------------------------------------------------
    %
    % Copy out before the handles are released below.
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

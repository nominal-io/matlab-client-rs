function results = nominalexample_assetdemo(assetName)
%NOMINALEXAMPLE_ASSETDEMO  Exercise every asset operation.
%
%   nominalexample_assetdemo                 % timestamped throwaway name
%   nominalexample_assetdemo("engine-3")     % an existing asset
%
%   Needs credentials. With no argument this creates a new asset named
%   nominal-matlab-demo-<timestamp>; pass a name to use an existing asset.
%
%   Covers: get-or-create, get by RID, metadata update, accessors, a
%   standalone dataset attached twice split by tag, renaming and detaching,
%   and listing attached data sources. Publishes results as nominalAsset.
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

    % --- one dataset, attached twice, split by tag ---------------------
    %
    % createDataset makes a dataset attached to nothing. Each addDataset then
    % shows only the series carrying its tags. A struct holds keys that are
    % valid field names; a dictionary holds any key. write stamps the same
    % tags on points.
    dataset = client.createDataset("assetdemo shared");
    updatedAsset.addDataset(dataset, "unit-a", Tags=struct(UUT="A"));
    updatedAsset.addDataset(dataset, "unit-b", ...
                            Tags=dictionary(["UUT" "test-stand"], ["B" "3"]));
    dataset.write("rpm", datetime("now", TimeZone="UTC"), 1500, Tags=struct(UUT="A"));

    attachedByName = updatedAsset.getAttachedDataset("assetdemo shared");
    fprintf('  "%s" found by name, same RID: %d\n', ...
            attachedByName.Name, attachedByName.Rid == dataset.Rid);
    fprintf('  held by %d asset(s)\n', height(dataset.assets()));

    % Workbooks using the asset follow a rename.
    updatedAsset.renameRefName("unit-b", "bench-b");

    % --- attached data sources ----------------------------------------
    %
    % Check the Type column: only a dataset RID can open a stream.
    % Refresh=true because this handle predates the attachments above.
    dataSources = updatedAsset.datasources(Refresh=true);
    fprintf('  "%s" attached as: %s\n', dataset.Name, ...
            join(dataSources.RefName(dataSources.Rid == dataset.Rid)', ", "));
    fprintf('  %d data source(s) attached\n', height(dataSources));
    if ~isempty(dataSources)
        disp(dataSources);
    end

    % --- detach -------------------------------------------------------
    %
    % Leaves the asset as it was found. The dataset itself is untouched.
    updatedAsset.removeDataset("unit-a");
    updatedAsset.removeDataset("bench-b");
    fprintf('  detached; %d data source(s) left\n', ...
            height(updatedAsset.datasources(Refresh=true)));

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
    delete(attachedByName);
    delete(dataset);
    delete(updatedAsset);
    delete(sameAssetByRid);
    delete(asset);
    delete(client);

    nominalexample_publish(results, "nominalAsset");
end

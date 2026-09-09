function results = nominalexample_datasetdemo(assetName)
%NOMINALEXAMPLE_DATASETDEMO  Exercise dataset operations and channel metadata.
%
%   nominalexample_datasetdemo               % throwaway asset and dataset
%   nominalexample_datasetdemo("engine-3")   % under an existing asset
%
%   Needs credentials. Creates a dataset under the asset, attaches units to
%   channels before any data exists, then lists what the dataset holds.
%
%   Covers: get-or-create under an asset, get by RID, update, channel metadata
%   read and write, and listing every channel.
%
%   See also NOMINAL.DATASET, NOMINAL.CHANNELMETADATA,
%   NOMINALEXAMPLE_ASSETDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalexample_connect();
    asset = client.getOrCreateAsset(assetName);
    fprintf('Asset: %s\n', asset.Name);

    % --- get or create a dataset under the asset ----------------------
    %
    % refName is how this dataset is addressed within the asset, and must be
    % unique among its data sources.
    %
    % AttachExisting=false because this demo wants its own data. Left on, a
    % dataset called "telemetry" belonging to someone else would be adopted
    % onto this throwaway asset — sensible for real work, wrong for a demo
    % that then writes to it. See nominal.Asset.getOrCreateDataset.
    dataset = asset.getOrCreateDataset("telemetry", "tlm", AttachExisting=false);
    fprintf('Dataset "%s"\n  rid %s\n', dataset.Name, dataset.Rid);

    % --- fetch the same dataset by RID --------------------------------
    sameDatasetByRid = client.datasetByRid(dataset.Rid);
    fprintf('  refetched by rid, name matches: %d\n', ...
            sameDatasetByRid.Name == dataset.Name);

    % --- update -------------------------------------------------------
    %
    % update returns a new object rather than mutating in place, so everything
    % after this point works against updatedDataset.
    updatedDataset = dataset.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = "matlab-demo");
    fprintf('  description: %s\n', updatedDataset.Description);

    % --- channel metadata, before any data exists ---------------------
    %
    % This is an upsert, so units can be attached ahead of a stream or upload
    % ever writing a point. That is the usual reason to call it: a downstream
    % workbook wants units on day one.
    %
    % The data type is required and always sent — the API has no way to leave
    % it alone, so naming the wrong one re-declares the channel.
    fprintf('Attaching units...\n');

    % A struct keyed by channel name, so the loop below stays a single pass.
    % Units are UCUM symbols: "Cel" rather than "C", which UCUM reserves for
    % coulomb, and "1/min" rather than "rpm", which UCUM does not define.
    unitByChannelName = struct( ...
        rpm = "1/min", ...
        egt = "Cel", ...
        psi = "kPa");

    numericChannelNames = string(fieldnames(unitByChannelName))';
    for channelName = numericChannelNames
        channelMetadata = updatedDataset.setChannelMetadata( ...
            channelName, "double", ...
            Unit = unitByChannelName.(channelName), ...
            Description = "demo channel " + channelName);

        fprintf('  %-6s %-6s %s\n', channelMetadata.Name, ...
                channelMetadata.Unit, channelMetadata.Description);
        delete(channelMetadata);
    end

    % A string channel, to show a non-numeric data type. Units make no sense
    % here, so none is set.
    modeMetadata = updatedDataset.setChannelMetadata("mode", "string", ...
                                                     Description = "vehicle mode");
    fprintf('  %-6s %-6s %s\n', modeMetadata.Name, "(none)", ...
            modeMetadata.Description);
    delete(modeMetadata);

    % --- read one back ------------------------------------------------
    %
    % Worth doing rather than trusting what setChannelMetadata returned: that
    % object is built from what you sent, not from what the server holds, so
    % it omits fields you did not set.
    refetchedMetadata = updatedDataset.channelMetadata("rpm");
    fprintf('Read back "rpm": unit=%s type=%s\n', ...
            refetchedMetadata.Unit, refetchedMetadata.DataType);
    delete(refetchedMetadata);

    % --- list every channel -------------------------------------------
    channelTable = updatedDataset.channels();
    fprintf('%d channel(s) in the dataset:\n', height(channelTable));
    if ~isempty(channelTable)
        disp(channelTable);
    end

    % --- results ------------------------------------------------------
    results = struct( ...
        'Rid',         updatedDataset.Rid, ...
        'Name',        updatedDataset.Name, ...
        'Description', updatedDataset.Description, ...
        'Labels',      updatedDataset.Labels, ...
        'Channels',    channelTable);

    % --- teardown -----------------------------------------------------
    delete(updatedDataset);
    delete(sameDatasetByRid);
    delete(dataset);
    delete(asset);
    delete(client);

    nominalexample_publish(results, "nominalDataset");
end

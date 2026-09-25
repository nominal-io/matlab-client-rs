function results = nominalexample_datasetdemo(assetName)
%NOMINALEXAMPLE_DATASETDEMO  Exercise dataset operations and channel metadata.
%
%   nominalexample_datasetdemo               % throwaway asset and dataset
%   nominalexample_datasetdemo("engine-3")   % under an existing asset
%
%   Needs credentials. Creates a dataset under the asset, sets channel units
%   before any data exists, then lists the channels. Publishes results as
%   nominalDataset.
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
    % refName addresses the dataset within the asset and must be unique among
    % its data sources.
    %
    % AttachExisting=false: this demo writes data, so it must not adopt an
    % existing "telemetry" dataset belonging to someone else. Leave it on for
    % real work. See nominal.Asset.getOrCreateDataset.
    dataset = asset.getOrCreateDataset("telemetry", "tlm", AttachExisting=false);
    fprintf('Dataset "%s"\n  rid %s\n', dataset.Name, dataset.Rid);

    % --- fetch the same dataset by RID --------------------------------
    sameDatasetByRid = client.datasetByRid(dataset.Rid);
    fprintf('  refetched by rid, name matches: %d\n', ...
            sameDatasetByRid.Name == dataset.Name);

    % --- update -------------------------------------------------------
    %
    % update returns a new object; everything below uses updatedDataset.
    updatedDataset = dataset.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = "matlab-demo");
    fprintf('  description: %s\n', updatedDataset.Description);

    % --- channel metadata, before any data exists ---------------------
    %
    % setChannelMetadata is an upsert and works before any data exists. The
    % data type is always sent, so a wrong one re-declares the channel.
    fprintf('Attaching units...\n');

    % Units are UCUM symbols: "Cel" not "C", "1/min" not "rpm".
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

    % A string channel; no unit.
    modeMetadata = updatedDataset.setChannelMetadata("mode", "string", ...
                                                     Description = "vehicle mode");
    fprintf('  %-6s %-6s %s\n', modeMetadata.Name, "(none)", ...
            modeMetadata.Description);
    delete(modeMetadata);

    % --- read one back ------------------------------------------------
    %
    % The object setChannelMetadata returns reflects what you sent, not what
    % the server holds. Read back to see the server's view.
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

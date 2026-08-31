function datasetdemo(assetName)
%DATASETDEMO  Exercise dataset operations and channel metadata.
%
%   datasetdemo                  % throwaway asset and dataset
%   datasetdemo("engine-3")      % under an existing asset
%
%   Needs NOMINAL_TOKEN. Creates a dataset under the asset, attaches units to
%   channels before any data exists, then lists what the dataset holds.
%
%   Covers: get-or-create under an asset, get by RID, update, channel metadata
%   read and write, and listing every channel.
%
%   See also NOMINAL.DATASET, NOMINAL.CHANNELMETADATA, ASSETDEMO, STREAMDEMO

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = connect();
    asset = client.asset(assetName);
    fprintf('Asset: %s\n', asset.Name);

    % --- get or create a dataset under the asset ----------------------
    %
    % refName is how this dataset is addressed within the asset, and must be
    % unique among its data sources. An existing dataset is returned as-is
    % rather than re-attached.
    dataset = asset.dataset("telemetry", "tlm");
    fprintf('Dataset "%s"\n  rid %s\n', dataset.Name, dataset.Rid);

    % --- fetch the same dataset by RID --------------------------------
    again = client.datasetByRid(dataset.Rid);
    fprintf('  refetched by rid, name matches: %d\n', again.Name == dataset.Name);

    % --- update -------------------------------------------------------
    updated = dataset.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = "matlab-demo");
    fprintf('  description: %s\n', updated.Description);

    % --- channel metadata, before any data exists ---------------------
    %
    % This is an upsert, so units can be attached ahead of a stream or upload
    % ever writing a point. That is the usual reason to call it: a downstream
    % workbook wants units on day one.
    %
    % The data type is required and always sent — the API has no way to leave
    % it alone, so naming the wrong one re-declares the channel.
    fprintf('Attaching units...\n');
    units = struct( ...
        rpm = "1/min", ...
        egt = "Cel", ...
        psi = "kPa");

    names = string(fieldnames(units))';
    for name = names
        m = updated.setChannelMetadata(name, "double", ...
                                       Unit = units.(name), ...
                                       Description = "demo channel " + name);
        fprintf('  %-6s %-6s %s\n', m.Name, m.Unit, m.Description);
        delete(m);
    end

    % A string channel, to show a non-numeric data type.
    m = updated.setChannelMetadata("mode", "string", ...
                                   Description = "vehicle mode");
    fprintf('  %-6s %-6s %s\n', m.Name, "(none)", m.Description);
    delete(m);

    % --- read one back ------------------------------------------------
    %
    % Worth doing rather than trusting what setChannelMetadata returned: that
    % object is built from what you sent, not from what the server holds, so
    % it omits fields you did not set.
    fetched = updated.channelMetadata("rpm");
    fprintf('Read back "rpm": unit=%s type=%s\n', fetched.Unit, fetched.DataType);
    delete(fetched);

    % --- list every channel -------------------------------------------
    channels = updated.channels();
    fprintf('%d channel(s) in the dataset:\n', numel(channels));
    if ~isempty(channels)
        disp(struct2table(channels, AsArray=true));
    end

    % --- teardown -----------------------------------------------------
    delete(updated);
    delete(again);
    delete(dataset);
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

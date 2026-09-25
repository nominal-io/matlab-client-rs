function results = nominalexample_rundemo(assetName)
%NOMINALEXAMPLE_RUNDEMO  Exercise every run operation.
%
%   nominalexample_rundemo                   % throwaway asset
%   nominalexample_rundemo("engine-3")       % under an existing asset
%
%   Needs credentials. Creates an asset, a dataset, and a run over them, then
%   closes it.
%
%   Covers: create with an explicit start, get by RID, update, all accessors,
%   and finish. Not addDataset: a run's data sources are its asset's, so there
%   is nothing to attach.
%
%   See also NOMINAL.RUN, NOMINALEXAMPLE_ASSETDEMO,
%   NOMINALEXAMPLE_EVENTDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalexample_connect();
    asset = client.getOrCreateAsset(assetName);
    % AttachExisting=false so a demo asset does not adopt someone else's
    % existing "telemetry" dataset.
    dataset = asset.getOrCreateDataset("telemetry", "tlm", AttachExisting=false);
    fprintf('Asset %s / dataset %s\n', asset.Name, dataset.Name);

    % --- create -------------------------------------------------------
    %
    % Started a minute ago so the window covers data already written. Pass 0,
    % or omit the argument, to start now. (Unlike streaming timestamps, 0 here
    % means now, not the epoch.)
    %
    % Each mutation below returns a new object: openRun -> updatedRun ->
    % finishedRun. Earlier handles keep reporting their older state.
    runStartTime = datetime("now", TimeZone="UTC") - minutes(1);
    openRun = asset.run("matlab-demo-run", runStartTime);

    fprintf('Run "%s"\n', openRun.Name);
    fprintf('  rid    %s\n', openRun.Rid);
    fprintf('  number %d\n', openRun.Number);
    fprintf('  url    %s\n', openRun.Url);
    fprintf('  start  %s\n', string(openRun.StartTime));

    % An open run's EndTime is NaT. Test for it; fprintf cannot format
    % string(NaT).
    if isnat(openRun.EndTime)
        fprintf('  end    (none yet - the run is open)\n');
    else
        fprintf('  end    %s\n', string(openRun.EndTime));
    end

    % --- fetch by RID -------------------------------------------------
    sameRunByRid = client.runByRid(openRun.Rid);
    fprintf('  refetched by rid, number matches: %d\n', ...
            sameRunByRid.Number == openRun.Number);

    % --- the run's data ------------------------------------------------
    %
    % A run's data sources are its asset's, live. The dataset above is already
    % on the run, and so is anything attached to the asset later. Nothing needs
    % attaching, and nominal.Run.addDataset cannot succeed for a run made with
    % asset.run().
    fprintf('  data sources come from the asset; nothing to attach\n');

    % --- update -------------------------------------------------------
    %
    % update accepts start and end times as well as these metadata fields.
    % Collections replace, they do not merge.
    updatedRun = openRun.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = ["matlab-demo" "smoke"], ...
        Properties  = struct(operator = "matlab", phase = "demo"));

    fprintf('  description: %s\n', updatedRun.Description);
    fprintf('  labels:      %s\n', join(updatedRun.Labels, " "));
    fprintf('  operator:    %s\n', updatedRun.property("operator"));

    % --- close it -----------------------------------------------------
    %
    % No argument means end now.
    finishedRun = updatedRun.finish();
    fprintf('  end    %s (closed)\n', string(finishedRun.EndTime));
    fprintf('  span   %s\n', string(finishedRun.EndTime - finishedRun.StartTime));

    % --- results ------------------------------------------------------
    %
    % Read from finishedRun, the only handle that reflects every change.
    results = struct( ...
        'Rid',         finishedRun.Rid, ...
        'Name',        finishedRun.Name, ...
        'Number',      finishedRun.Number, ...
        'Url',         finishedRun.Url, ...
        'Description', finishedRun.Description, ...
        'Labels',      finishedRun.Labels, ...
        'StartTime',   finishedRun.StartTime, ...
        'EndTime',     finishedRun.EndTime, ...
        'DatasetRid',  dataset.Rid);

    % --- teardown -----------------------------------------------------
    %
    % Each handle in the chain needs its own delete.
    delete(finishedRun);
    delete(updatedRun);
    delete(sameRunByRid);
    delete(openRun);
    delete(dataset);
    delete(asset);
    delete(client);

    nominalexample_publish(results, "nominalRun");
end

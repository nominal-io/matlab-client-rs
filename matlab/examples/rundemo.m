function results = rundemo(assetName)
%RUNDEMO  Exercise every run operation.
%
%   rundemo                      % throwaway asset
%   rundemo("engine-3")          % under an existing asset
%
%   Needs credentials. Creates an asset, a dataset, and a run; attaches the
%   dataset to the run; then closes it.
%
%   Covers: create with an explicit start, get by RID, attach a dataset,
%   update including times, all accessors, and finish.
%
%   See also NOMINAL.RUN, ASSETDEMO, EVENTDEMO, NOMINALCONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalconnect();
    asset = client.getOrCreateAsset(assetName);
    dataset = asset.getOrCreateDataset("telemetry", "tlm");
    fprintf('Asset %s / dataset %s\n', asset.Name, dataset.Name);

    % --- create -------------------------------------------------------
    %
    % Started a minute ago so the window covers data already written. Pass 0,
    % or omit the argument, to start now instead. Unlike streaming timestamps,
    % 0 here means "now" rather than the epoch.
    %
    % Named openRun rather than "run" because that is a MATLAB builtin — the
    % one that executes a script — and shadowing it in a demo teaches a bad
    % habit to anyone copying from here.
    %
    % Every mutation below returns a *new* object rather than changing this
    % one, so the variables form a chain: openRun -> runWithDataset ->
    % updatedRun -> finishedRun. Each name says what has happened by that
    % point, and each earlier handle still reports its own older state.
    runStartTime = datetime("now", TimeZone="UTC") - minutes(1);
    openRun = asset.run("matlab-demo-run", runStartTime);

    fprintf('Run "%s"\n', openRun.Name);
    fprintf('  rid    %s\n', openRun.Rid);
    fprintf('  number %d\n', openRun.Number);
    fprintf('  url    %s\n', openRun.Url);
    fprintf('  start  %s\n', string(openRun.StartTime));

    % An open run has no end. EndTime reports NaT rather than erroring or
    % returning 0, which would be a real instant.
    %
    % Tested rather than printed: string(NaT) is a <missing> element, and
    % fprintf refuses to format one.
    if isnat(openRun.EndTime)
        fprintf('  end    (none yet - the run is open)\n');
    else
        fprintf('  end    %s\n', string(openRun.EndTime));
    end

    % --- fetch by RID -------------------------------------------------
    sameRunByRid = client.runByRid(openRun.Rid);
    fprintf('  refetched by rid, number matches: %d\n', ...
            sameRunByRid.Number == openRun.Number);

    % --- attach the dataset -------------------------------------------
    %
    % refName addresses the dataset within the run and must be unique among
    % its data sources — and a run created on an asset already carries that
    % asset's. This dataset went onto the asset as "tlm" a few lines up, so
    % reusing "tlm" here is a conflict (Scout:RefNamesAlreadyUsed) rather than
    % a re-attach. The run gets a reference name of its own.
    %
    % Wrapped because that conflict is a 409, not a no-op: a demo should
    % survive a deployment where the name is already spoken for.
    runWithDataset = openRun;
    try
        runWithDataset = openRun.addDataset("run-tlm", dataset);
        fprintf('  dataset attached to the run as "run-tlm"\n');
    catch attachError
        fprintf('  dataset not attached: %s\n', attachError.message);
    end

    % --- update -------------------------------------------------------
    %
    % Runs honour start and end times as well as the shared metadata fields.
    % Collections replace rather than merge.
    updatedRun = runWithDataset.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = ["matlab-demo" "smoke"], ...
        Properties  = struct(operator = "matlab", phase = "demo"));

    fprintf('  description: %s\n', updatedRun.Description);
    fprintf('  labels:      %s\n', join(updatedRun.Labels, " "));
    fprintf('  operator:    %s\n', updatedRun.property("operator"));

    % --- close it -----------------------------------------------------
    %
    % No argument means end now, which is the usual case at the end of a test.
    finishedRun = updatedRun.finish();
    fprintf('  end    %s (closed)\n', string(finishedRun.EndTime));
    fprintf('  span   %s\n', string(finishedRun.EndTime - finishedRun.StartTime));

    % --- results ------------------------------------------------------
    %
    % From the last link in the chain, which is the only one that reflects
    % every change made along the way.
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
    % Every link in the chain is its own handle and needs its own release.
    delete(finishedRun);
    delete(updatedRun);
    delete(runWithDataset);
    delete(sameRunByRid);
    delete(openRun);
    delete(dataset);
    delete(asset);
    delete(client);

    nominalpublish(results, "nominalRun");
end

function results = nominalexample_rundemo(assetName)
%NOMINALEXAMPLE_RUNDEMO  Exercise every run operation.
%
%   nominalexample_rundemo                   % throwaway asset
%   nominalexample_rundemo("engine-3")       % under an existing asset
%
%   Needs credentials. Creates an asset, a dataset, and a run over them, then
%   closes it.
%
%   Covers: create with an explicit start, get by RID, update including times,
%   all accessors, and finish. Not addDataset — a run's data sources are its
%   asset's, so there is nothing for it to do; see nominal.Run.addDataset.
%
%   See also NOMINAL.RUN, NOMINALEXAMPLE_ASSETDEMO,
%   NOMINALEXAMPLE_EVENTDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalexample_connect();
    asset = client.getOrCreateAsset(assetName);
    % AttachExisting=false: a throwaway demo asset should not adopt some
    % other team's "telemetry". See nominal.Asset.getOrCreateDataset.
    dataset = asset.getOrCreateDataset("telemetry", "tlm", AttachExisting=false);
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

    % --- the run's data ------------------------------------------------
    %
    % There is no attach step, because there is nothing to attach: a run's
    % data sources *are* its asset's, live. The dataset created above is
    % already on the run, and so is anything added to the asset later.
    %
    % nominal.Run.addDataset exists but cannot succeed here — see its help.
    % Every reference name the asset uses is reported as already taken, and
    % every other name as invalid, so there is no argument that works for a
    % run made with asset.run(). Calling it would only print an error.
    fprintf('  data sources come from the asset; nothing to attach\n');

    % --- update -------------------------------------------------------
    %
    % Runs honour start and end times as well as the shared metadata fields.
    % Collections replace rather than merge.
    updatedRun = openRun.update( ...
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
    delete(sameRunByRid);
    delete(openRun);
    delete(dataset);
    delete(asset);
    delete(client);

    nominalexample_publish(results, "nominalRun");
end

function rundemo(assetName)
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
%   See also NOMINAL.RUN, ASSETDEMO, EVENTDEMO, CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = connect();
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
    fprintf('  end    %s (open)\n', string(openRun.EndTime));

    % --- fetch by RID -------------------------------------------------
    sameRunByRid = client.runByRid(openRun.Rid);
    fprintf('  refetched by rid, number matches: %d\n', ...
            sameRunByRid.Number == openRun.Number);

    % --- attach the dataset -------------------------------------------
    %
    % refName addresses the dataset within the run and must be unique among
    % its data sources.
    runWithDataset = openRun.addDataset("tlm", dataset);
    fprintf('  dataset attached\n');

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
    fprintf('Done.\n');
end

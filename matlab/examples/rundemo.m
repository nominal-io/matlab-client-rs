function rundemo(assetName)
%RUNDEMO  Exercise every run operation.
%
%   rundemo                      % throwaway asset
%   rundemo("engine-3")          % under an existing asset
%
%   Needs NOMINAL_TOKEN. Creates an asset, a dataset, and a run; attaches the
%   dataset to the run; then closes it.
%
%   Covers: create with an explicit start, get by RID, attach a dataset,
%   update including times, all accessors, and finish.
%
%   See also NOMINAL.RUN, ASSETDEMO, EVENTDEMO

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = connect();
    asset = client.asset(assetName);
    dataset = asset.dataset("telemetry", "tlm");
    fprintf('Asset %s / dataset %s\n', asset.Name, dataset.Name);

    % --- create -------------------------------------------------------
    %
    % Started a minute ago so the window covers data already written. Pass 0,
    % or omit the argument, to start now instead. Unlike streaming timestamps,
    % 0 here means "now" rather than the epoch.
    startTime = datetime("now", TimeZone="UTC") - minutes(1);
    run = asset.run("matlab-demo-run", startTime);

    fprintf('Run "%s"\n', run.Name);
    fprintf('  rid    %s\n', run.Rid);
    fprintf('  number %d\n', run.Number);
    fprintf('  url    %s\n', run.Url);
    fprintf('  start  %s\n', run.StartTime);

    % An open run has no end. EndTime reports NaT rather than erroring or
    % returning 0, which would be a real instant.
    fprintf('  end    %s (open)\n', run.EndTime);

    % --- fetch by RID -------------------------------------------------
    again = client.runByRid(run.Rid);
    fprintf('  refetched by rid, number matches: %d\n', again.Number == run.Number);

    % --- attach the dataset -------------------------------------------
    %
    % refName addresses the dataset within the run and must be unique among
    % its data sources.
    withData = run.addDataset("tlm", dataset);
    fprintf('  dataset attached\n');

    % --- update -------------------------------------------------------
    %
    % Runs honour start and end times as well as the shared metadata fields.
    % Collections replace rather than merge.
    updated = withData.update( ...
        Description = "Created by the Nominal MATLAB demo", ...
        Labels      = ["matlab-demo" "smoke"], ...
        Properties  = struct(operator = "matlab", phase = "demo"));

    fprintf('  description: %s\n', updated.Description);
    fprintf('  labels:      %s\n', join(updated.Labels, " "));
    fprintf('  operator:    %s\n', updated.property("operator"));

    % --- close it -----------------------------------------------------
    %
    % No argument means end now, which is the usual case at the end of a test.
    finished = updated.finish();
    fprintf('  end    %s (closed)\n', finished.EndTime);
    fprintf('  span   %s\n', finished.EndTime - finished.StartTime);

    % --- teardown -----------------------------------------------------
    delete(finished);
    delete(updated);
    delete(withData);
    delete(again);
    delete(run);
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

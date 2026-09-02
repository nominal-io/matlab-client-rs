function uploaddemo(assetName)
%UPLOADDEMO  Getting data in: from a .mat file, and from a CSV on disk.
%
%   uploaddemo                   % throwaway asset
%   uploaddemo("engine-3")       % under an existing asset
%
%   Needs NOMINAL_TOKEN. Writes two small datasets and leaves two files in
%   tempdir, so point it at something disposable.
%
%   streamdemo covers the live path, where samples arrive as a test runs.
%   This covers the other two, where the data already exists:
%
%     write    — a matrix already in the workspace, or loaded from a .mat.
%                One call, no stream, returns when the data has landed.
%
%     ingest   — a CSV or Parquet file on disk. Nominal does the parsing;
%                you get a job to wait on.
%
%   Also shows the two things worth doing alongside an upload: declaring units
%   before any data exists, and recording which script produced the data.
%
%   See also NOMINAL.DATASET/WRITE, NOMINAL.CLIENT/INGEST, STREAMDEMO

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = connect();
    asset = client.getOrCreateAsset(assetName);
    fprintf('Asset: %s\n\n', asset.Name);

    % Shared sample data: 500 rows, 1 ms apart, three channels.
    rows = 500;
    startTime = datetime("now", TimeZone="UTC") - seconds(rows / 1000);
    t = startTime + milliseconds(0:rows-1)';
    V = [1500 + 10*sin(linspace(0, 6*pi, rows))', ...
         700 + (1:rows)' * 0.1, ...
         30 + 0.05 * (1:rows)'];

    % 1 ------------------------------------------- units before any data
    %
    % setChannelMetadata is an upsert, so it works on channels that do not
    % exist yet. Declaring units first means the first plot comes out right
    % rather than being relabelled later.
    dataset = asset.getOrCreateDataset("Uploaded telemetry", "uploaded");
    fprintf('--- Channel metadata ---\n');
    dataset.setChannelMetadata("rpm", "double", Unit="1/min");
    dataset.setChannelMetadata("egt", "double", Unit="Cel", ...
                               Description="Exhaust gas temperature");
    dataset.setChannelMetadata("psi", "double", Unit="psi");
    fprintf('Declared units for 3 channels\n\n');

    % 2 ----------------------------------------------- upload from a .mat
    %
    % The round trip through a file is the point: this is what a user with an
    % existing .mat actually does. There is no .mat ingest endpoint and none
    % is needed — MATLAB already has the data in memory, so write it directly.
    fprintf('--- Upload from a .mat file ---\n');
    matPath = fullfile(tempdir, "nominal-uploaddemo.mat");
    save(matPath, "t", "V");
    fprintf('Saved %s\n', matPath);

    loaded = load(matPath);
    dataset.write(["rpm" "egt" "psi"], loaded.t, loaded.V);
    fprintf('Wrote %d rows x 3 channels via dataset.write\n\n', rows);

    % 3 ---------------------------------------------------- provenance
    %
    % Properties and labels are arbitrary text. Recording what produced the
    % data is what makes two runs comparable six months later — the model or
    % script version is the thing you always wish you had written down.
    fprintf('--- Provenance ---\n');
    dataset = dataset.update( ...
        Properties=struct(script="uploaddemo.m", ...
                          matlab=string(version("-release")), ...
                          source="dataset.write"), ...
        Labels=["demo" "uploaded"]);
    fprintf('Recorded script, MATLAB release, and source\n');
    fprintf('  script = %s\n\n', dataset.property("script"));

    % 4 ------------------------------------------------ ingest a CSV file
    %
    % The other direction: hand Nominal a path and let it parse. This lands in
    % a new dataset rather than the one above, so the two paths stay legible
    % in the UI.
    fprintf('--- Ingest a CSV ---\n');
    csvPath = fullfile(tempdir, "nominal-uploaddemo.csv");
    writetable(table(posixtime(t), V(:,1), V(:,2), ...
                     VariableNames=["time" "rpm" "egt"]), csvPath);
    fprintf('Wrote %s\n', csvPath);

    % Epoch seconds rather than the ISO 8601 default, because that is what
    % posixtime produces and what most logger CSVs carry.
    job = client.ingest(csvPath, TimestampColumn="time", ...
                        NewDataset=assetName + " (ingested)", ...
                        Kind="epoch", Unit="seconds");
    fprintf('Ingest job %s\n', job.Rid);
    fprintf('  landing in %s\n', job.DatasetRid);
    fprintf('  status now: %s\n', job.status());

    % The upload finished when ingest returned; this waits for the server-side
    % processing. A failed ingest comes back as a status, not an exception.
    final = job.wait();
    fprintf('  finished as: %s\n', final);

    if final == "completed"
        ingested = client.datasetByRid(job.DatasetRid);
        fprintf('  dataset "%s" now has %d channel(s)\n', ...
                ingested.Name, height(ingested.channels()));
        delete(ingested);
    end

    % 5 -------------------------------------------------------- teardown
    fprintf('\n--- Result ---\n');
    fprintf('%s\n', dataset.Rid);
    delete(job);
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

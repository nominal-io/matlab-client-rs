function results = uploaddemo(assetName)
%UPLOADDEMO  Getting data in: from a .mat file, and from a CSV on disk.
%
%   uploaddemo                   % throwaway asset
%   uploaddemo("engine-3")       % under an existing asset
%   results = uploaddemo(...)
%
%   Needs credentials. Writes two small datasets and leaves two files in
%   tempdir, so point it at something disposable.
%
%   The RIDs it creates and the data it sent are returned, and left in the
%   base workspace as `nominalUpload` — so the next demo can be pointed at
%   them without copying anything out of the console:
%
%       uploaddemo("engine-3")
%       analysisdemo(nominalUpload.WrittenDatasetRid)
%
%   Fields: AssetRid, AssetName, WrittenDatasetRid, IngestedDatasetRid,
%   ChannelNames, SampleTimes, SampleValues, IngestStatus, MatFile, CsvFile.
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
%   See also NOMINAL.DATASET/WRITE, NOMINAL.CLIENT/INGEST, STREAMDEMO, NOMINALCONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    % Filled in as the demo goes, so a step that fails still leaves a struct
    % that indexes cleanly.
    results = struct( ...
        'AssetRid',           "", ...
        'AssetName',          "", ...
        'WrittenDatasetRid',  "", ...
        'IngestedDatasetRid', "", ...
        'ChannelNames',       strings(1, 0), ...
        'SampleTimes',        NaT("TimeZone", "UTC"), ...
        'SampleValues',       [], ...
        'IngestStatus',       "", ...
        'MatFile',            "", ...
        'CsvFile',            "");

    client = nominalconnect();
    asset = client.getOrCreateAsset(assetName);
    results.AssetRid = asset.Rid;
    results.AssetName = asset.Name;
    fprintf('Asset: %s\n\n', asset.Name);

    % Synthetic engine telemetry, standing in for whatever your acquisition
    % system produced: half a second of data at 1 kHz across three channels.
    %
    % The timestamps end at "now" rather than starting there, so the data
    % lands in the past and is immediately visible in a default time window.
    %
    % The three signals are shaped only so the charts are legible:
    %
    %   rpm  1490-1510 1/min, three sine cycles — an engine holding idle
    %   egt   700-750  Cel,   a slow linear climb
    %   psi    30-55   psi,   a faster linear climb
    %
    % Nothing reads these values back and checks them; they exist to be
    % plausible on a chart.
    sampleCount = 500;
    sampleRate = 1000;                                  % Hz
    endTime = datetime("now", TimeZone="UTC");
    startTime = endTime - seconds(sampleCount / sampleRate);

    sampleTimes = startTime + milliseconds(0:sampleCount-1)';
    sampleIndex = (1:sampleCount)';

    rpmValues = 1500 + 10 * sin(linspace(0, 6*pi, sampleCount))';
    egtValues = 700 + sampleIndex * 0.1;
    psiValues = 30 + sampleIndex * 0.05;

    % One column per channel, in the same order as the channel names passed
    % to write() below. Getting that order wrong would misalign every series,
    % which is why the two are kept next to each other.
    channelNames = ["matrpm" "mategt" "matpsi"];
    sampleValues = [rpmValues, egtValues, psiValues];

    results.ChannelNames = channelNames;
    results.SampleTimes = sampleTimes;
    results.SampleValues = sampleValues;

    % 1 ------------------------------------------- units before any data
    %
    % setChannelMetadata is an upsert, so it works on channels that do not
    % exist yet. Declaring units first means the first plot comes out right
    % rather than being relabelled later.
    dataset = asset.getOrCreateDataset("Uploaded telemetry", "uploaded");
    fprintf('--- Channel metadata ---\n');

    % Units are UCUM symbols, not free text. That is why temperature is "Cel"
    % rather than "C" (UCUM reserves C for coulomb), speed is "1/min" rather
    % than "rpm", and pressure is "[psi]" — UCUM brackets the customary units
    % it defines by name. A symbol UCUM cannot parse is still accepted, but is
    % stored as display-only and will not support conversions.
    dataset.setChannelMetadata("matrpm", "double", Unit="1/min");
    dataset.setChannelMetadata("mategt", "double", Unit="Cel", ...
                               Description="Exhaust gas temperature");
    dataset.setChannelMetadata("matpsi", "double", Unit="[psi]");
    fprintf('Declared units for %d channels\n\n', numel(channelNames));

    % 2 ----------------------------------------------- upload from a .mat
    %
    % The round trip through a file is the point: this is what a user with an
    % existing .mat actually does. There is no .mat ingest endpoint and none
    % is needed — MATLAB already has the data in memory, so write it directly.
    fprintf('--- Upload from a .mat file ---\n');
    matFilePath = fullfile(tempdir, "nominal-uploaddemo.mat");
    results.MatFile = string(matFilePath);
    save(matFilePath, "sampleTimes", "sampleValues");
    fprintf('Saved %s\n', matFilePath);

    % load() into a struct rather than straight into the workspace, so it is
    % obvious below which values came off disk.
    fromDisk = load(matFilePath);
    dataset.write(channelNames, fromDisk.sampleTimes, fromDisk.sampleValues);
    fprintf('Wrote %d rows x %d channels via dataset.write\n\n', ...
            sampleCount, numel(channelNames));

    % 3 ---------------------------------------------------- provenance
    %
    % Properties and labels are arbitrary text. Recording what produced the
    % data is what makes two runs comparable six months later — the model or
    % script version is the thing you always wish you had written down.
    fprintf('--- Provenance ---\n');

    % update returns a new object rather than changing this one, so the result
    % gets its own name — the original dataset handle still reports the
    % pre-update state.
    annotatedDataset = dataset.update( ...
        Properties=struct(script="uploaddemo.m", ...
                          matlab=string(version("-release")), ...
                          source="dataset.write"), ...
        Labels=["demo" "uploaded"]);

    results.WrittenDatasetRid = annotatedDataset.Rid;

    fprintf('Recorded script, MATLAB release, and source as properties\n');
    fprintf('  script = %s\n', annotatedDataset.property("script"));
    fprintf('  labels = %s\n\n', join(annotatedDataset.Labels, " "));

    % 4 ------------------------------------------------ ingest a CSV file
    %
    % The other direction: hand Nominal a path and let it parse. This lands in
    % its own dataset rather than the one above, so the two paths stay legible
    % in the UI.
    %
    % The dataset is created under the asset *first*, then handed to ingest as
    % Dataset=. Passing NewDataset= instead would work, but the dataset it
    % creates is not attached to any asset — and this client has no way to
    % attach one afterwards, since the C ABI exposes no add-datasource call.
    % Creating it under the asset is the only route to a dataset that shows up
    % in asset.datasources().
    fprintf('--- Ingest a CSV ---\n');
    csvFilePath = fullfile(tempdir, "nominal-uploaddemo.csv");
    results.CsvFile = string(csvFilePath);

    % Two of the three channels, to show that an ingested file decides its own
    % schema — it need not match what was written above.
    csvContents = table(posixtime(sampleTimes), rpmValues, egtValues, ...
                        VariableNames=["time" "csvrpm" "csvegt"]);
    writetable(csvContents, csvFilePath);
    fprintf('Wrote %s\n', csvFilePath);

    ingestTarget = asset.getOrCreateDataset("Ingested telemetry", "ingested");
    results.IngestedDatasetRid = ingestTarget.Rid;

    % Epoch seconds rather than the ISO 8601 default, because that is what
    % posixtime produces and what most logger CSVs carry.
    ingestJob = client.ingest(csvFilePath, TimestampColumn="time", ...
                              Dataset=ingestTarget, ...
                              Kind="epoch", Unit="seconds");
    fprintf('Ingest job %s\n', ingestJob.Rid);
    fprintf('  landing in %s\n', ingestJob.DatasetRid);
    fprintf('  status now: %s\n', ingestJob.status());

    % The upload finished when ingest returned; this waits for the server-side
    % processing. wait() raises if the ingest itself fails, so it is wrapped —
    % a failed ingest is a normal outcome to report, not a reason to abandon
    % the rest of the demo.
    finalStatus = "failed";
    try
        finalStatus = ingestJob.wait();
        fprintf('  finished as: %s\n', finalStatus);
    catch ingestError
        fprintf('  ingest failed: %s\n', ingestError.message);
    end
    results.IngestStatus = finalStatus;

    if finalStatus == "completed"
        fprintf('  dataset "%s" now has %d channel(s)\n', ...
                ingestTarget.Name, height(ingestTarget.channels()));
    end

    % 5 -------------------------------------------------------- teardown
    %
    % Both datasets hang off the asset, so a.datasources() lists them and the
    % asset page in Nominal shows both.
    fprintf('\n--- Result ---\n');
    fprintf('asset %s has %d data source(s):\n', ...
            asset.Name, height(asset.datasources()));
    disp(asset.datasources());

    delete(ingestJob);
    delete(ingestTarget);
    delete(annotatedDataset);
    delete(dataset);
    delete(asset);
    delete(client);

    nominalpublish(results, "nominalUpload");
    fprintf('  e.g. analysisdemo(nominalUpload.WrittenDatasetRid)\n');
end

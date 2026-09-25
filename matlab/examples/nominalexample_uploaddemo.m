function results = nominalexample_uploaddemo(assetName)
%NOMINALEXAMPLE_UPLOADDEMO  Getting data in: from a .mat file, and from a CSV.
%
%   nominalexample_uploaddemo                % throwaway asset
%   nominalexample_uploaddemo("engine-3")    % under an existing asset
%   results = nominalexample_uploaddemo(...)
%
%   Needs credentials. Writes two small datasets and leaves two files in
%   tempdir, so point it at something disposable.
%
%   The RIDs it creates and the data it sent are returned, and left in the
%   base workspace as `nominalUpload`, so the next demo can be pointed at them:
%
%       nominalexample_uploaddemo("engine-3")
%       nominalexample_analysisdemo(nominalUpload.WrittenDatasetRid)
%
%   Fields: AssetRid, AssetName, WrittenDatasetRid, IngestedDatasetRid,
%   ChannelNames, SampleTimes, SampleValues, IngestStatus, MatFile, CsvFile.
%
%   nominalexample_streamdemo covers live data. This covers data that already
%   exists:
%
%     write    - a matrix in the workspace, or loaded from a .mat. One call,
%                no stream, returns when the data has landed.
%
%     ingest   - a CSV or Parquet file on disk. Nominal parses it; you get a
%                job to wait on.
%
%   Also shows declaring units before any data exists, and recording which
%   script produced the data.
%
%   See also NOMINAL.DATASET/WRITE, NOMINAL.CLIENT/INGEST,
%   NOMINALEXAMPLE_STREAMDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    % Filled in as the demo goes; a failed step still leaves every field.
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

    client = nominalexample_connect();
    asset = client.getOrCreateAsset(assetName);
    results.AssetRid = asset.Rid;
    results.AssetName = asset.Name;
    fprintf('Asset: %s\n\n', asset.Name);

    % Synthetic engine telemetry: half a second at 1 kHz across three channels,
    % shaped to look plausible on a chart. The timestamps end at now, so the
    % data is visible in a default time window.
    sampleCount = 500;
    sampleRate = 1000;                                  % Hz
    endTime = datetime("now", TimeZone="UTC");
    startTime = endTime - seconds(sampleCount / sampleRate);

    sampleTimes = startTime + milliseconds(0:sampleCount-1)';
    sampleIndex = (1:sampleCount)';

    rpmValues = 1500 + 10 * sin(linspace(0, 6*pi, sampleCount))';
    egtValues = 700 + sampleIndex * 0.1;
    psiValues = 30 + sampleIndex * 0.05;

    % One column per channel. Column order must match the channel names order.
    channelNames = ["matrpm" "mategt" "matpsi"];
    sampleValues = [rpmValues, egtValues, psiValues];

    results.ChannelNames = channelNames;
    results.SampleTimes = sampleTimes;
    results.SampleValues = sampleValues;

    % 1 ------------------------------------------- units before any data
    %
    % setChannelMetadata is an upsert, so it works on channels that do not
    % exist yet, and the first plot comes out with the right units.
    %
    % AttachExisting=false on both getOrCreateDataset calls: the demo writes to
    % whatever it gets back, and should not adopt a dataset someone else owns.
    dataset = asset.getOrCreateDataset("Uploaded telemetry", "uploaded", ...
                                       AttachExisting=false);
    fprintf('--- Channel metadata ---\n');

    % Units are UCUM symbols: "Cel" not "C" (C is coulomb), "1/min" not "rpm",
    % and "[psi]" in brackets. A symbol UCUM cannot parse is accepted but stored
    % display-only, with no conversions.
    dataset.setChannelMetadata("matrpm", "double", Unit="1/min");
    dataset.setChannelMetadata("mategt", "double", Unit="Cel", ...
                               Description="Exhaust gas temperature");
    dataset.setChannelMetadata("matpsi", "double", Unit="[psi]");
    fprintf('Declared units for %d channels\n\n', numel(channelNames));

    % 2 ----------------------------------------------- upload from a .mat
    %
    % There is no .mat ingest endpoint: load the file and write the data
    % directly.
    fprintf('--- Upload from a .mat file ---\n');
    matFilePath = fullfile(tempdir, "nominal-uploaddemo.mat");
    results.MatFile = string(matFilePath);
    save(matFilePath, "sampleTimes", "sampleValues");
    fprintf('Saved %s\n', matFilePath);

    % load() into a struct so it is clear which values came off disk.
    fromDisk = load(matFilePath);
    dataset.write(channelNames, fromDisk.sampleTimes, fromDisk.sampleValues);
    fprintf('Wrote %d rows x %d channels via dataset.write\n\n', ...
            sampleCount, numel(channelNames));

    % 3 ---------------------------------------------------- provenance
    %
    % Properties and labels are arbitrary text. Record the script and version
    % that produced the data.
    fprintf('--- Provenance ---\n');

    % update returns a new object; the original handle still reports the
    % pre-update state.
    annotatedDataset = dataset.update( ...
        Properties=struct(script="nominalexample_uploaddemo.m", ...
                          matlab=string(version("-release")), ...
                          source="dataset.write"), ...
        Labels=["demo" "uploaded"]);

    results.WrittenDatasetRid = annotatedDataset.Rid;

    fprintf('Recorded script, MATLAB release, and source as properties\n');
    fprintf('  script = %s\n', annotatedDataset.property("script"));
    fprintf('  labels = %s\n\n', join(annotatedDataset.Labels, " "));

    % 4 ------------------------------------------------ ingest a CSV file
    %
    % Hand Nominal a path and let it parse. This lands in its own dataset so
    % the two paths are easy to tell apart in the UI.
    %
    % The dataset is created under the asset first and passed as Dataset=,
    % which is the simpler path. NewDataset= instead creates an unattached
    % dataset; attach it afterwards with
    % asset.addDataset(client.datasetByRid(job.DatasetRid)).
    fprintf('--- Ingest a CSV ---\n');
    csvFilePath = fullfile(tempdir, "nominal-uploaddemo.csv");
    results.CsvFile = string(csvFilePath);

    % Two of the three channels: an ingested file decides its own schema.
    csvContents = table(posixtime(sampleTimes), rpmValues, egtValues, ...
                        VariableNames=["time" "csvrpm" "csvegt"]);
    writetable(csvContents, csvFilePath);
    fprintf('Wrote %s\n', csvFilePath);

    ingestTarget = asset.getOrCreateDataset("Ingested telemetry", "ingested", ...
                                            AttachExisting=false);
    results.IngestedDatasetRid = ingestTarget.Rid;

    % Kind="epoch", Unit="seconds" for a posixtime column. ISO 8601 is the
    % default.
    ingestJob = client.ingest(csvFilePath, TimestampColumn="time", ...
                              Dataset=ingestTarget, ...
                              Kind="epoch", Unit="seconds");
    fprintf('Ingest job %s\n', ingestJob.Rid);
    fprintf('  landing in %s\n', ingestJob.DatasetRid);
    fprintf('  status now: %s\n', ingestJob.status());

    % The upload finished when ingest returned; wait() waits for server-side
    % processing. It raises on a failed ingest, so wrap it to report instead
    % of throwing.
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
    % Both datasets hang off the asset. The asset handle is a snapshot fetched
    % before either dataset existed, so Refresh=true is needed to see them.
    fprintf('\n--- Result ---\n');
    attached = asset.datasources(Refresh=true);
    fprintf('asset %s has %d data source(s):\n', asset.Name, height(attached));
    disp(attached);

    delete(ingestJob);
    delete(ingestTarget);
    delete(annotatedDataset);
    delete(dataset);
    delete(asset);
    delete(client);

    nominalexample_publish(results, "nominalUpload");
    fprintf('  e.g. nominalexample_analysisdemo(nominalUpload.WrittenDatasetRid)\n');
end

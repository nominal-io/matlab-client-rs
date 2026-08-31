function streamdemo(datasetRid)
%STREAMDEMO  End-to-end streaming demo: both write paths, then teardown.
%
%   streamdemo("ri.catalog....")     % explicit dataset
%   streamdemo                       % reads NOMINAL_DATASET_RID
%
%   Needs NOMINAL_TOKEN in the environment. Writes about 220 points across
%   four channels into the dataset you name, so point it at something
%   disposable.
%
%   Covers both ways of writing:
%
%     Matrix push   — the MATLAB path. Preallocate an N-by-C matrix, fill it,
%                     push it. MATLAB stores matrices column-major, so each
%                     channel's samples are already contiguous and reach the
%                     library with no copy or transpose.
%
%     Buffer        — the parity path. Row at a time, commit when full. This
%                     exists so procedures written against the C or LabVIEW
%                     APIs translate line for line; it has no advantage in
%                     MATLAB and is slower, since every row crosses the MEX
%                     boundary separately.
%
%   See also NOMINAL.STREAM, NOMINAL.BUFFER

    arguments
        datasetRid (1,1) string = string(getenv("NOMINAL_DATASET_RID"))
    end

    token = string(getenv("NOMINAL_TOKEN"));
    if token == ""
        error('nominal:demo', 'set NOMINAL_TOKEN in the environment');
    end
    if datasetRid == ""
        error('nominal:demo', ...
              'pass a dataset RID, or set NOMINAL_DATASET_RID');
    end

    % 1 ---------------------------------------------------------- client
    fprintf('Connecting...\n');
    client = nominal.Client(token);
    fprintf('  authenticated as %s\n', client.whoAmI());
    fprintf('  %s\n', client.BaseUrl);

    % 2 ----------------------------------------------------- open stream
    dataset = client.datasetByRid(datasetRid);
    fprintf('Dataset: %s\n', dataset.Name);

    stream = dataset.stream();
    fprintf('Stream opened\n');

    % 3 -------------------------------------------------- single channel
    single = stream.channel("demo.single");

    % 4 ------------------------------------------- push 100 points to it
    %
    % Timestamps are literal here — unlike run times, 0 does not mean "now",
    % because a stream may carry times relative to an epoch you chose.
    t0 = nominal.now();
    timestamps = t0 + int64(0:99)' * 1000000;      % 1 ms apart
    values = sin(linspace(0, 4*pi, 100))';

    stream.push(single, timestamps, values);
    fprintf('Pushed 100 points to %s\n', single.Name);

    % 5 ------------------------------------------------- three channels
    %
    % An array of nominal.Channel. They share one stream, which is required
    % for the buffer below: a buffer commits as a single batch.
    triple = [stream.channel("demo.rpm"), ...
              stream.channel("demo.egt"), ...
              stream.channel("demo.psi")];
    fprintf('Created %d more channels\n', numel(triple));

    % A tag is stamped on every point written through that address from here
    % on. Tags belong to points, not to the channel.
    triple(1).tag("bank", "1");

    % --- the MATLAB way, for comparison with the buffer below ------------
    %
    % Preallocate, fill, push once. This is what production MATLAB code
    % should do; the buffer section that follows is the parity path.
    rows = 100;
    t = t0 + int64(0:rows-1)' * 1000000;
    block = zeros(rows, 3);
    for i = 1:rows
        block(i, :) = [1500 + 10*i, 700 + i, 30 + 0.1*i];
    end
    stream.push(triple, t, block);
    fprintf('Pushed %d x %d block via matrix push\n', rows, numel(triple));

    % 6 ----------------------------------------------------- buffer path
    %
    % Capacity is deliberately smaller than the number of rows stored, so the
    % fill boundary gets exercised more than once.
    capacity = 50;
    buffer = stream.buffer(triple, capacity);
    fprintf('Buffer: capacity %d across %d channels\n', ...
            buffer.Capacity, numel(triple));

    % 7 & 8 ------------------------------- store rows, commit when full
    tBuf = t0 + int64(200:319)' * 1000000;         % 120 rows
    commits = 0;
    for i = 1:numel(tBuf)
        row = [1600 + i; 750 + i; 35 + 0.05*i];
        isFull = buffer.store(tBuf(i), row);
        if isFull
            buffer.commit();
            commits = commits + 1;
        end
    end

    % The tail: 120 rows against a capacity of 50 leaves 20 uncommitted.
    % Committing an empty buffer is a no-op, so this is always safe to call.
    fprintf('  %d full commits, %d rows left over\n', commits, buffer.Rows);
    buffer.commit();
    fprintf('Committed the tail\n');

    % 9 ------------------------------------------------------- teardown
    %
    % Order matters. Everything here is released automatically when it goes
    % out of scope, but MATLAB does not promise when — and releasing the
    % stream is what flushes buffered points. Doing it explicitly means the
    % data has landed before this function returns.
    %
    % Innermost first: buffer, then channels, then the stream that owns them,
    % then the dataset and client.
    delete(buffer);
    delete(triple);
    delete(single);
    delete(stream);      % flushes; blocks until it completes
    delete(dataset);
    delete(client);

    fprintf('\nDone. Points may take a moment to appear — the stream\n');
    fprintf('batches on a 100 ms delay, and ingest is not instant.\n');
end

function streamdemo(datasetRid)
%STREAMDEMO  End-to-end streaming demo: open, write, tear down.
%
%   streamdemo("ri.catalog....")
%
%   Needs credentials. Writes about 200 points across four channels into the
%   dataset you name, so point it at something disposable.
%
%   To find a dataset RID:
%
%       c   = connect();
%       rid = c.datasets("telemetry").Rid(1);
%       streamdemo(rid)
%
%   Writing is one pattern: preallocate an N-by-C matrix, fill it, push it.
%   MATLAB stores matrices column-major, so each channel's samples are already
%   contiguous and reach the library with no copy or transpose.
%
%   See also NOMINAL.STREAM, CONNECT

    arguments
        datasetRid (1,1) string
    end

    % 1 ---------------------------------------------------------- client
    client = connect();
    fprintf('  %s\n', client.BaseUrl);

    % 2 ----------------------------------------------------- open stream
    dataset = client.datasetByRid(datasetRid);
    fprintf('Dataset: %s\n', dataset.Name);

    stream = dataset.stream();
    fprintf('Stream opened\n');

    % 3 -------------------------------------------------- single channel
    %
    % Named sineChannel rather than "single" because that is a MATLAB builtin
    % — the single-precision type — and shadowing it in a demo teaches a bad
    % habit to anyone copying from here.
    sineChannel = stream.channel("demo.sine");

    % 4 ------------------------------------------- push 100 points to it
    %
    % Timestamps are literal here — unlike run times, 0 does not mean "now",
    % because a stream may carry times relative to an epoch you chose.
    acquisitionStart = nominal.now();
    sineTimestamps = acquisitionStart + int64(0:99)' * 1000000;  % 1 ms apart
    sineValues = sin(linspace(0, 4*pi, 100))';                   % two cycles

    stream.push(sineChannel, sineTimestamps, sineValues);
    fprintf('Pushed 100 points to %s\n', sineChannel.Name);

    % 5 ------------------------------------------------- three channels
    %
    % An array of nominal.Channel, all on the one stream. Engine telemetry
    % names, chosen because they are recognisable and carry three genuinely
    % different units: shaft speed, exhaust gas temperature, and a pressure.
    engineChannels = [stream.channel("demo.rpm"), ...
                      stream.channel("demo.egt"), ...
                      stream.channel("demo.psi")];
    fprintf('Created %d more channels\n', numel(engineChannels));

    % A tag is stamped on every point written through that address from here
    % on. Tags belong to points, not to the channel.
    engineChannels(1).tag("bank", "1");

    % 6 ------------------------------------------- a block of three series
    %
    % Preallocate, fill, push once — the pattern this client is fastest at.
    %
    % The numbers are synthetic: 100 rows at 1 ms, so a tenth of a second of
    % an engine spooling up. RPM ramps 1510 -> 2500, exhaust gas temperature
    % 701 -> 800 Cel, and oil pressure 30.1 -> 40 psi. Steeper than anything
    % real over 100 ms — nothing reads these values back, they exist so the
    % charts in Nominal show a trend rather than a flat line.
    blockRowCount = 100;
    blockTimestamps = acquisitionStart + int64(0:blockRowCount-1)' * 1000000;

    engineSamples = zeros(blockRowCount, 3);   % one column per channel
    for row = 1:blockRowCount
        engineSamples(row, :) = [1500 + 10 * row, ...   % rpm
                                 700 + row, ...         % egt, Cel
                                 30 + 0.1 * row];       % psi
    end

    stream.push(engineChannels, blockTimestamps, engineSamples);
    fprintf('Pushed %d x %d block via matrix push\n', ...
            blockRowCount, numel(engineChannels));

    % 7 ------------------------------------------------------- teardown
    %
    % Order matters. Everything here is released automatically when it goes
    % out of scope, but MATLAB does not promise when — and releasing the
    % stream is what flushes buffered points. Doing it explicitly means the
    % data has landed before this function returns.
    %
    % Innermost first: channels, then the stream that owns them, then the
    % dataset and client.
    delete(engineChannels);
    delete(sineChannel);
    delete(stream);      % flushes; blocks until it completes
    delete(dataset);
    delete(client);

    fprintf('\nDone. Points may take a moment to appear — the stream\n');
    fprintf('batches on a 100 ms delay, and ingest is not instant.\n');
end

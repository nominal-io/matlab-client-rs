classdef Dataset < nominal.Resource
    % DATASET  Time-aligned access to test data, exposing many channels.
    %
    %   Obtained from an asset or a client:
    %
    %       ds = a.getOrCreateDataset("telemetry", "tlm");
    %       ds = c.datasetByRid(rid);
    %
    %   Streaming into it:
    %
    %       s = ds.stream();
    %
    %   See also NOMINAL.ASSET, NOMINAL.STREAM

    properties (Dependent, SetAccess = private)
        Rid string   % Resource identifier.
        Name string  % Display name.
    end

    properties (Access = private)
        Client nominal.Client
    end

    methods
        function obj = Dataset(client, handle)
            % Constructed by nominal.Client or nominal.Asset; not called directly.
            arguments
                client (1,1) nominal.Client
                handle (1,1) int32
            end
            obj.Client = client;
            obj.Handle = handle;
        end

        function v = get.Rid(obj);  obj.assertLive(); v = string(nominalmex('dataset_rid', obj.Handle));  end
        function v = get.Name(obj); obj.assertLive(); v = string(nominalmex('dataset_name', obj.Handle)); end

        function s = stream(obj)
            %STREAM  Open a stream that writes into this dataset.
            %
            %   Data is buffered and shipped in the background; nothing is
            %   durable until it reaches Nominal. The stream flushes when it is
            %   released, which happens automatically when it goes out of
            %   scope — but see nominal.Stream for why you may want to force it.
            obj.assertLive();
            s = nominal.Stream(nominalmex('stream_create', obj.Client.Handle, obj.Handle));
        end

        function write(obj, channels, timestamps, values)
            %WRITE  Send a block of samples in one call, with no stream.
            %
            %   ds.write(["rpm" "egt"], t, V)
            %
            %   channels   1-by-C string array of channel names
            %   timestamps N-by-1 int64 nanoseconds, or a datetime vector
            %   values     N-by-C double, one column per channel
            %
            %   Returns once the write has been accepted, so there is nothing
            %   to flush and no stream to close. Use this for data already in
            %   memory; use stream() for continuous acquisition, where the
            %   background batching and backpressure earn their keep.
            %
            %   Keep a call to roughly 50,000 points and at most 10 channels.
            %   The server splits larger requests, but a stream is the better
            %   tool past that point.
            %
            %   Timestamps are literal, including zero.
            %
            %   See also NOMINAL.DATASET/STREAM
            arguments
                obj (1,1) nominal.Dataset
                channels (1,:) string
                timestamps
                values (:,:) double
            end
            obj.assertLive();

            if numel(channels) ~= size(values, 2)
                error('nominal:invalidParameter', ...
                      'values has %d columns but %d channels were given', ...
                      size(values, 2), numel(channels));
            end

            nominalmex('dataset_write', obj.Client.Handle, obj.Handle, ...
                       cellstr(channels), nominal.toNanosVector(timestamps), values);
        end

        function m = channelMetadata(obj, name)
            %CHANNELMETADATA  Units and description for one channel by name.
            %
            %   Errors if the dataset has no channel with that name. Use
            %   setChannelMetadata to attach metadata before any data exists.
            arguments
                obj (1,1) nominal.Dataset
                name (1,1) string
            end
            obj.assertLive();
            m = nominal.ChannelMetadata( ...
                nominalmex('meta_get', obj.Client.Handle, obj.Handle, char(name)));
        end

        function t = channels(obj)
            %CHANNELS  Every channel in this dataset, as a table.
            %
            %   Variables: Name, Unit, Description, DataType. Ordered by name.
            %
            %       ds.channels()
            %       ds.channels().Name                    % just the names
            %       c = ds.channels();
            %       c(c.Unit == "Cel", :)                 % only the temperatures
            obj.assertLive();
            t = structsToTable(nominalmex('meta_list', obj.Client.Handle, obj.Handle), ...
                               ["Name" "Unit" "Description" "DataType"]);
        end

        function tt = fetch(obj, channel, startTime, endTime, options)
            %FETCH  Read one channel back into MATLAB as a timetable.
            %
            %   tt = ds.fetch("rpm", t0, t1)
            %   tt = ds.fetch("rpm", t0, t1, Buckets=2000)
            %
            %   startTime and endTime are zoned datetimes or int64 nanoseconds;
            %   the window is inclusive at both ends. The result is a timetable
            %   with one variable named after the channel, so it plots and
            %   resamples directly:
            %
            %       plot(tt.Time, tt.("rpm"))
            %       retime(tt, "regular", "linear", TimeStep=seconds(1))
            %
            %   Buckets asks the server to decimate to roughly that many
            %   points, capped at 10,000. Use it for plotting, where full
            %   resolution is wasted — a few thousand points is usually
            %   indistinguishable on screen and vastly cheaper. Without it the
            %   whole window is fetched, which pages internally and can be many
            %   round trips over a wide window; export is the better tool when
            %   the destination is a file.
            %
            %   Note that timetable row times are datetimes, whose resolution
            %   does not reach nanoseconds. Use export if you need the exact
            %   instants.
            %
            %   See also NOMINAL.DATASET/EXPORT, RETIME, SYNCHRONIZE
            arguments
                obj (1,1) nominal.Dataset
                channel (1,1) string
                startTime
                endTime
                options.Buckets (1,1) double {mustBePositive, mustBeInteger} = 0
            end
            obj.assertLive();

            if options.Buckets > 0
                [nanos, values] = nominalmex('dataset_fetch_decimated', ...
                    obj.Client.Handle, obj.Handle, char(channel), ...
                    nominal.toNanos(startTime), nominal.toNanos(endTime), ...
                    int32(options.Buckets));
            else
                [nanos, values] = nominalmex('dataset_fetch', ...
                    obj.Client.Handle, obj.Handle, char(channel), ...
                    nominal.toNanos(startTime), nominal.toNanos(endTime));
            end

            tt = timetable(nominal.fromNanos(nanos), values);

            % A channel really can be called "Time", and a timetable cannot
            % have a variable sharing the row-times dimension name. Move the
            % dimension rather than the channel, so the variable still answers
            % to the name the data actually has.
            if strcmp(char(channel), tt.Properties.DimensionNames{1})
                tt.Properties.DimensionNames{1} = 'RowTimes';
            end

            % Assigned rather than passed to the constructor: channel names
            % routinely contain dots ("engine.left.rpm"), and the constructor
            % would quietly rewrite those into valid identifiers.
            tt.Properties.VariableNames = {char(channel)};
        end

        function export(obj, path, channels, startTime, endTime, options)
            %EXPORT  Write channels to a file on disk.
            %
            %   ds.export("run12.mat", ["rpm" "egt"], t0, t1)
            %   ds.export("run12.csv", ch, t0, t1, Format="csv")
            %
            %   Format is matfile (the default), csv, or arrow. The file is
            %   replaced if it exists, and the call blocks until the whole
            %   export has been received.
            %
            %   This moves the same data as fetch but in one request rather
            %   than many, so it is the right tool for a wide window. Use fetch
            %   when you want the samples in the workspace; use this when you
            %   want them on disk.
            %
            %   Resolution is full (every sample, the default), buckets, or
            %   interval. The latter two read ResolutionValue as a point count
            %   or a nanosecond spacing respectively.
            %
            %   See also NOMINAL.DATASET/FETCH, NOMINAL.DATASET/EXPORTURL
            arguments
                obj (1,1) nominal.Dataset
                path (1,1) string
                channels (1,:) string
                startTime
                endTime
                options.Format (1,1) string {mustBeMember(options.Format, ...
                    ["matfile" "csv" "arrow"])} = "matfile"
                options.Resolution (1,1) string {mustBeMember(options.Resolution, ...
                    ["full" "buckets" "interval"])} = "full"
                options.ResolutionValue (1,1) double = 0
            end
            obj.assertLive();
            nominalmex('dataset_export', obj.Client.Handle, obj.Handle, ...
                       cellstr(channels), nominal.toNanos(startTime), ...
                       nominal.toNanos(endTime), char(options.Resolution), ...
                       int64(options.ResolutionValue), char(options.Format), ...
                       char(path));
        end

        function url = exportUrl(obj, channels, startTime, endTime, options)
            %EXPORTURL  A time-limited download link instead of the bytes.
            %
            %   The server renders the file to object storage and returns a
            %   presigned URL. Useful when the link is more use than the data —
            %   handing it to a browser, or to something that is not MATLAB.
            %
            %   Arguments match export, minus the path.
            %
            %   See also NOMINAL.DATASET/EXPORT
            arguments
                obj (1,1) nominal.Dataset
                channels (1,:) string
                startTime
                endTime
                options.Format (1,1) string {mustBeMember(options.Format, ...
                    ["matfile" "csv" "arrow"])} = "matfile"
                options.Resolution (1,1) string {mustBeMember(options.Resolution, ...
                    ["full" "buckets" "interval"])} = "full"
                options.ResolutionValue (1,1) double = 0
            end
            obj.assertLive();
            url = string(nominalmex('dataset_export_url', obj.Client.Handle, ...
                obj.Handle, cellstr(channels), nominal.toNanos(startTime), ...
                nominal.toNanos(endTime), char(options.Resolution), ...
                int64(options.ResolutionValue), char(options.Format)));
        end

        function m = setChannelMetadata(obj, name, dataType, options)
            %SETCHANNELMETADATA  Attach or update a channel's units.
            %
            %   ds.setChannelMetadata("rpm", "double", Unit="1/min")
            %   ds.setChannelMetadata("rpm", "double", Unit="")     % clear
            %
            %   dataType is required and always sent — the underlying API has
            %   no way to leave it alone, so naming the wrong one re-declares
            %   the channel as something it is not. One of: double, int, uint,
            %   string, log, doubleArray, stringArray, struct, video, spatial.
            %
            %   Units are UCUM symbols such as "1/min", "Cel", "m/s2". A symbol
            %   UCUM cannot parse is stored as display-only and will not
            %   support conversions.
            %
            %   This is an upsert, so it works before any data exists — which
            %   is how you attach units ahead of a stream or upload.
            %
            %   The returned object reflects what you sent rather than what the
            %   server now holds; re-fetch with channelMetadata for truth.
            arguments
                obj (1,1) nominal.Dataset
                name (1,1) string
                dataType (1,1) string {mustBeMember(dataType, ...
                    ["double" "int" "uint" "string" "log" "doubleArray" ...
                     "stringArray" "struct" "video" "spatial"])}
                options.Unit string = string.empty
                options.Description string = string.empty
            end
            obj.assertLive();

            unit = "";
            if ~isempty(options.Unit)
                unit = options.Unit;
            end
            description = "";
            if ~isempty(options.Description)
                description = options.Description;
            end

            m = nominal.ChannelMetadata(nominalmex('meta_set', ...
                obj.Client.Handle, obj.Handle, char(name), char(dataType), ...
                char(unit), char(description)));
        end

        function updated = update(obj, options)
            %UPDATE  Apply metadata changes, returning the updated dataset.
            %
            %   Collections REPLACE rather than merge — see nominal.Asset.update.
            arguments
                obj (1,1) nominal.Dataset
                options.Name string = string.empty
                options.Description string = string.empty
                options.Properties struct = struct.empty
                options.Labels string = string.empty
            end
            obj.assertLive();
            u = obj.stageUpdate(options);
            cleanup = onCleanup(@() nominalmex('update_free', u));
            updated = nominal.Dataset(obj.Client, ...
                nominalmex('dataset_update_commit', obj.Client.Handle, obj.Handle, u));
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('dataset_free', obj.Handle);
        end
    end
end

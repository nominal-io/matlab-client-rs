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
        Rid string          % Resource identifier.
        Name string         % Display name.
        Description string  % Description, or "" if it has none.
        Labels string       % All labels, as a string array.
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

        function v = get.Rid(obj);         obj.assertLive(); v = string(nominalmex('dataset_rid', obj.Handle));         end
        function v = get.Name(obj);        obj.assertLive(); v = string(nominalmex('dataset_name', obj.Handle));        end
        function v = get.Description(obj); obj.assertLive(); v = string(nominalmex('dataset_description', obj.Handle)); end

        function v = get.Labels(obj)
            obj.assertLive();
            n = double(nominalmex('dataset_label_count', obj.Handle));
            v = strings(1, n);
            for i = 1:n
                v(i) = string(nominalmex('dataset_label_at', obj.Handle, int32(i - 1)));
            end
        end

        function value = property(obj, key)
            %PROPERTY  Value of one property. Errors if the key is absent.
            arguments
                obj (1,1) nominal.Dataset
                key (1,1) string
            end
            obj.assertLive();
            value = string(nominalmex('dataset_property', obj.Handle, char(key)));
        end

        function s = stream(obj)
            %STREAM  Open a stream that writes into this dataset.
            %
            %   Data is buffered and sent in the background. The stream flushes
            %   when released; call delete(s) to make that happen at a known
            %   point. See nominal.Stream.
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
            %   Returns once the write has been accepted; nothing to flush or
            %   close. Use this for data already in memory, and stream() for
            %   continuous acquisition.
            %
            %   Keep a call to roughly 50,000 points and at most 10 channels.
            %   Past that, use a stream.
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
            %   points (bucket means), capped at 10,000. Use it for plotting.
            %   Without it the whole window is fetched, which can be many round
            %   trips over a wide window; use export when the destination is a
            %   file.
            %
            %   Timetable row times are datetimes, which do not resolve to
            %   nanoseconds. Use export if you need the exact instants.
            %
            %   See also NOMINAL.DATASET/EXPORT, RETIME, SYNCHRONIZE
            arguments
                obj (1,1) nominal.Dataset
                channel (1,1) string
                startTime
                endTime
                % Nonnegative rather than positive: MATLAB validates the
                % default as well as a supplied value, so mustBePositive with
                % a default of 0 rejects every call that omits Buckets. Zero
                % is the sentinel for "no decimation".
                options.Buckets (1,1) double {mustBeNonnegative, mustBeInteger} = 0
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

            % A channel really can be called "Time" or "Variables", and a
            % timetable cannot have a variable sharing either dimension name.
            % Move the dimension rather than the channel, so the variable still
            % answers to the name the data actually has.
            if strcmp(char(channel), tt.Properties.DimensionNames{1})
                tt.Properties.DimensionNames{1} = 'RowTimes';
            end
            if strcmp(char(channel), tt.Properties.DimensionNames{2})
                tt.Properties.DimensionNames{2} = 'TableVariables';
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
            %   replaced if it exists. Blocks until the export is complete.
            %
            %   Same data as fetch, but in one request, so better for a wide
            %   window. Use fetch for samples in the workspace, export for
            %   samples on disk.
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
            %EXPORTURL  A time-limited download link instead of a file.
            %
            %   For handing to a browser or something that is not MATLAB.
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
            %   dataType is required and always sent, so naming the wrong one
            %   re-declares the channel. One of: double, int, uint, string,
            %   log, doubleArray, stringArray, struct, video, spatial.
            %
            %   Units are UCUM symbols such as "1/min", "Cel", "m/s2". A symbol
            %   UCUM cannot parse is stored display-only, with no conversions.
            %
            %   This is an upsert and works before any data exists, so you can
            %   declare units ahead of a stream or upload.
            %
            %   The returned object reflects what you sent, not what the server
            %   holds. Re-fetch with channelMetadata to check.
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
            %   Labels and Properties REPLACE rather than merge. Fields not
            %   passed are left alone. The original object still shows the
            %   pre-update state.
            arguments
                obj (1,1) nominal.Dataset
                % No defaults, so stageUpdate can tell "passed empty" (clear)
                % from "not passed" (leave alone) — see nominal.Asset.update,
                % which also explains why only Labels is left unconstrained.
                options.Name (1,1) string
                options.Description (1,1) string
                options.Properties struct
                options.Labels string
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

classdef Dataset < nominal.Resource
    % DATASET  Time-aligned access to test data, exposing many channels.
    %
    %   Obtained from an asset or a client:
    %
    %       ds = a.getOrCreateDataset("telemetry", "tlm");
    %       ds = c.datasetByRid(rid);
    %       ds = c.createDataset("shared");      % attached to nothing
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

        function v = get.Rid(obj)
            obj.assertLive();
            v = string(nominalmex('dataset_rid', obj.Handle));
        end

        function v = get.Name(obj)
            obj.assertLive();
            v = string(nominalmex('dataset_name', obj.Handle));
        end

        function v = get.Description(obj)
            obj.assertLive();
            v = string(nominalmex('dataset_description', obj.Handle));
        end

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
            %
            %   Returns:
            %       string: The property's value.
            arguments
                obj (1,1) nominal.Dataset
                key (1,1) string
            end
            obj.assertLive();
            value = string(nominalmex('dataset_property', obj.Handle, char(key)));
        end

        function t = assets(obj)
            %ASSETS  Every asset this dataset is attached to, as a table.
            %
            %   An asset holding the dataset more than once, under different
            %   tags, is listed once.
            %
            %   Returns:
            %       table: Variables Name, Rid and Description, ordered by name.
            %
            %   See also NOMINAL.ASSET/ADDDATASET
            obj.assertLive();
            t = structsToTable(nominalmex('dataset_assets', obj.Client.Handle, obj.Handle), ...
                               ["Name" "Rid" "Description"]);
        end

        function s = stream(obj)
            %STREAM  Open a stream that writes into this dataset.
            %
            %   Data is buffered and sent in the background. The stream flushes
            %   when released; call delete(s) to make that happen at a known
            %   point.
            %
            %   Returns:
            %       nominal.Stream: The open stream.
            %
            %   See also NOMINAL.STREAM
            obj.assertLive();
            s = nominal.Stream(nominalmex('stream_create', obj.Client.Handle, obj.Handle));
        end

        function write(obj, channels, timestamps, values, options)
            %WRITE  Send a block of samples in one call, with no stream.
            %
            %   ds.write(["rpm" "egt"], t, V)
            %   ds.write(["rpm" "egt"], t, V, Tags=struct(UUT="A"))
            %
            %   Returns once the write has been accepted; nothing to flush or
            %   close. Use this for data already in memory, and stream() for
            %   continuous acquisition.
            %
            %   Keep a call to roughly 50,000 points and at most 10 channels.
            %   Past that, use a stream.
            %
            %   Args:
            %       channels: 1-by-C string array of channel names.
            %       timestamps: N-by-1 int64 nanoseconds, or a datetime
            %           vector. Literal, including zero.
            %       values: N-by-C double, one column per channel.
            %
            %   Options:
            %       Tags: Stamped on every point written. A struct, or a
            %           dictionary for keys that aren't valid field names. An
            %           asset attached with the same Tags sees these points.
            %
            %   See also NOMINAL.DATASET/STREAM
            arguments
                obj (1,1) nominal.Dataset
                channels (1,:) string
                timestamps
                values (:,:) double
                options.Tags (1,1) {mustBeA(options.Tags, ["struct" "dictionary"])} = struct()
            end
            obj.assertLive();

            if numel(channels) ~= size(values, 2)
                error('nominal:invalidParameter', ...
                      'values has %d columns but %d channels were given', ...
                      size(values, 2), numel(channels));
            end
            [tagKeys, tagValues] = keyValuePairs(options.Tags, "tag");

            nominalmex('dataset_write', obj.Client.Handle, obj.Handle, ...
                       cellstr(channels), nominal.toNanosVector(timestamps), values, ...
                       tagKeys, tagValues);
        end

        function m = channelMetadata(obj, name)
            %CHANNELMETADATA  Units and description for one channel by name.
            %
            %   Errors if the dataset has no channel with that name. Use
            %   setChannelMetadata to attach metadata before any data exists.
            %
            %   Returns:
            %       nominal.ChannelMetadata: The channel's units, description
            %       and data type.
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
            %       ds.channels()
            %       ds.channels().Name                    % just the names
            %       c = ds.channels();
            %       c(c.Unit == "Cel", :)                 % only the temperatures
            %
            %   Returns:
            %       table: Variables Name, Unit, Description and DataType,
            %       ordered by name.
            obj.assertLive();
            t = structsToTable(nominalmex('meta_list', obj.Client.Handle, obj.Handle), ...
                               ["Name" "Unit" "Description" "DataType"]);
        end

        function tt = fetch(obj, channel, startTime, endTime, options)
            %FETCH  Read one channel back into MATLAB as a timetable.
            %
            %   tt = ds.fetch("rpm", t0, t1)
            %   tt = ds.fetch("rpm", t0, t1, Buckets=2000)
            %   tt = ds.fetch("rpm", t0, t1, Tags=struct(UUT="A"))
            %
            %   The result plots and resamples directly:
            %
            %       plot(tt.Time, tt.("rpm"))
            %       retime(tt, "regular", "linear", TimeStep=seconds(1))
            %
            %   Without Buckets the whole window is fetched, which can be many
            %   round trips over a wide window; use export when the destination
            %   is a file.
            %
            %   Args:
            %       startTime: Zoned datetime or int64 nanoseconds. The window
            %           is inclusive at both ends.
            %       endTime: Zoned datetime or int64 nanoseconds.
            %
            %   Options:
            %       Buckets: Decimate server-side to roughly this many points
            %           (bucket means), capped at 10,000. Use it for plotting.
            %       Tags: A channel written with tags holds one series per tag
            %           set. If it has more than one, pick with Tags, as given
            %           to write.
            %
            %   Returns:
            %       timetable: One variable, named after the channel. Row times
            %       are datetimes, which do not resolve to nanoseconds; use
            %       export if you need the exact instants.
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
                options.Tags (1,1) {mustBeA(options.Tags, ["struct" "dictionary"])} = struct()
            end
            obj.assertLive();
            [tagKeys, tagValues] = keyValuePairs(options.Tags, "tag");

            if options.Buckets > 0
                [nanos, values] = nominalmex('dataset_fetch_decimated', ...
                    obj.Client.Handle, obj.Handle, char(channel), ...
                    nominal.toNanos(startTime), nominal.toNanos(endTime), ...
                    int32(options.Buckets), tagKeys, tagValues);
            else
                [nanos, values] = nominalmex('dataset_fetch', ...
                    obj.Client.Handle, obj.Handle, char(channel), ...
                    nominal.toNanos(startTime), nominal.toNanos(endTime), ...
                    tagKeys, tagValues);
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
            %   Same data as fetch, but in one request, so better for a wide
            %   window. Use fetch for samples in the workspace, export for
            %   samples on disk. Blocks until the export is complete.
            %
            %   Args:
            %       path: File to write. Replaced if it exists.
            %       channels: Channel names.
            %       startTime: Zoned datetime or int64 nanoseconds.
            %       endTime: Zoned datetime or int64 nanoseconds.
            %
            %   Options:
            %       Format: "matfile" (the default), "csv" or "arrow".
            %       Resolution: "full" (every sample, the default), "buckets"
            %           or "interval".
            %       ResolutionValue: The point count for "buckets", or the
            %           nanosecond spacing for "interval".
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
            %   url = ds.exportUrl(["rpm" "egt"], t0, t1, Format="csv")
            %
            %   For handing to a browser or something that is not MATLAB.
            %
            %   Args:
            %       channels: Channel names.
            %       startTime: Zoned datetime or int64 nanoseconds.
            %       endTime: Zoned datetime or int64 nanoseconds.
            %
            %   Options:
            %       Format: "matfile" (the default), "csv" or "arrow".
            %       Resolution: "full" (every sample, the default), "buckets"
            %           or "interval".
            %       ResolutionValue: The point count for "buckets", or the
            %           nanosecond spacing for "interval".
            %
            %   Returns:
            %       string: The download URL. It expires.
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
            %   This is an upsert and works before any data exists, so you can
            %   declare units ahead of a stream or upload.
            %
            %   Args:
            %       name: Channel name.
            %       dataType: Required and always sent, so naming the wrong one
            %           re-declares the channel. One of double, int, uint,
            %           string, log, doubleArray, stringArray, struct, video,
            %           spatial.
            %
            %   Options:
            %       Unit: A UCUM symbol such as "1/min", "Cel" or "m/s2". A
            %           symbol UCUM cannot parse is stored display-only, with
            %           no conversions.
            %       Description: Free text.
            %
            %   Returns:
            %       nominal.ChannelMetadata: What you sent, not what the server
            %       holds. Re-fetch with channelMetadata to check.
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
            %   ds2 = ds.update(Description="reduced", Labels=["flight-test"])
            %
            %   Options not passed are left alone. Labels and Properties
            %   REPLACE rather than merge: read ds.Labels first and concatenate
            %   if you mean to add.
            %
            %   Options:
            %       Name: New display name.
            %       Description: New description.
            %       Properties: Struct of key-value pairs, replacing all of
            %           them. struct() clears them.
            %       Labels: String array, replacing all of them. string.empty
            %           clears them.
            %
            %   Returns:
            %       nominal.Dataset: A new handle with the changes applied. The
            %       original still shows the pre-update state.
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

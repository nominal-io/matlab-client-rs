classdef Dataset < nominal.Resource
    % DATASET  Time-aligned access to test data, exposing many channels.
    %
    %   Obtained from an asset or a client:
    %
    %       ds = a.dataset("telemetry", "tlm");
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

        function channels = channels(obj)
            %CHANNELS  Every channel in this dataset, as a struct array.
            %
            %   Fields: Name, Unit, Description, DataType. Ordered by name.
            %
            %       struct2table(ds.channels())
            obj.assertLive();
            channels = nominalmex('meta_list', obj.Client.Handle, obj.Handle);
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

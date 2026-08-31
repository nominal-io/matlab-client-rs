classdef Asset < nominal.Resource
    % ASSET  A physical or logical system under test.
    %
    %   Obtained from a client rather than constructed directly:
    %
    %       a = c.asset("engine-3");        % get or create by name
    %       a = c.assetByRid(rid);          % by RID
    %
    %   Example:
    %       ds = a.dataset("telemetry", "tlm");
    %       r  = a.run("burn-12");
    %       a.update(Labels=["production" "orbit"]);
    %
    %   See also NOMINAL.CLIENT, NOMINAL.DATASET, NOMINAL.RUN

    properties (Dependent, SetAccess = private)
        Rid string          % Resource identifier.
        Name string         % Display name.
        Description string  % Description, or "" if it has none.
        Url string          % Web URL in the Nominal app.
        Labels string       % All labels, as a string array.
    end

    properties (Access = private)
        Client nominal.Client
    end

    methods
        function obj = Asset(client, handle)
            % Constructed by nominal.Client; not called directly.
            arguments
                client (1,1) nominal.Client
                handle (1,1) int32
            end
            obj.Client = client;
            obj.Handle = handle;
        end

        function v = get.Rid(obj);         obj.assertLive(); v = string(nominalmex('asset_rid', obj.Handle));         end
        function v = get.Name(obj);        obj.assertLive(); v = string(nominalmex('asset_name', obj.Handle));        end
        function v = get.Description(obj); obj.assertLive(); v = string(nominalmex('asset_description', obj.Handle)); end
        function v = get.Url(obj);         obj.assertLive(); v = string(nominalmex('asset_url', obj.Handle));          end

        function v = get.Labels(obj)
            obj.assertLive();
            n = double(nominalmex('asset_label_count', obj.Handle));
            v = strings(1, n);
            for i = 1:n
                v(i) = string(nominalmex('asset_label_at', obj.Handle, int32(i - 1)));
            end
        end

        function value = property(obj, key)
            %PROPERTY  Value of one property. Errors if the key is absent.
            arguments
                obj (1,1) nominal.Asset
                key (1,1) string
            end
            obj.assertLive();
            value = string(nominalmex('asset_property', obj.Handle, char(key)));
        end

        function sources = datasources(obj)
            %DATASOURCES  Everything attached to this asset, as a struct array.
            %
            %   Fields: RefName, Rid, Type. Type is "dataset", "video", or
            %   "connection" — which matters because the RID alone does not
            %   tell you what an endpoint will accept. Only a dataset RID can
            %   open a stream, for instance.
            %
            %   Ordered by reference name, so the result is reproducible.
            %
            %       s = a.datasources();
            %       struct2table(s)
            %       tlm = s(strcmp({s.Type}, 'dataset'));
            obj.assertLive();
            sources = nominalmex('asset_datasources', obj.Handle);
        end

        function d = dataset(obj, name, refName)
            %DATASET  Fetch a dataset by name, creating and attaching it if absent.
            %
            %   refName is how the dataset is addressed within this asset and
            %   must be unique among its data sources. An existing dataset is
            %   returned as-is and is not re-attached.
            arguments
                obj (1,1) nominal.Asset
                name (1,1) string
                refName (1,1) string
            end
            obj.assertLive();
            d = nominal.Dataset(obj.Client, ...
                nominalmex('dataset_get_or_create', obj.Client.Handle, obj.Handle, ...
                           char(name), char(refName)));
        end

        function r = run(obj, name, startTime)
            %RUN  Create a run on this asset.
            %
            %   startTime may be a datetime or int64 nanoseconds since the
            %   epoch. Omit it, or pass 0, to start the run now. The run is
            %   left open — close it with r.finish().
            arguments
                obj (1,1) nominal.Asset
                name (1,1) string
                startTime = int64(0)
            end
            obj.assertLive();
            r = nominal.Run(obj.Client, ...
                nominalmex('run_create', obj.Client.Handle, obj.Handle, ...
                           char(name), nominal.toNanos(startTime)));
        end

        function updated = update(obj, options)
            %UPDATE  Apply metadata changes, returning the updated asset.
            %
            %   a2 = a.update(Name="x", Description="y", ...
            %                 Properties=struct(phase="burn"), ...
            %                 Labels=["a" "b"]);
            %
            %   Collections REPLACE rather than merge: passing Labels at all
            %   discards whatever the asset had. Read a.Labels first and
            %   concatenate if you mean to add. Fields not passed are left
            %   alone; pass Labels=string.empty to clear them.
            %
            %   The original object still reflects the pre-update state.
            arguments
                obj (1,1) nominal.Asset
                options.Name string = string.empty
                options.Description string = string.empty
                options.Properties struct = struct.empty
                options.Labels string = string.empty
            end
            obj.assertLive();
            u = obj.stageUpdate(options);
            cleanup = onCleanup(@() nominalmex('update_free', u));
            updated = nominal.Asset(obj.Client, ...
                nominalmex('asset_update_commit', obj.Client.Handle, obj.Handle, u));
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('asset_free', obj.Handle);
        end
    end
end

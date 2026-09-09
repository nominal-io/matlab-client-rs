classdef Asset < nominal.Resource
    % ASSET  A physical or logical system under test.
    %
    %   Obtained from a client rather than constructed directly:
    %
    %       a = c.getOrCreateAsset("engine-3");   % by name, creating if absent
    %       a = c.assetByRid(rid);                % by RID
    %
    %   Example:
    %       ds = a.getOrCreateDataset("telemetry", "tlm");
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

        function t = datasources(obj, options)
            %DATASOURCES  Everything attached to this asset, as a table.
            %
            %   s = a.datasources();                % what this handle knows
            %   s = a.datasources(Refresh=true);    % ask the server
            %
            %   Variables: RefName, Rid, Type. Type is "dataset", "video", or
            %   "connection" — which matters because the RID alone does not
            %   tell you what an endpoint will accept. Only a dataset RID can
            %   open a stream, for instance.
            %
            %   Ordered by reference name, so the result is reproducible.
            %
            %       s = a.datasources();
            %       tlm = s(s.Type == "dataset", :);
            %
            %   **Reads this handle's snapshot by default**, taken when the
            %   asset was fetched. So a dataset attached since — by
            %   getOrCreateDataset, by another process, or from the web app —
            %   is not listed until you ask for it:
            %
            %       a.getOrCreateDataset("telemetry", "tlm");
            %       height(a.datasources())              % unchanged
            %       height(a.datasources(Refresh=true))  % +1
            %
            %   That is the same rule every other accessor follows — a handle
            %   is a snapshot, which is why update() hands back a new object
            %   rather than changing this one. Refresh=true costs one request
            %   and does *not* alter this object: it reads a fresh handle and
            %   discards it, so a.Name and the rest still report what they
            %   always did.
            %
            %   See also NOMINAL.CLIENT/ASSETBYRID
            arguments
                obj (1,1) nominal.Asset
                options.Refresh (1,1) logical = false
            end
            obj.assertLive();

            if options.Refresh
                % A throwaway handle on the same asset. The table is plain
                % data by the time it comes back, so releasing the handle
                % straight away is safe — and an exception on the way would
                % release it anyway, when the local goes out of scope.
                fresh = obj.Client.assetByRid(obj.Rid);
                t = fresh.datasources();
                delete(fresh);
                return
            end

            t = structsToTable(nominalmex('asset_datasources', obj.Handle), ...
                               ["RefName" "Rid" "Type"]);
        end

        function d = getAttachedDataset(obj, name)
            %GETATTACHEDDATASET  A dataset already on this asset, by name.
            %
            %   d = a.getAttachedDataset("telemetry");
            %
            %   Read-only: it never creates or attaches anything. Use it when
            %   the dataset is expected to be there and its absence is a
            %   problem; getOrCreateDataset is for making sure it is.
            %
            %   Errors when no dataset of that name is attached, and when more
            %   than one is — a name is not unique in Nominal, so there is
            %   nothing sensible to return. a.datasources() lists everything
            %   without erroring.
            %
            %   See also NOMINAL.ASSET/GETORCREATEDATASET, NOMINAL.ASSET/DATASOURCES
            arguments
                obj (1,1) nominal.Asset
                name (1,1) string
            end
            obj.assertLive();
            d = nominal.Dataset(obj.Client, ...
                nominalmex('asset_attached_dataset', obj.Client.Handle, ...
                           obj.Handle, char(name)));
        end

        function d = getOrCreateDataset(obj, name, refName, options)
            %GETORCREATEDATASET  Ensure this asset has a dataset of that name.
            %
            %   d = a.getOrCreateDataset("telemetry", "tlm");
            %   d = a.getOrCreateDataset("telemetry", "tlm", AttachExisting=false);
            %
            %   A bare name is not unique in Nominal, so this resolves in three
            %   steps and says which one it took:
            %
            %     1. A dataset of that name already attached to this asset is
            %        returned as-is.
            %     2. Otherwise a dataset of that exact name elsewhere in the
            %        workspace is attached to this asset and returned.
            %     3. Otherwise one is created and attached.
            %
            %   Step 2 is what makes "the dataset for serial 12345678" resolve
            %   to the one a colleague already made. It is also a change to
            %   your asset driven by a name match, so it announces itself and
            %   can be switched off with AttachExisting=false, which goes
            %   straight from step 1 to step 3.
            %
            %   Errors rather than guessing when several datasets share the
            %   name, naming the RIDs so you can pick one with
            %   client.datasetByRid.
            %
            %   refName addresses the dataset within this asset and must be
            %   unique among its data sources. It is used only when attaching
            %   — never to decide which dataset you meant.
            %
            %   See also NOMINAL.ASSET/GETATTACHEDDATASET, NOMINAL.CLIENT/DATASETBYRID
            arguments
                obj (1,1) nominal.Asset
                name (1,1) string
                refName (1,1) string
                options.AttachExisting (1,1) logical = true
            end
            obj.assertLive();

            [handle, outcome] = nominalmex('dataset_get_or_create', ...
                obj.Client.Handle, obj.Handle, char(name), char(refName), ...
                int32(options.AttachExisting));
            d = nominal.Dataset(obj.Client, handle);

            % Announced, not silent: two of the three branches change the
            % asset. Only the outcome is printed, never the intermediate
            % lookups — this is an interactive client, not a log source.
            switch outcome
                case 1
                    fprintf('Attached existing dataset "%s" to asset "%s" as %s\n', ...
                            name, obj.Name, refName);
                case 2
                    fprintf('Created dataset "%s" on asset "%s" as %s\n', ...
                            name, obj.Name, refName);
            end
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
                % Deliberately no defaults: stageUpdate reads field presence
                % through isfield, so "passed empty" (clear the collection) and
                % "not passed" (leave it alone) stay distinguishable. A size
                % constraint is still checked when the argument IS passed, so
                % (1,1) below costs nothing on the absent path.
                %
                % Name and Description are single strings; Labels is a list, so
                % it stays unconstrained — `string` is already an array class,
                % and the shape is the only thing that says which is meant.
                options.Name (1,1) string
                options.Description (1,1) string
                options.Properties struct
                options.Labels string
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

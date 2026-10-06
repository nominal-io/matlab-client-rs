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

        function v = get.Rid(obj)
            obj.assertLive();
            v = string(nominalmex('asset_rid', obj.Handle));
        end

        function v = get.Name(obj)
            obj.assertLive();
            v = string(nominalmex('asset_name', obj.Handle));
        end

        function v = get.Description(obj)
            obj.assertLive();
            v = string(nominalmex('asset_description', obj.Handle));
        end

        function v = get.Url(obj)
            obj.assertLive();
            v = string(nominalmex('asset_url', obj.Handle));
        end

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
            %
            %   Returns:
            %       string: The property's value.
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
            %   tlm = s(s.Type == "dataset", :);    % datasets only
            %
            %   **By default this reads the snapshot taken when the asset was
            %   fetched.** A dataset attached since then, by getOrCreateDataset
            %   or from the web app, is not listed until you pass Refresh=true:
            %
            %       a.getOrCreateDataset("telemetry", "tlm");
            %       height(a.datasources())              % unchanged
            %       height(a.datasources(Refresh=true))  % +1
            %
            %   Options:
            %       Refresh: Ask the server instead of reading the snapshot.
            %           Costs one request and does not change this object.
            %
            %   Returns:
            %       table: Variables RefName, Rid and Type, ordered by
            %       reference name. Type is "dataset", "video" or
            %       "connection"; only a dataset RID can open a stream.
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

        function addDataset(obj, dataset, refName, options)
            %ADDDATASET  Attach a dataset you already have to this asset.
            %
            %   a.addDataset(ds);
            %   a.addDataset(ds, "can");
            %   a.addDataset(ds, Tags=struct(UUT="A"));
            %   a.addDataset(ds, Tags=dictionary("test-stand", "3"));
            %
            %   Write one shared dataset with a tag per unit under test, then
            %   give each unit's asset its own slice:
            %
            %       assetA.addDataset(ds, Tags=struct(UUT="A"));
            %       assetB.addDataset(ds, Tags=struct(UUT="B"));
            %
            %   An asset holds a dataset once per tag filter. Attaching it again
            %   with the same Tags *moves* it to the new reference name; with
            %   different Tags it is added alongside, so one dataset can appear
            %   twice, split by tag:
            %
            %       a.addDataset(ds, "drone",  Tags=struct(source="drone"));
            %       a.addDataset(ds, "remote", Tags=struct(source="remote"));
            %
            %   This asset handle is a snapshot and will not show the new data
            %   source. Use a.datasources(Refresh=true) to see it.
            %
            %   Args:
            %       dataset: Any dataset handle: one fetched by RID, from a
            %           search, or from an ingest.
            %       refName: The dataset's name within this asset, unique among
            %           its data sources. Spaces, dots and mixed case are fine.
            %           It matters when one asset carries two sources measuring
            %           the same thing, say a CAN log and a test rig both
            %           reporting "engine temp". Omit it and one is chosen for
            %           you: "default" on an asset with none, otherwise the
            %           dataset's own name, otherwise that with a number.
            %
            %   Options:
            %       Tags: Limit this asset to the dataset's series carrying
            %           every one of these tags. A struct, or a dictionary
            %           (R2022b+) for a key that is not a valid field name.
            %           Values are strings; numbers are converted.
            %
            %   See also NOMINAL.ASSET/GETORCREATEDATASET, NOMINAL.ASSET/DATASOURCES
            arguments
                obj (1,1) nominal.Asset
                dataset (1,1) nominal.Dataset
                refName (1,1) string = ""
                options.Tags (1,1) {mustBeA(options.Tags, ["struct" "dictionary"])} = struct()
            end
            obj.assertLive();

            % Before freeRefName, so bad tags fail without a request.
            [tagKeys, tagValues] = keyValuePairs(options.Tags, "tag");

            explicit = refName ~= "";
            if ~explicit
                refName = obj.freeRefName(dataset.Name);
            end

            try
                nominalmex('asset_add_dataset', obj.Client.Handle, obj.Handle, ...
                           char(refName), dataset.Handle, tagKeys, tagValues);
            catch attachError
                % Only a name the caller chose can collide — one we picked was
                % free a moment ago, and a collision there means someone else
                % took it in between, which rethrow reports honestly.
                if explicit
                    obj.rethrowAttachError(attachError, refName, ...
                                           "a.addDataset(ds, ""can"")");
                end
                rethrow(attachError);
            end
        end

        function removeDataset(obj, refName)
            %REMOVEDATASET  Detach the data source with this reference name.
            %
            %   a.removeDataset("can");
            %
            %   The dataset itself is untouched, and stays on any other asset
            %   holding it. Everything else on this asset keeps its tag filter.
            %   Errors if nothing here has that reference name.
            %
            %   See also NOMINAL.ASSET/ADDDATASET, NOMINAL.ASSET/DATASOURCES
            arguments
                obj (1,1) nominal.Asset
                refName (1,1) string
            end
            obj.assertLive();
            nominalmex('asset_remove_data_source', obj.Client.Handle, obj.Handle, ...
                       char(refName));
        end

        function renameRefName(obj, oldName, newName)
            %RENAMEREFNAME  Change the reference name a data source is under.
            %
            %   a.renameRefName("default", "flight-telemetry");
            %
            %   Workbooks using this asset are updated to match. The tag
            %   filter, if any, is kept. Errors if oldName is not attached or
            %   newName already is.
            %
            %   See also NOMINAL.ASSET/DATASOURCES
            arguments
                obj (1,1) nominal.Asset
                oldName (1,1) string
                newName (1,1) string
            end
            obj.assertLive();
            try
                nominalmex('asset_rename_ref_name', obj.Client.Handle, obj.Handle, ...
                           char(oldName), char(newName));
            catch renameError
                obj.rethrowAttachError(renameError, newName, ...
                    sprintf('a.renameRefName("%s", "other")', oldName));
            end
        end

        function d = getAttachedDataset(obj, name)
            %GETATTACHEDDATASET  A dataset already on this asset, by name.
            %
            %   d = a.getAttachedDataset("telemetry");
            %
            %   Read-only: it never creates or attaches anything.
            %
            %   Errors when no dataset of that name is attached, and when more
            %   than one is. a.datasources() lists everything without erroring.
            %
            %   Returns:
            %       nominal.Dataset: The attached dataset.
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
            %   d = a.getOrCreateDataset("telemetry");
            %   d = a.getOrCreateDataset("telemetry", "tlm");
            %   d = a.getOrCreateDataset("telemetry", AttachExisting=false);
            %
            %   Dataset names are not unique in Nominal, so this resolves in
            %   three steps and prints which one it took:
            %
            %     1. A dataset of that name already attached to this asset is
            %        returned as-is.
            %     2. Otherwise a dataset of that exact name elsewhere in the
            %        workspace is attached to this asset and returned.
            %     3. Otherwise one is created and attached.
            %
            %   Step 2 finds the dataset a colleague already made, but it
            %   changes your asset based on a name match.
            %
            %   Errors when several datasets share the name, listing their RIDs
            %   so you can pick one with client.datasetByRid.
            %
            %   Args:
            %       refName: The dataset's name within this asset, used only
            %           when attaching. Omit it and a free one is chosen; see
            %           addDataset.
            %
            %   Options:
            %       AttachExisting: false skips step 2, going straight from
            %           step 1 to step 3. Defaults to true.
            %
            %   Returns:
            %       nominal.Dataset: The dataset, attached to this asset.
            %
            %   See also NOMINAL.ASSET/ADDDATASET, NOMINAL.ASSET/GETATTACHEDDATASET
            arguments
                obj (1,1) nominal.Asset
                name (1,1) string
                refName (1,1) string = ""
                options.AttachExisting (1,1) logical = true
            end
            obj.assertLive();

            explicit = refName ~= "";
            if ~explicit
                refName = obj.freeRefName(name);
            end

            try
                [handle, outcome] = nominalmex('dataset_get_or_create', ...
                    obj.Client.Handle, obj.Handle, char(name), char(refName), ...
                    int32(options.AttachExisting));
            catch createError
                if explicit
                    obj.rethrowAttachError(createError, refName, ...
                        sprintf('a.getOrCreateDataset("%s", "demo")', name));
                end
                rethrow(createError);
            end
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
            %   r = a.run("burn-12");                                 % starts now
            %   r = a.run("burn-12", datetime("now", TimeZone="UTC") - minutes(5));
            %
            %   The run is left open; close it with r.finish().
            %
            %   Args:
            %       startTime: Zoned datetime or int64 nanoseconds since the
            %           epoch. Omit it, or pass 0, to start the run now.
            %
            %   Returns:
            %       nominal.Run: The new, open run.
            %
            %   See also NOMINAL.RUN/FINISH
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
            %   Options not passed are left alone. Labels and Properties
            %   REPLACE rather than merge: passing Labels discards whatever the
            %   asset had, so read a.Labels first and concatenate if you mean
            %   to add.
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
            %       nominal.Asset: A new handle with the changes applied. The
            %       original still shows the pre-update state.
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

    methods (Access = private)
        function refName = freeRefName(obj, preferred)
            %FREEREFNAME  A reference name not already used on this asset.
            %
            %   Reference names must be unique per asset, and the caller
            %   should not have to know that. A name is a namespace for the
            %   source's channels — it matters when one asset carries two
            %   sources reporting the same channel, and is noise otherwise —
            %   so when nobody chose one, choose a free one rather than
            %   failing on a detail the caller never asked about.
            %
            %   "default" first, so the common single-source asset reads the
            %   way you would expect. Then the dataset's own name, which is
            %   at least descriptive. Then numbered.
            %
            %   Costs one request, and only when no name was supplied.

            attached = obj.datasources(Refresh=true);
            if isempty(attached)
                inUse = strings(0, 1);
            else
                inUse = attached.RefName;
            end

            for candidate = ["default", preferred]
                if ~ismember(candidate, inUse)
                    refName = candidate;
                    return
                end
            end

            suffix = 2;
            while true
                candidate = preferred + "-" + suffix;
                if ~ismember(candidate, inUse)
                    refName = candidate;
                    return
                end
                suffix = suffix + 1;
            end
        end

        function rethrowAttachError(obj, cause, refName, suggestion)
            %RETHROWATTACHERROR  Translate a refName collision, rethrow the rest.
            %
            %   Attaching and renaming can both collide, so both translate the
            %   rejection here. The server's own error is a wall of Conjure
            %   naming "data scope" — an internal concept that appears nowhere
            %   in this API — which tells the caller nothing about what to do.
            %   A rename is checked before it is sent, since the server answers
            %   that collision with an internal error.
            %
            %   suggestion is the call to show, since the entry points take the
            %   reference name in different positions.

            if contains(cause.message, ["DuplicateDataScopeNames" ...
                                        "already has a data source called"])
                error('nominal:refNameInUse', ...
                      ['asset "%s" already has a data source called "%s".\n' ...
                       'Reference names must be unique on an asset, so pass a ' ...
                       'different one:\n    %s\n' ...
                       'a.datasources(Refresh=true) lists the names in use.'], ...
                      obj.Name, refName, suggestion);
            end
            rethrow(cause);
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('asset_free', obj.Handle);
        end
    end
end

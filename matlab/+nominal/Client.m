classdef Client < nominal.Resource
    % CLIENT  An authenticated connection to Nominal.
    %
    %   Two ways to authenticate, matching the Python client:
    %
    %       c = nominal.Client.fromProfile();          % credentials on disk
    %       c = nominal.Client.fromToken("<api-key>"); % token in hand
    %
    %   Prefer fromProfile. It reads the same ~/.config/nominal/config.yml
    %   that the `nom` CLI and the Python client use, and no key ends up in a
    %   script.
    %
    %   nominal.Client(token, Workspace=rid, BaseUrl=url) is the underlying
    %   constructor. Both options are optional; an unset base URL means
    %   Nominal production. Surrounding whitespace is trimmed from all three.
    %
    %   Example:
    %       c  = nominal.Client.fromProfile();
    %       a  = c.getOrCreateAsset("engine-3");
    %       ds = a.getOrCreateDataset("telemetry", "tlm");
    %       s  = ds.stream();
    %
    %   The connection is released when c goes out of scope.
    %
    %   See also NOMINAL.ASSET, NOMINAL.DATASET, NOMINAL.RUN, NOMINAL.SHUTDOWN

    properties (Dependent, SetAccess = private)
        % Workspace this client is scoped to, or "" if unscoped.
        WorkspaceRid string
        % Base API URL being targeted.
        BaseUrl string
    end

    methods
        function obj = Client(token, options)
            arguments
                token (1,1) string
                options.Workspace (1,1) string = ""
                options.BaseUrl (1,1) string = ""
            end
            obj.Handle = nominalmex('client_new', char(token), ...
                                    char(options.Workspace), char(options.BaseUrl));
        end

        function value = get.WorkspaceRid(obj)
            obj.assertLive();
            value = string(nominalmex('client_workspace_rid', obj.Handle));
        end

        function value = get.BaseUrl(obj)
            obj.assertLive();
            value = string(nominalmex('client_base_url', obj.Handle));
        end

        function name = whoAmI(obj)
            %WHOAMI  Display name of the authenticated user.
            %
            %   Calls the API, so it doubles as a credential check.
            %
            %   Returns:
            %       string: The user's display name.
            obj.assertLive();
            name = string(nominalmex('client_user', obj.Handle));
        end

        function t = assets(obj, filter)
            %ASSETS  Assets you can see, as a table.
            %
            %   c.assets("engine")
            %   a = c.assetByRid(c.assets("engine").Rid(1));
            %
            %   With no argument it fetches EVERY asset in the workspace in
            %   one call, which on a real deployment is tens of thousands of
            %   rows. There is no page size to pass, so filter.
            %
            %   Args:
            %       filter: Keep only assets whose name contains this
            %           (case-insensitive substring). Use it to find a RID
            %           from a name.
            %
            %   Returns:
            %       table: Variables Name, Rid and Description, ordered by name.
            %
            %   See also NOMINAL.CLIENT/DATASETS
            arguments
                obj (1,1) nominal.Client
                filter (1,1) string = ""
            end
            obj.assertLive();
            if filter == ""
                s = nominalmex('asset_list', obj.Handle);
            else
                s = nominalmex('asset_search', obj.Handle, char(filter));
            end
            t = structsToTable(s, ["Name" "Rid" "Description"]);
        end

        function t = datasets(obj, filter)
            %DATASETS  Datasets you can see, as a table.
            %
            %   ds = c.datasetByRid(c.datasets("telemetry").Rid(1));
            %   ds.channels()                    % what is inside it
            %
            %   With no argument it fetches EVERY dataset in the workspace in
            %   one call. Slow on a real deployment, and there is no page size
            %   to pass, so filter.
            %
            %   Args:
            %       filter: Keep only datasets whose name contains this.
            %
            %   Returns:
            %       table: Variables Name and Rid, ordered by name.
            %
            %   See also NOMINAL.CLIENT/ASSETS, NOMINAL.DATASET/CHANNELS
            arguments
                obj (1,1) nominal.Client
                filter (1,1) string = ""
            end
            obj.assertLive();
            if filter == ""
                s = nominalmex('dataset_list', obj.Handle);
            else
                s = nominalmex('dataset_search', obj.Handle, char(filter));
            end
            t = structsToTable(s, ["Name" "Rid"]);
        end

        function a = getOrCreateAsset(obj, name)
            %GETORCREATEASSET  Fetch an asset by name, creating it if absent.
            %
            %   A typo creates a new empty asset rather than erroring, so
            %   check the name. Names are not unique in Nominal; if several
            %   match, the first is returned. Use assetByRid when you know the
            %   RID, and assets(name) to look without creating.
            %
            %   Returns:
            %       nominal.Asset: The existing or new asset.
            %
            %   See also NOMINAL.CLIENT/ASSETBYRID, NOMINAL.CLIENT/ASSETS
            arguments
                obj (1,1) nominal.Client
                name (1,1) string
            end
            obj.assertLive();
            a = nominal.Asset(obj, nominalmex('asset_get_or_create', obj.Handle, char(name)));
        end

        function a = createAsset(obj, name)
            %CREATEASSET  Create an asset, even if one of that name exists.
            %
            %   Names are not unique in Nominal, so this always makes a new
            %   one. Use getOrCreateAsset to reuse an existing asset.
            %
            %   Returns:
            %       nominal.Asset: The new asset.
            %
            %   See also NOMINAL.CLIENT/GETORCREATEASSET
            arguments
                obj (1,1) nominal.Client
                name (1,1) string
            end
            obj.assertLive();
            a = nominal.Asset(obj, nominalmex('asset_create', obj.Handle, char(name)));
        end

        function d = createDataset(obj, name)
            %CREATEDATASET  Create a dataset attached to no asset.
            %
            %   ds = c.createDataset("bench telemetry");
            %   assetA.addDataset(ds, Tags=struct(UUT="A"));
            %   assetB.addDataset(ds, Tags=struct(UUT="B"));
            %
            %   Always makes a new one, whatever its name. Attach it with
            %   asset.addDataset, to as many assets as need it.
            %
            %   Returns:
            %       nominal.Dataset: The new dataset, attached to no asset.
            %
            %   See also NOMINAL.ASSET/ADDDATASET, NOMINAL.ASSET/GETORCREATEDATASET
            arguments
                obj (1,1) nominal.Client
                name (1,1) string
            end
            obj.assertLive();
            d = nominal.Dataset(obj, nominalmex('dataset_create', obj.Handle, char(name)));
        end

        function a = assetByRid(obj, rid)
            %ASSETBYRID  Fetch an asset by RID.
            %
            %   Returns:
            %       nominal.Asset: The asset.
            arguments
                obj (1,1) nominal.Client
                rid (1,1) string
            end
            obj.assertLive();
            a = nominal.Asset(obj, nominalmex('asset_get_by_rid', obj.Handle, char(rid)));
        end

        function d = datasetByRid(obj, rid)
            %DATASETBYRID  Fetch a dataset by RID.
            %
            %   Returns:
            %       nominal.Dataset: The dataset.
            arguments
                obj (1,1) nominal.Client
                rid (1,1) string
            end
            obj.assertLive();
            d = nominal.Dataset(obj, nominalmex('dataset_get_by_rid', obj.Handle, char(rid)));
        end

        function e = createEvent(obj, assetRids, name, options)
            %CREATEEVENT  Flag a moment or interval on one or more assets.
            %
            %   e = c.createEvent(rids, "overspeed", Type="error", ...
            %                     Timestamp=t, Duration=seconds(10));
            %   e = c.createEvent(rids, "step 3", Type="success", ...
            %                     Properties=struct(status="pass", output=4.2));
            %
            %   Args:
            %       assetRids: String array of asset RIDs. At least one is
            %           required.
            %
            %   Options:
            %       Type: "info" (the default), "flag", "error" or "success".
            %       Timestamp: Zoned datetime or int64 nanoseconds. Defaults to
            %           now.
            %       Duration: A duration, or int64 nanoseconds. Defaults to
            %           zero, meaning an instantaneous event.
            %       Properties: A struct, or a dictionary for keys that aren't
            %           valid field names.
            %
            %   Returns:
            %       nominal.Event: The new event.
            arguments
                obj (1,1) nominal.Client
                assetRids (1,:) string
                name (1,1) string
                options.Type (1,1) string {mustBeMember(options.Type, ...
                    ["info" "flag" "error" "success"])} = "info"
                options.Timestamp = int64(0)
                options.Duration = seconds(0)
                options.Properties (1,1) {mustBeA(options.Properties, ["struct" "dictionary"])} = struct()
            end
            obj.assertLive();

            if isempty(assetRids)
                error('nominal:invalidParameter', ...
                      'at least one asset RID is required');
            end
            [propertyKeys, propertyValues] = keyValuePairs(options.Properties, "property");

            if isduration(options.Duration)
                durationNanos = int64(round(seconds(options.Duration) * 1e9));
            else
                durationNanos = int64(options.Duration);
            end

            e = nominal.Event(nominalmex('event_create', obj.Handle, ...
                cellstr(assetRids), char(name), char(options.Type), ...
                nominal.toNanos(options.Timestamp), durationNanos, ...
                propertyKeys, propertyValues));
        end

        function r = runByRid(obj, rid)
            %RUNBYRID  Fetch a run by RID.
            %
            %   Returns:
            %       nominal.Run: The run.
            arguments
                obj (1,1) nominal.Client
                rid (1,1) string
            end
            obj.assertLive();
            r = nominal.Run(obj, nominalmex('run_get_by_rid', obj.Handle, char(rid)));
        end

        function job = ingest(obj, path, options)
            %INGEST  Upload a CSV or Parquet file and start ingesting it.
            %
            %   job = c.ingest("flight12.csv", TimestampColumn="time", ...
            %                  NewDataset="Flight 12");
            %   job = c.ingest("run.parquet", TimestampColumn="t", ...
            %                  Dataset=ds, Kind="epoch", Unit="milliseconds");
            %
            %   Blocks while the file uploads. The server-side ingest continues
            %   afterwards; call job.wait() if you need it finished.
            %
            %   Args:
            %       path: The file. .parquet is read as Parquet, anything else
            %           as CSV.
            %
            %   Options:
            %       TimestampColumn: Name of the column holding time. Required.
            %       Dataset: An existing dataset to add to. Give either this or
            %           NewDataset.
            %       NewDataset: Name of a dataset to create. It is attached to
            %           no asset; attach it afterwards with asset.addDataset.
            %       Kind: How to read the timestamp column: "iso8601" (the
            %           default), "epoch" or "relative".
            %       Unit: For "epoch" and "relative" timestamps:
            %           "nanoseconds", "microseconds", "milliseconds",
            %           "seconds" (the default), "minutes" or "hours".
            %       Tags: Stamped on every point in the file. A struct, or a
            %           dictionary for keys that aren't valid field names.
            %
            %   Returns:
            %       nominal.IngestJob: Carries DatasetRid whichever of Dataset
            %       or NewDataset was given.
            %
            %   See also NOMINAL.INGESTJOB, NOMINAL.DATASET/WRITE
            arguments
                obj (1,1) nominal.Client
                path (1,1) string {mustBeFile}
                % Defaulted rather than left bare: a name-value with no default
                % is simply absent from options when the caller omits it, so
                % reading it would fail on a missing field rather than saying
                % what was wrong.
                options.TimestampColumn (1,1) string = ""
                options.Dataset nominal.Dataset = nominal.Dataset.empty
                options.NewDataset (1,1) string = ""
                options.Kind (1,1) string {mustBeMember(options.Kind, ...
                    ["iso8601" "epoch" "relative"])} = "iso8601"
                options.Unit (1,1) string {mustBeMember(options.Unit, ...
                    ["nanoseconds" "microseconds" "milliseconds" ...
                     "seconds" "minutes" "hours"])} = "seconds"
                options.Tags (1,1) {mustBeA(options.Tags, ["struct" "dictionary"])} = struct()
            end
            obj.assertLive();

            if options.TimestampColumn == ""
                error('nominal:invalidParameter', ...
                      'TimestampColumn= is required: name the column holding time');
            end
            [tagKeys, tagValues] = keyValuePairs(options.Tags, "tag");

            % Zero means "no existing dataset" on the C side, which is what
            % pairs with a NewDataset name.
            datasetHandle = int32(0);
            if ~isempty(options.Dataset)
                datasetHandle = options.Dataset.Handle;
            end
            if datasetHandle == 0 && options.NewDataset == ""
                error('nominal:invalidParameter', ...
                      'give either Dataset= to add to an existing dataset, or NewDataset= to create one');
            end

            if endsWith(lower(path), ".parquet")
                command = 'ingest_parquet';
            else
                command = 'ingest_csv';
            end

            [handle, datasetRid] = nominalmex(command, obj.Handle, char(path), ...
                datasetHandle, char(options.NewDataset), ...
                char(options.TimestampColumn), char(options.Kind), char(options.Unit), ...
                tagKeys, tagValues);

            job = nominal.IngestJob(obj, handle, string(datasetRid));
        end

        function t = query(obj, sql, options)
            %QUERY  Run a SQL query and return the result as a table.
            %
            %   t = c.query("SELECT ts, channel, value FROM points_double " + ...
            %               "WHERE dataset_rid = '" + ds.Rid + "' LIMIT 100")
            %
            %   The tables are the warehouse's own, so the columns differ from
            %   these classes. Telemetry tables (points_double, points_int,
            %   points_string, logs, channels) must filter on dataset_rid.
            %   Metadata tables (assets, runs, datasets, events) need not, and
            %   are capped at 10,000 rows.
            %
            %   Results are capped at 1 GiB. Use queryExportUrl for larger.
            %
            %   Options:
            %       Workspace: Workspace RID to query. SQL always needs one:
            %           the client's own is used unless this names another, and
            %           an unscoped client must give one.
            %
            %   Returns:
            %       table: One variable per column. Timestamp columns come back
            %       as int64 nanoseconds; pass them through nominal.fromNanos
            %       for a datetime.
            %
            %   See also NOMINAL.CLIENT/QUERYEXPORTURL, NOMINAL.FROMNANOS
            arguments
                obj (1,1) nominal.Client
                sql (1,1) string
                options.Workspace (1,1) string = ""
            end
            obj.assertLive();
            [names, columns] = nominalmex('sql_query', obj.Handle, ...
                                          char(sql), char(options.Workspace));

            if isempty(names)
                t = table();
                return
            end
            t = table(columns{:});

            % String columns arrive from the gateway as cellstr. Convert to
            % string so they compare with ==, matching what every listing
            % returns.
            for i = 1:width(t)
                if iscellstr(t.(i)) %#ok<ISCLSTR>
                    t.(i) = string(t.(i));
                end
            end

            % A join can legitimately produce two columns of the same name —
            % SELECT a.rid, b.rid — and MATLAB refuses duplicate variable
            % names outright. Disambiguate rather than failing on a query the
            % warehouse was happy to run.
            names = matlab.lang.makeUniqueStrings(names);

            % Assigned rather than passed to the constructor, which would
            % rewrite anything that is not a valid identifier — and a query
            % selecting `a.b AS "x y"` is entitled to that name.
            t.Properties.VariableNames = names;
        end

        function url = queryExportUrl(obj, sql, options)
            %QUERYEXPORTURL  Run a query and get a download link for the CSV.
            %
            %   For results too large for query, which is capped at 1 GiB.
            %
            %   CSV only, and only for queries on telemetry tables; one
            %   touching assets, runs, or datasets cannot be exported this way.
            %   Fails on deployments with no export bucket configured.
            %
            %   Options:
            %       Workspace: Workspace RID to query. Defaults to the client's
            %           own; an unscoped client must give one.
            %
            %   Returns:
            %       string: A time-limited download URL with no size cap.
            %
            %   See also NOMINAL.CLIENT/QUERY
            arguments
                obj (1,1) nominal.Client
                sql (1,1) string
                options.Workspace (1,1) string = ""
            end
            obj.assertLive();
            url = string(nominalmex('sql_export_url', obj.Handle, ...
                                    char(sql), char(options.Workspace)));
        end
    end

    methods (Static)
        function c = connect(name)
            %CONNECT  Connect from a stored profile, else from NOMINAL_TOKEN.
            %
            %   c = nominal.Client.connect()          % the "default" profile
            %   c = nominal.Client.connect("staging") % a named one
            %
            %   For code that runs both on a workstation (profile) and in CI
            %   (environment variable). Prefer fromProfile or fromToken when
            %   you know which you have.
            %
            %   The profile wins. NOMINAL_TOKEN carries no base URL or
            %   workspace, so falling back to it means Nominal production with
            %   no workspace scope, whatever the profile said. The fallback
            %   raises a nominal:profileFallback warning when it happens.
            %
            %   Raises nominal:noCredentials when neither is available. The
            %   message names the config file it looked in and the command
            %   that would fix it.
            %
            %   Args:
            %       name: Profile name. Defaults to "default".
            %
            %   Returns:
            %       nominal.Client: The connection.
            %
            %   See also NOMINAL.CLIENT/FROMPROFILE, NOMINAL.CLIENT/FROMTOKEN
            arguments
                name (1,1) string = "default"
            end

            try
                c = nominal.Client.fromProfile(name);
                return
            catch profileError
                % Fall through to the environment variable. The error is kept
                % because it is the more useful one to report if that is unset
                % too: it names the config file and the command to fix it.
            end

            token = string(getenv("NOMINAL_TOKEN"));
            if token == ""
                error('nominal:noCredentials', ...
                      ['no credentials found.\n\n%s\n\n' ...
                       'Alternatively set NOMINAL_TOKEN in the environment. ' ...
                       'Note that MATLAB reads the environment it was ' ...
                       'launched with — on macOS, starting MATLAB from the ' ...
                       'Dock does not pick up shell exports.'], ...
                      profileError.message);
            end

            warning('nominal:profileFallback', ...
                    ['profile "%s" could not be read, so NOMINAL_TOKEN is ' ...
                     'being used instead — that reaches Nominal production ' ...
                     'with no workspace scope, whatever the profile said. ' ...
                     'The profile error was: %s'], name, profileError.message);

            c = nominal.Client.fromToken(token);
        end

        function c = fromProfile(name, options)
            %FROMPROFILE  Connect using credentials stored on disk.
            %
            %   c = nominal.Client.fromProfile()          % the "default" profile
            %   c = nominal.Client.fromProfile("staging") % a named one
            %
            %   Reads ~/.config/nominal/config.yml, the same file the `nom`
            %   CLI and the Python client use. Set one up once with:
            %
            %       nom config profile add default -t <api-token>
            %
            %   A profile carries the base URL, the token, and optionally a
            %   workspace RID. Python equivalent:
            %
            %       client = NominalClient.from_profile("default")
            %
            %   Args:
            %       name: Profile name. Defaults to "default".
            %
            %   Options:
            %       ConfigPath: Read this config file instead of the default.
            %
            %   Returns:
            %       nominal.Client: The connection.
            %
            %   See also NOMINAL.CLIENT/FROMTOKEN
            arguments
                name (1,1) string = "default"
                options.ConfigPath (1,1) string = ""
            end

            if options.ConfigPath == ""
                profile = readProfile(name);
            else
                profile = readProfile(name, options.ConfigPath);
            end

            c = nominal.Client(profile.Token, ...
                               BaseUrl=profile.BaseUrl, ...
                               Workspace=profile.WorkspaceRid);
        end

        function c = fromToken(token, options)
            %FROMTOKEN  Connect using a token you already hold.
            %
            %   c = nominal.Client.fromToken("<api-key>")
            %   c = nominal.Client.fromToken(tok, BaseUrl="https://api.nominal.test")
            %
            %   Python equivalent: NominalClient.from_token. Prefer fromProfile
            %   where you can; a token in a script ends up in version control.
            %
            %   Args:
            %       token: API token. Surrounding whitespace is trimmed.
            %
            %   Options:
            %       Workspace: Workspace RID to scope the client to. Unset
            %           means unscoped.
            %       BaseUrl: API base URL. Unset means Nominal production.
            %
            %   Returns:
            %       nominal.Client: The connection.
            %
            %   See also NOMINAL.CLIENT/FROMPROFILE
            arguments
                token (1,1) string
                options.Workspace (1,1) string = ""
                options.BaseUrl (1,1) string = ""
            end
            c = nominal.Client(token, Workspace=options.Workspace, ...
                                      BaseUrl=options.BaseUrl);
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('client_free', obj.Handle);
        end
    end
end

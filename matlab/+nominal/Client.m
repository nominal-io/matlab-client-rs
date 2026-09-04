classdef Client < nominal.Resource
    % CLIENT  An authenticated connection to Nominal.
    %
    %   Two ways to authenticate, matching the Python client:
    %
    %       c = nominal.Client.fromProfile();          % credentials on disk
    %       c = nominal.Client.fromToken("<api-key>"); % token in hand
    %
    %   fromProfile is the recommended one. It reads the same
    %   ~/.config/nominal/config.yml that the `nom` CLI and the Python client
    %   use, so a machine set up for either already works here — and no key
    %   ends up pasted into a script.
    %
    %   nominal.Client(token, Workspace=rid, BaseUrl=url) is the underlying
    %   constructor. Both options are optional; the API does not require a
    %   workspace, and an unset base URL means Nominal production.
    %
    %   Surrounding whitespace is trimmed from all three, so a token pasted
    %   with a trailing newline still authenticates.
    %
    %   Example:
    %       c  = nominal.Client.fromProfile();
    %       a  = c.getOrCreateAsset("engine-3");
    %       ds = a.getOrCreateDataset("telemetry", "tlm");
    %       s  = ds.stream();
    %
    %   The connection is released automatically when c goes out of scope.
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
            %   Round-trips to the API, so it doubles as a credential check: a
            %   bad token fails here rather than at the first real call.
            obj.assertLive();
            name = string(nominalmex('client_user', obj.Handle));
        end

        function t = assets(obj, filter)
            %ASSETS  Every asset you can see, as a table.
            %
            %   Variables: Name, Rid, Description. Ordered by name.
            %
            %   With one argument, keeps only assets whose name contains it —
            %   a case-insensitive substring match, not a pattern. This is how
            %   you find a RID when all you have is a name:
            %
            %       c.assets("engine")
            %       a = c.assetByRid(c.assets("engine").Rid(1));
            %
            %   With no argument it fetches EVERY asset in the workspace, in
            %   one unpaginated call. That is tens of thousands of rows on a
            %   real deployment and takes correspondingly long — there is no
            %   limit or page size to pass, so filter unless you genuinely
            %   want the lot.
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
            %DATASETS  Every dataset you can see, as a table.
            %
            %   Variables: Name, Rid. Ordered by name. With one argument, keeps
            %   only datasets whose name contains it.
            %
            %       ds = c.datasetByRid(c.datasets("telemetry").Rid(1));
            %
            %   With no argument it fetches EVERY dataset in the workspace, in
            %   one unpaginated call — slow on a real deployment, and there is
            %   no limit to pass. Filter unless you want all of them.
            %
            %   To see what is inside one, use its channels:
            %
            %       ds.channels()
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
            %   Named for what it does. A lookup that silently creates on a
            %   typo is worth spelling out at the call site, because the
            %   evidence of the mistake is a new empty asset rather than an
            %   error.
            %
            %   Name is not unique in Nominal; if several match, the first is
            %   returned. Prefer assetByRid when you already know the RID, and
            %   assets(name) when you want to look without creating.
            %
            %   See also NOMINAL.CLIENT/ASSETBYRID, NOMINAL.CLIENT/ASSETS
            arguments
                obj (1,1) nominal.Client
                name (1,1) string
            end
            obj.assertLive();
            a = nominal.Asset(obj, nominalmex('asset_get_or_create', obj.Handle, char(name)));
        end

        function a = assetByRid(obj, rid)
            %ASSETBYRID  Fetch an asset by RID.
            arguments
                obj (1,1) nominal.Client
                rid (1,1) string
            end
            obj.assertLive();
            a = nominal.Asset(obj, nominalmex('asset_get_by_rid', obj.Handle, char(rid)));
        end

        function d = datasetByRid(obj, rid)
            %DATASETBYRID  Fetch a dataset by RID.
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
            %
            %   assetRids is a string array of asset RIDs; at least one is
            %   required, since an event with no asset is not created. Pass
            %   asset objects' .Rid, or the RIDs directly.
            %
            %   Type is one of info, flag, error, success. Timestamp accepts a
            %   zoned datetime or int64 nanoseconds, and defaults to now.
            %   Duration defaults to zero, meaning an instantaneous event.
            arguments
                obj (1,1) nominal.Client
                assetRids (1,:) string
                name (1,1) string
                options.Type (1,1) string {mustBeMember(options.Type, ...
                    ["info" "flag" "error" "success"])} = "info"
                options.Timestamp = int64(0)
                options.Duration = seconds(0)
            end
            obj.assertLive();

            if isempty(assetRids)
                error('nominal:invalidParameter', ...
                      'at least one asset RID is required');
            end

            if isduration(options.Duration)
                durationNanos = int64(round(seconds(options.Duration) * 1e9));
            else
                durationNanos = int64(options.Duration);
            end

            e = nominal.Event(nominalmex('event_create', obj.Handle, ...
                cellstr(assetRids), char(name), char(options.Type), ...
                nominal.toNanos(options.Timestamp), durationNanos));
        end

        function r = runByRid(obj, rid)
            %RUNBYRID  Fetch a run by RID.
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
            %   The format is taken from the file extension: .parquet is
            %   Parquet, anything else is CSV.
            %
            %   Give either Dataset (add to an existing one) or NewDataset (a
            %   name to create). The returned job carries DatasetRid either
            %   way, which is how you find a dataset this call just made.
            %
            %   Kind says how to read the timestamp column: iso8601 (the
            %   default), epoch, or relative. Unit applies to the latter two
            %   and is ignored for ISO 8601.
            %
            %   Blocks while the file uploads, which for a large file is a long
            %   time. The ingest itself continues afterwards — call job.wait()
            %   if you need it finished before moving on.
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
            end
            obj.assertLive();

            if options.TimestampColumn == ""
                error('nominal:invalidParameter', ...
                      'TimestampColumn= is required: name the column holding time');
            end

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
                char(options.TimestampColumn), char(options.Kind), char(options.Unit));

            job = nominal.IngestJob(obj, handle, string(datasetRid));
        end

        function t = query(obj, sql, options)
            %QUERY  Run a SQL query and return the result as a table.
            %
            %   t = c.query("SELECT ts, channel, value FROM points_double " + ...
            %               "WHERE dataset_rid = '" + ds.Rid + "' LIMIT 100")
            %
            %   The tables are the warehouse's own, not the object model, so
            %   the columns are not the ones these classes expose. Telemetry
            %   tables (points_double, points_int, points_string, logs,
            %   channels) must filter on dataset_rid. Metadata tables (assets,
            %   runs, datasets, events) need not, and are capped at 10,000
            %   rows.
            %
            %   Timestamp columns come back as int64 nanoseconds since the
            %   epoch, whatever resolution the warehouse sent — pass them
            %   through nominal.fromNanos for a datetime.
            %
            %   The SQL service always needs a workspace, even though the rest
            %   of the API does not. The client's own workspace is used unless
            %   Workspace= names another; if the client is unscoped, one must
            %   be given here.
            %
            %   Bounded at 1 GiB. Use queryExportUrl for anything larger.
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
            %   For results too large for query, which is capped at 1 GiB. The
            %   export runs without that cap, writes to object storage, and
            %   returns a time-limited presigned URL.
            %
            %   CSV only, and only for queries reading telemetry tables — one
            %   touching assets, runs, or datasets cannot be exported this way.
            %   Some deployments have no export bucket configured, in which
            %   case this fails.
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
        function c = fromProfile(name, options)
            %FROMPROFILE  Connect using credentials stored on disk.
            %
            %   c = nominal.Client.fromProfile()          % the "default" profile
            %   c = nominal.Client.fromProfile("staging") % a named one
            %
            %   Reads ~/.config/nominal/config.yml — the same file the `nom`
            %   CLI and the Python client use. Set one up once with:
            %
            %       nom config profile add default -t <api-token>
            %
            %   A profile carries the base URL, the token, and optionally a
            %   workspace RID, so nothing else needs passing and no key ends
            %   up in a script. The MATLAB call is the counterpart of Python's
            %
            %       client = NominalClient.from_profile("default")
            %
            %   ConfigPath= reads a file somewhere else, which is mainly
            %   useful in CI where the home directory is not the user's.
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
            %   The counterpart of Python's NominalClient.from_token. Prefer
            %   fromProfile where you can: a token in a script is a token in
            %   version control eventually.
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

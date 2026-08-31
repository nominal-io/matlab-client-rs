classdef Client < nominal.Resource
    % CLIENT  An authenticated connection to Nominal.
    %
    %   c = nominal.Client(token) connects to Nominal production.
    %   c = nominal.Client(token, Workspace=rid, BaseUrl=url) scopes the
    %   client to a workspace and/or targets a different deployment. Both are
    %   optional; the API does not require a workspace.
    %
    %   Surrounding whitespace is trimmed from all three, so a token pasted
    %   with a trailing newline still authenticates.
    %
    %   Example:
    %       c  = nominal.Client(getenv("NOMINAL_TOKEN"));
    %       a  = c.asset("engine-3");
    %       ds = a.dataset("telemetry", "tlm");
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
            % Every path into the library starts here or at nominal.now, so
            % this is where the DLL search path gets established.
            nominal.setup();
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

        function list = assets(obj, filter)
            %ASSETS  Every asset you can see, as a struct array.
            %
            %   Fields: Name, Rid, Description. Ordered by name.
            %
            %   With no argument, lists everything. With one, keeps only assets
            %   whose name contains it — a case-insensitive substring match, not
            %   a pattern.
            %
            %   This is where you start when you have no RID:
            %
            %       struct2table(c.assets())
            %       struct2table(c.assets("engine"))
            %
            %   See also NOMINAL.CLIENT/DATASETS
            arguments
                obj (1,1) nominal.Client
                filter (1,1) string = ""
            end
            obj.assertLive();
            if filter == ""
                list = nominalmex('asset_list', obj.Handle);
            else
                list = nominalmex('asset_search', obj.Handle, char(filter));
            end
        end

        function list = datasets(obj, filter)
            %DATASETS  Every dataset you can see, as a struct array.
            %
            %   Fields: Name, Rid. Ordered by name. With one argument, keeps
            %   only datasets whose name contains it.
            %
            %       struct2table(c.datasets())
            %       ds = c.datasetByRid(c.datasets("telemetry")(1).Rid);
            %
            %   To see what is inside one, use its channels:
            %
            %       struct2table(ds.channels())
            %
            %   See also NOMINAL.CLIENT/ASSETS, NOMINAL.DATASET/CHANNELS
            arguments
                obj (1,1) nominal.Client
                filter (1,1) string = ""
            end
            obj.assertLive();
            if filter == ""
                list = nominalmex('dataset_list', obj.Handle);
            else
                list = nominalmex('dataset_search', obj.Handle, char(filter));
            end
        end

        function a = asset(obj, name)
            %ASSET  Fetch an asset by name, creating it if none has that name.
            %
            %   Name is not unique in Nominal; if several match, the first is
            %   returned. Prefer assetByRid when you already know the RID.
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
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('client_free', obj.Handle);
        end
    end
end

classdef Run < nominal.Resource
    % RUN  A bounded time window of activity on an asset.
    %
    %   Created on an asset, or fetched by RID:
    %
    %       r = a.run("burn-12");           % starts now, left open
    %       r = c.runByRid(rid);
    %
    %   Closing it:
    %
    %       r = r.finish();                 % ends now
    %
    %   Times are datetime on the way out, and accept either datetime or int64
    %   nanoseconds on the way in.
    %
    %   See also NOMINAL.ASSET, NOMINAL.DATASET

    properties (Dependent, SetAccess = private)
        Rid string          % Resource identifier.
        Name string         % Display name.
        Description string  % Description.
        Number uint32       % Sequential run number within the workspace.
        Url string          % Web URL in the Nominal app.
        Labels string       % All labels, as a string array.
        StartTime datetime  % When the run began, UTC.
        EndTime datetime    % When it ended, or NaT while still open.
    end

    properties (Access = private)
        Client nominal.Client
    end

    methods
        function obj = Run(client, handle)
            % Constructed by nominal.Client or nominal.Asset; not called directly.
            arguments
                client (1,1) nominal.Client
                handle (1,1) int32
            end
            obj.Client = client;
            obj.Handle = handle;
        end

        function v = get.Rid(obj);         obj.assertLive(); v = string(nominalmex('run_rid', obj.Handle));         end
        function v = get.Name(obj);        obj.assertLive(); v = string(nominalmex('run_name', obj.Handle));        end
        function v = get.Description(obj); obj.assertLive(); v = string(nominalmex('run_description', obj.Handle)); end
        function v = get.Url(obj);         obj.assertLive(); v = string(nominalmex('run_url', obj.Handle));         end
        function v = get.Number(obj);      obj.assertLive(); v = nominalmex('run_number', obj.Handle);              end

        function v = get.StartTime(obj)
            obj.assertLive();
            v = nominal.fromNanos(nominalmex('run_start_time', obj.Handle));
        end

        function v = get.EndTime(obj)
            obj.assertLive();
            [nanos, hasEnd] = nominalmex('run_end_time', obj.Handle);
            if hasEnd
                v = nominal.fromNanos(nanos);
            else
                % NaT rather than an error: an open run legitimately has no
                % end, and 0 would be a real instant.
                v = NaT('TimeZone', 'UTC');
            end
        end

        function v = get.Labels(obj)
            obj.assertLive();
            n = double(nominalmex('run_label_count', obj.Handle));
            v = strings(1, n);
            for i = 1:n
                v(i) = string(nominalmex('run_label_at', obj.Handle, int32(i - 1)));
            end
        end

        function value = property(obj, key)
            %PROPERTY  Value of one property. Errors if the key is absent.
            arguments
                obj (1,1) nominal.Run
                key (1,1) string
            end
            obj.assertLive();
            value = string(nominalmex('run_property', obj.Handle, char(key)));
        end

        function updated = finish(obj, endTime)
            %FINISH  Close the run, returning the updated run.
            %
            %   endTime may be a datetime or int64 nanoseconds. Omit it to end
            %   the run now, which is the usual case.
            arguments
                obj (1,1) nominal.Run
                endTime = int64(0)
            end
            obj.assertLive();
            updated = nominal.Run(obj.Client, ...
                nominalmex('run_set_end_time', obj.Client.Handle, obj.Handle, ...
                           nominal.toNanos(endTime)));
        end

        function updated = addDataset(obj, refName, dataset)
            %ADDDATASET  Attach a dataset under a reference name.
            %
            %   The reference name addresses the dataset within this run and
            %   must be unique among its data sources.
            arguments
                obj (1,1) nominal.Run
                refName (1,1) string
                dataset (1,1) nominal.Dataset
            end
            obj.assertLive();
            updated = nominal.Run(obj.Client, ...
                nominalmex('run_add_dataset', obj.Client.Handle, obj.Handle, ...
                           char(refName), dataset.Handle));
        end

        function updated = update(obj, options)
            %UPDATE  Apply metadata changes, returning the updated run.
            %
            %   Honours start and end times as well as the shared fields.
            %   Collections REPLACE rather than merge — see nominal.Asset.update.
            arguments
                obj (1,1) nominal.Run
                % No defaults on the shared fields, so stageUpdate can tell
                % "passed empty" (clear) from "not passed" (leave alone) — see
                % nominal.Asset.update. Times keep a sentinel: there is no
                % "clear" for them, so [] simply means unset.
                options.Name string
                options.Description string
                options.Properties struct
                options.Labels string
                options.StartTime = []
                options.EndTime = []
            end
            obj.assertLive();
            u = obj.stageUpdate(options);
            cleanup = onCleanup(@() nominalmex('update_free', u));

            if ~isempty(options.StartTime)
                nominalmex('update_set_start', u, nominal.toNanos(options.StartTime));
            end
            if ~isempty(options.EndTime)
                nominalmex('update_set_end', u, nominal.toNanos(options.EndTime));
            end

            updated = nominal.Run(obj.Client, ...
                nominalmex('run_update_commit', obj.Client.Handle, obj.Handle, u));
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('run_free', obj.Handle);
        end
    end
end

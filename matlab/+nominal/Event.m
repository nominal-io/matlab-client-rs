classdef Event < nominal.Resource
    % EVENT  A time-based annotation on one or more assets.
    %
    %   Events flag a moment or interval: a fault, a phase boundary, an
    %   anomaly. Created from a client:
    %
    %       e = c.createEvent(["ri.scout...asset..."], "overspeed", ...
    %                         Type="error", Duration=seconds(10));
    %
    %   Events attach to **assets**, not to runs or datasets. A run shows the
    %   events whose time falls within it.
    %
    %   See also NOMINAL.CLIENT, NOMINAL.ASSET

    properties (Dependent, SetAccess = private)
        Rid string          % Resource identifier.
        Name string         % Display name.
        Type string         % "info", "flag", "error", or "success".
        Timestamp datetime  % When it occurred, UTC.
        Duration duration    % How long it spans; zero for an instant.
        AssetRids string    % Assets it is attached to.
    end

    methods
        function obj = Event(handle)
            % Constructed by nominal.Client.createEvent; not called directly.
            arguments
                handle (1,1) int32
            end
            obj.Handle = handle;
        end

        function v = get.Rid(obj);  obj.assertLive(); v = string(nominalmex('event_rid', obj.Handle));  end
        function v = get.Name(obj); obj.assertLive(); v = string(nominalmex('event_name', obj.Handle)); end
        function v = get.Type(obj); obj.assertLive(); v = string(nominalmex('event_type', obj.Handle)); end

        function v = get.Timestamp(obj)
            obj.assertLive();
            v = nominal.fromNanos(nominalmex('event_timestamp', obj.Handle));
        end

        function v = get.Duration(obj)
            obj.assertLive();
            nanos = nominalmex('event_duration', obj.Handle);
            % seconds() takes a double, which is exact to 2^53 ns — about 104
            % days. Event durations are far below that, unlike absolute
            % timestamps where the same conversion would be lossy.
            v = seconds(double(nanos) / 1e9);
        end

        function v = get.AssetRids(obj)
            obj.assertLive();
            v = string(nominalmex('event_assets', obj.Handle));
            v = reshape(v, 1, []);
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('event_free', obj.Handle);
        end
    end
end

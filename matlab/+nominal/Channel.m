classdef Channel < nominal.Resource
    % CHANNEL  A write address for one named series on a stream.
    %
    %   A channel in Nominal is a named series within a dataset — roughly a
    %   column. This object is the address points are written to: a stream, a
    %   name, and the tags to stamp on each point. Creating one performs no API
    %   call; the channel appears in Nominal when the first point arrives.
    %
    %       ch = s.channel("rpm");
    %       ch.tag("bank", "1");
    %       ch.push(timestamps, values);
    %
    %   Tags belong to points rather than to the channel, so changing them
    %   partway through acquisition is legal: earlier points keep the tags they
    %   were sent with, later ones carry the new set, and all of them land in
    %   the same channel. That is how a multiplexed channel is written — one
    %   address per tag set, all sharing a name.
    %
    %   Keep tag cardinality low. Anything that changes every point belongs in
    %   its own channel; used as a tag it degrades queries.
    %
    %   For several channels sharing one clock, nominal.Stream.push is faster —
    %   one call rather than one per channel.
    %
    %   See also NOMINAL.STREAM

    properties (Dependent, SetAccess = private)
        Name string  % Channel name this address writes under.
    end

    methods
        function obj = Channel(handle)
            % Constructed by nominal.Stream.channel; not called directly.
            arguments
                handle (1,1) int32
            end
            obj.Handle = handle;
        end

        function v = get.Name(obj)
            obj.assertLive();
            v = string(nominalmex('channel_name', obj.Handle));
        end

        function tag(obj, key, value)
            %TAG  Stamp a key-value pair on every point written from here on.
            arguments
                obj (1,1) nominal.Channel
                key (1,1) string
                value (1,1) string
            end
            obj.assertLive();
            nominalmex('channel_set_tag', obj.Handle, char(key), char(value));
        end

        function push(obj, timestamps, values)
            %PUSH  Write a batch of samples to this channel.
            %
            %   timestamps is int64 nanoseconds or a datetime vector; values is
            %   a double vector of the same length. Timestamps are literal,
            %   including zero.
            %
            %   Blocks if the stream has saturated.
            arguments
                obj (1,1) nominal.Channel
                timestamps
                values (:,1) double
            end
            obj.assertLive();
            nominalmex('channel_push', obj.Handle, ...
                       nominal.toNanosVector(timestamps), values);
        end

        function s = stream(obj)
            %STREAM  Handle of the stream this address writes to.
            %
            %   Returns the raw int32 rather than a nominal.Stream, because the
            %   stream is owned elsewhere and wrapping it here would create a
            %   second object that frees the same handle.
            obj.assertLive();
            s = nominalmex('channel_stream', obj.Handle);
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('channel_free', obj.Handle);
        end
    end
end

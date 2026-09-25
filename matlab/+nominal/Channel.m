classdef Channel < nominal.Resource
    % CHANNEL  A write address for one named series on a stream.
    %
    %   A channel is a named series within a dataset, roughly a column. This
    %   object is where points for it are written: a stream, a name, and the
    %   tags to stamp on each point. Creating one makes no API call; the
    %   channel appears in Nominal when the first point arrives.
    %
    %       ch = s.channel("rpm");
    %       ch.tag("bank", "1");
    %       ch.push(timestamps, values);
    %
    %   Tags belong to points, not to the channel. Earlier points keep the tags
    %   they were sent with, later ones carry the new set, and all land in the
    %   same channel. Keep tag cardinality low: anything that changes every
    %   point belongs in its own channel.
    %
    %   For several channels sharing one clock, nominal.Stream.push is faster.
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
            %STREAM  Raw int32 handle of the stream this channel writes to.
            %
            %   Not a nominal.Stream object, since the stream is owned by the
            %   object you opened it from.
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

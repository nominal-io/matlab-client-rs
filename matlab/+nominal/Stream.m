classdef Stream < nominal.Resource
    % STREAM  An open write path into a dataset.
    %
    %   Opened from a dataset:
    %
    %       s = ds.stream();
    %
    %   The fastest path is a block of samples sharing one clock:
    %
    %       chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];
    %       t = zeros(1000, 1, 'int64');
    %       v = zeros(1000, 3);            % one column per channel
    %       ... fill in a loop ...
    %       s.push(chans, t, v);
    %
    %   Preallocate the matrix, fill it, push it. It reaches the library with
    %   no copy.
    %
    %   Releasing the stream flushes what is still buffered and blocks until
    %   that completes. MATLAB does not promise when a variable is collected,
    %   so call delete(s) if you need the data to have landed before moving
    %   on.
    %
    %   push blocks when the stream saturates: if points arrive faster than
    %   the network drains them, it waits instead of queueing without bound.
    %
    %   See also NOMINAL.CHANNEL, NOMINAL.DATASET

    methods
        function obj = Stream(handle)
            % Constructed by nominal.Dataset.stream; not called directly.
            arguments
                handle (1,1) int32
            end
            obj.Handle = handle;
        end

        function ch = channel(obj, name)
            %CHANNEL  A write address for a named channel on this stream.
            %
            %   Performs no API call; the channel appears in Nominal when the
            %   first point arrives.
            arguments
                obj (1,1) nominal.Stream
                name (1,1) string
            end
            obj.assertLive();
            ch = nominal.Channel(nominalmex('channel_create', obj.Handle, char(name)));
        end

        function push(obj, channels, timestamps, values)
            %PUSH  Write an N-by-C block of samples across C channels.
            %
            %   channels   1-by-C array of nominal.Channel
            %   timestamps N-by-1 int64 nanoseconds, or a datetime vector
            %   values     N-by-C double, one column per channel
            %
            %   All channels share the timestamp column. For channels on
            %   independent clocks, push each separately with Channel.push.
            %
            %   Timestamps are literal, including zero. Unlike run times, 0
            %   does not mean "now".
            arguments
                obj (1,1) nominal.Stream
                channels (1,:) nominal.Channel
                timestamps
                values (:,:) double
            end
            obj.assertLive();

            if numel(channels) ~= size(values, 2)
                error('nominal:invalidParameter', ...
                      'values has %d columns but %d channels were given', ...
                      size(values, 2), numel(channels));
            end

            handles = int32(arrayfun(@(c) c.Handle, channels));
            nominalmex('channel_push_matrix', handles, ...
                       nominal.toNanosVector(timestamps), values);
        end

    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('stream_free', obj.Handle);
        end
    end
end

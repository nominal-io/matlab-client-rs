classdef Stream < nominal.Resource
    % STREAM  An open write path into a dataset.
    %
    %   Opened from a dataset:
    %
    %       s = ds.stream();
    %
    %   Writing a block of synchronised samples — the usual shape for data
    %   acquisition, and the fastest path from MATLAB:
    %
    %       chans = [s.channel("rpm"), s.channel("egt"), s.channel("psi")];
    %       t = zeros(1000, 1, 'int64');
    %       v = zeros(1000, 3);            % one column per channel
    %       ... fill in a loop ...
    %       s.push(chans, t, v);
    %
    %   MATLAB stores v column-major, so each channel's samples are already
    %   contiguous in memory and go to the library with no copy or transpose.
    %   Filling a preallocated matrix and pushing it is therefore both the
    %   idiomatic MATLAB pattern and the efficient one — there is no need for
    %   the row-by-row buffer the C and LabVIEW paths use.
    %
    %   Releasing the stream flushes whatever is still buffered, and blocks
    %   until that completes. That happens automatically, but MATLAB does not
    %   promise exactly when a variable is collected, so call delete(s)
    %   explicitly if you need the data to have landed before moving on.
    %
    %   Writing blocks when the stream saturates: if points arrive faster than
    %   the network drains them, push waits rather than queueing without bound.
    %
    %   See also NOMINAL.CHANNEL, NOMINAL.DATASET, NOMINAL.BUFFER

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
            %   All channels share the timestamp column, which is the DAQ case:
            %   one sample per channel per tick against a common clock. For
            %   channels on independent clocks, push each separately.
            %
            %   Timestamps are literal here, including zero — unlike run times,
            %   0 does not mean "now", since a stream may carry timestamps
            %   relative to an epoch you chose.
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

        function b = buffer(obj, channels, capacity)
            %BUFFER  A row-at-a-time accumulator, for parity with C and LabVIEW.
            %
            %   Most MATLAB code should preallocate a matrix and use push
            %   instead — see the class help. This exists so that a procedure
            %   written against the C or LabVIEW API translates line for line.
            arguments
                obj (1,1) nominal.Stream
                channels (1,:) nominal.Channel
                capacity (1,1) double {mustBePositive, mustBeInteger}
            end
            obj.assertLive();
            b = nominal.Buffer(channels, capacity);
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('stream_free', obj.Handle);
        end
    end
end

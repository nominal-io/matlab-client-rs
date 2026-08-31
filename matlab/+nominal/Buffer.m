classdef Buffer < nominal.Resource
    % BUFFER  A row-at-a-time accumulator across several channels.
    %
    %   Provided for parity with the C and LabVIEW APIs, so a procedure written
    %   against those translates line for line. Most MATLAB code should
    %   preallocate a matrix and use nominal.Stream.push instead, which is both
    %   more idiomatic and faster — see nominal.Stream.
    %
    %       b = s.buffer(chans, 1000);
    %       while acquiring
    %           full = b.store(t, [rpm egt psi]);
    %           if full, b.commit(); end
    %       end
    %       b.commit();     % the partial tail
    %
    %   Channels must all belong to one stream: a buffer commits as a single
    %   batch, so a mixture would have nowhere to go.
    %
    %   See also NOMINAL.STREAM

    properties (Dependent, SetAccess = private)
        Rows uint32      % Rows currently held.
        Capacity uint32  % Rows it can hold before commit is required.
    end

    methods
        function obj = Buffer(channels, capacity)
            % Usually reached through nominal.Stream.buffer.
            arguments
                channels (1,:) nominal.Channel
                capacity (1,1) double {mustBePositive, mustBeInteger}
            end
            handles = int32(arrayfun(@(c) c.Handle, channels));
            obj.Handle = nominalmex('buffer_alloc', handles, int32(capacity));
        end

        function v = get.Rows(obj)
            obj.assertLive();
            [v, ~] = nominalmex('buffer_status', obj.Handle);
        end

        function v = get.Capacity(obj)
            obj.assertLive();
            [~, v] = nominalmex('buffer_status', obj.Handle);
        end

        function isFull = store(obj, timestamp, row)
            %STORE  Append one row: a timestamp and one value per channel.
            %
            %   Returns true when the buffer has no room for another row.
            %   Commit then — storing into a full buffer errors rather than
            %   overwriting, and a wrong-length row is rejected whole rather
            %   than misaligning every channel.
            arguments
                obj (1,1) nominal.Buffer
                timestamp
                row (:,1) double
            end
            obj.assertLive();
            isFull = nominalmex('buffer_store', obj.Handle, ...
                                nominal.toNanos(timestamp), row);
        end

        function commit(obj)
            %COMMIT  Send everything held to the stream, then empty for reuse.
            %
            %   Committing an empty buffer does nothing, so this can be called
            %   unconditionally to flush a partial tail. Blocks while the
            %   stream is saturated; a failed commit leaves the rows intact to
            %   retry.
            obj.assertLive();
            nominalmex('buffer_commit', obj.Handle);
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            % Uncommitted rows are discarded — commit first if the tail matters.
            nominalmex('buffer_free', obj.Handle);
        end
    end
end

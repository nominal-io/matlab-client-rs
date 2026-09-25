classdef IngestJob < nominal.Resource
    % INGESTJOB  A file upload that Nominal is still working through.
    %
    %   Returned by nominal.Client.ingest. The upload has finished by the time
    %   you hold one of these; the server-side ingest is still running.
    %
    %       job = c.ingest("flight12.csv", TimestampColumn="time", ...
    %                      NewDataset="Flight 12");
    %       ds  = c.datasetByRid(job.DatasetRid);   % usable straight away
    %       job.wait();                             % block until ingest ends
    %
    %   See also NOMINAL.CLIENT/INGEST

    properties (Dependent, SetAccess = private)
        Rid string  % Resource identifier of the job itself.
    end

    properties (SetAccess = immutable)
        % RID of the dataset the data is landing in, including one the
        % ingest call just created.
        DatasetRid string
    end

    properties (Access = private)
        Client nominal.Client
    end

    methods
        function obj = IngestJob(client, handle, datasetRid)
            % Constructed by nominal.Client.ingest; not called directly.
            arguments
                client (1,1) nominal.Client
                handle (1,1) int32
                datasetRid (1,1) string
            end
            obj.Client = client;
            obj.Handle = handle;
            obj.DatasetRid = datasetRid;
        end

        function v = get.Rid(obj)
            obj.assertLive();
            v = string(nominalmex('ingest_job_rid', obj.Handle));
        end

        function s = status(obj)
            %STATUS  Read the job's current state from the server.
            %
            %   One of submitted, queued, inProgress, completed, failed, or
            %   cancelled. The first three mean it is still running.
            obj.assertLive();
            s = string(nominalmex('ingest_status', obj.Client.Handle, obj.Handle));
        end

        function s = wait(obj)
            %WAIT  Block until the job finishes.
            %
            %   Returns "completed" when the ingest succeeds, and RAISES
            %   nominal:nominalError when it fails. Wrap it if a failure is
            %   something you want to report rather than throw:
            %
            %       try
            %           job.wait();
            %       catch e
            %           % the ingest failed; e.message says why
            %       end
            %
            %   Or poll status() in a loop. No timeout, so a stuck job blocks
            %   indefinitely.
            obj.assertLive();
            s = string(nominalmex('ingest_wait', obj.Client.Handle, obj.Handle));
        end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            % Releasing the handle does not cancel the ingest.
            nominalmex('ingest_job_free', obj.Handle);
        end
    end
end

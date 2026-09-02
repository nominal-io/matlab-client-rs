classdef IngestJob < nominal.Resource
    % INGESTJOB  A file upload that Nominal is still working through.
    %
    %   Returned by nominal.Client.ingest. The upload itself has already
    %   finished by the time you hold one of these — what is outstanding is the
    %   server-side ingest, which continues after the request returns.
    %
    %       job = c.ingest("flight12.csv", TimestampColumn="time", ...
    %                      NewDataset="Flight 12");
    %       ds  = c.datasetByRid(job.DatasetRid);   % usable straight away
    %       job.wait();                             % block until ingest ends
    %
    %   Status is a method rather than a property because reading it costs a
    %   round trip: a property that quietly hits the network would fire on
    %   every display and every tab-complete.
    %
    %   See also NOMINAL.CLIENT/INGEST

    properties (Dependent, SetAccess = private)
        Rid string  % Resource identifier of the job itself.
    end

    properties (SetAccess = immutable)
        % RID of the dataset the data is landing in. This is how you find a
        % dataset that the ingest call just created, so it is captured at
        % construction rather than fetched.
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
            %STATUS  Re-read the job's state from the server.
            %
            %   One of submitted, queued, inProgress, completed, failed, or
            %   cancelled. The first three mean it is still moving.
            %
            %   The handle holds the state as of when it was created, so this
            %   fetches a fresh one rather than reporting something stale.
            obj.assertLive();
            s = string(nominalmex('ingest_status', obj.Client.Handle, obj.Handle));
        end

        function s = wait(obj)
            %WAIT  Block until the job finishes, then report how it ended.
            %
            %   Returns "completed", "failed", or "cancelled". A failed ingest
            %   comes back as a status rather than an error: the call did what
            %   it was asked, and the ingest failing is a result.
            %
            %   Polls server-side with no timeout, so a wedged job blocks
            %   indefinitely. Loop on status() yourself if you need one.
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

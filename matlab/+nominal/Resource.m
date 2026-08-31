classdef (Abstract) Resource < handle
    % RESOURCE  Base for every Nominal object that owns a library handle.
    %
    %   Subclasses hold an int32 handle into a registry owned by the Nominal
    %   shared library. This class exists so that releasing one is automatic:
    %   MATLAB calls delete() when the last reference goes out of scope, which
    %   frees the handle. Nothing here needs a manual free, unlike the C and
    %   LabVIEW paths where forgetting one is a leak.
    %
    %   Deriving from handle (rather than value semantics) is deliberate:
    %   copying a Nominal object must alias the same underlying resource, not
    %   duplicate a handle that would then be freed twice.

    properties (SetAccess = protected, GetAccess = public)
        % The library handle. Exposed read-only mainly for diagnostics; zero
        % once released.
        Handle (1,1) int32 = 0
    end

    %   Note there is no isvalid override here: `handle` seals it, and the
    %   inherited one already reports false once delete has run — which
    %   releases the library handle on the way through.

    methods (Abstract, Access = protected)
        % Release the handle. Implemented per type because each has its own
        % free function; freeing an unknown handle is a no-op in every case.
        releaseHandle(obj)
    end

    methods
        function delete(obj)
            if obj.Handle ~= 0
                % Never let a destructor throw: MATLAB runs these during
                % cleanup and workspace clearing, where an error is disruptive
                % and usually unactionable.
                try
                    obj.releaseHandle();
                catch
                end
                obj.Handle = 0;
            end
        end
    end

    methods (Access = protected)
        function assertLive(obj)
            if obj.Handle == 0
                error('nominal:released', ...
                      '%s has already been released', class(obj));
            end
        end
    end

    methods (Static, Access = protected)
        function u = stageUpdate(options)
            %STAGEUPDATE  Build a staged update from name-value options.
            %
            %   Shared by Asset, Dataset, and Run, whose update() methods take
            %   the same four fields. The caller owns the returned handle and
            %   must free it — committing does not consume it.
            %
            %   Lives here rather than in a subpackage because only code in
            %   this folder can reach the private MEX gateway.
            u = nominalmex('update_begin');

            if ~isempty(options.Name)
                nominalmex('update_set_name', u, char(options.Name));
            end
            if ~isempty(options.Description)
                nominalmex('update_set_description', u, char(options.Description));
            end

            % An empty-but-present collection means "clear", which is distinct
            % from not passing it at all. MATLAB cannot tell those apart from
            % the value alone, so emptiness is read through isfield on the
            % options struct: a field only exists if the caller passed it.
            if isfield(options, 'Properties') && ~isempty(options.Properties)
                keys = fieldnames(options.Properties);
                for i = 1:numel(keys)
                    value = options.Properties.(keys{i});
                    nominalmex('update_set_property', u, keys{i}, char(string(value)));
                end
            end
            if isfield(options, 'Labels') && ~isempty(options.Labels)
                for i = 1:numel(options.Labels)
                    nominalmex('update_add_label', u, char(options.Labels(i)));
                end
            end
        end
    end
end

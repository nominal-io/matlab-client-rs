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

    properties (SetAccess = protected, GetAccess = public, Hidden)
        % The library handle. Hidden because it is an implementation detail —
        % it stays readable for diagnostics and for the tests, but it should
        % not appear in tab-completion or in the default display alongside the
        % properties a user actually works with.
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

    methods
        function disp(obj)
            %DISP  Show the resource's own fields rather than a handle address.
            %
            %   MATLAB's default display for a handle class is the class name
            %   and a link, which tells a user nothing about which asset or run
            %   they are holding. Every property here reads from a struct the
            %   library already fetched, so showing them all costs no network.
            if ~isscalar(obj)
                fprintf('  %s array (%s)\n\n', class(obj), ...
                        join(string(size(obj)), char(215)));
                return
            end
            if ~isvalid(obj) || obj.Handle == 0
                fprintf('  %s (released)\n\n', class(obj));
                return
            end

            names = properties(obj);
            fprintf('  %s\n\n', class(obj));
            for i = 1:numel(names)
                try
                    value = obj.(names{i});
                catch
                    % A getter can fail on its own — a shut-down library, a
                    % property the server did not return. One unreadable field
                    % should not take the whole display down with it.
                    value = "<unavailable>";
                end
                fprintf('    %-14s %s\n', names{i}, nominal.Resource.brief(value));
            end
            fprintf('\n');
        end
    end

    methods (Static, Access = private)
        function text = brief(value)
            % One line per property, whatever the type underneath.
            if isstring(value) || ischar(value)
                text = strjoin(cellstr(string(value)), ', ');
                if strlength(text) > 60
                    text = extractBefore(text, 58) + "...";
                end
            elseif isdatetime(value) || isnumeric(value) || islogical(value)
                text = strjoin(cellstr(string(value(:)')), ', ');
            else
                text = sprintf('[%s]', class(value));
            end
            if isempty(char(text))
                text = '""';
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
            %   The callers' arguments blocks give these fields no defaults, so
            %   a field exists in options only when the caller passed it. That
            %   is what makes "passed empty" distinguishable from "not passed":
            %   an empty-but-present collection means "clear" and stages an
            %   empty replacement, while an absent one leaves the resource's
            %   set alone.
            %
            %   Lives here rather than in a subpackage because only code in
            %   this folder can reach the private MEX gateway.
            u = nominalmex('update_begin');

            if isfield(options, 'Name') && ~isempty(options.Name)
                nominalmex('update_set_name', u, char(options.Name));
            end
            if isfield(options, 'Description') && ~isempty(options.Description)
                nominalmex('update_set_description', u, char(options.Description));
            end

            if isfield(options, 'Properties')
                keys = {};
                if ~isempty(options.Properties)
                    keys = fieldnames(options.Properties);
                end
                if isempty(keys)
                    nominalmex('update_clear_properties', u);
                end
                for i = 1:numel(keys)
                    value = options.Properties.(keys{i});
                    nominalmex('update_set_property', u, keys{i}, char(string(value)));
                end
            end
            if isfield(options, 'Labels')
                if isempty(options.Labels)
                    nominalmex('update_clear_labels', u);
                end
                for i = 1:numel(options.Labels)
                    nominalmex('update_add_label', u, char(options.Labels(i)));
                end
            end
        end
    end
end

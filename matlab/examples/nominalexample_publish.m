function nominalexample_publish(results, name)
%NOMINALEXAMPLE_PUBLISH  Leave a demo's results where they can be inspected.
%
%   Each demo pushes its results into the base workspace as one struct under
%   its own name, so they are still there after the demo returns:
%
%       nominalexample_streamdemo(rid)
%       plot(nominalStream.Timestamps, nominalStream.Values)
%
%   The variables are session-scoped and disappear on `clear`.
%
%   See also ASSIGNIN, NOMINALEXAMPLE_CONNECT

    arguments
        results struct
        name (1,1) string
    end

    assignin('base', name, results);

    fprintf('\nIn the base workspace as `%s`:\n', name);
    fields = string(fieldnames(results))';
    for field = fields
        fprintf('  %s.%s%s %s\n', name, field, ...
                blanks(max(1, 14 - strlength(field))), describe(results.(field)));
    end
end

function text = describe(value)
%DESCRIBE  One line per field. Non-scalar values are summarised by size.

    if istable(value) || istimetable(value)
        text = sprintf('%dx%d %s', height(value), width(value), class(value));

    elseif isempty(value)
        text = "(empty)";

    elseif ~isscalar(value)
        % Preview short string arrays; otherwise report size and type.
        if isstring(value) && numel(value) <= 6
            text = sprintf('1x%d string: %s', numel(value), join(value(:)', ", "));
        else
            text = sprintf('%dx%d %s', size(value, 1), size(value, 2), class(value));
        end

    elseif isdatetime(value) && isnat(value)
        % string(NaT) is <missing>, which %s will not format.
        text = "(not set)";

    elseif isstring(value) && strlength(value) == 0
        text = "(empty)";

    else
        text = string(value);
    end
end

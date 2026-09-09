function nominalexample_publish(results, name)
%NOMINALEXAMPLE_PUBLISH  Leave a demo's results where they can be inspected.
%
%   Prefixed for the same reason as every other file here: they land on the
%   path whenever this folder is added to it, so they should not claim plain
%   names. `publish` in particular is a MATLAB builtin.
%
%   A function's locals vanish on return, and a demo run as a bare statement
%   discards its output — so each demo also pushes its results into the base
%   workspace under a name of its own:
%
%       nominalexample_streamdemo(rid)
%       plot(nominalStream.Timestamps, nominalStream.Values)
%
%   Base variables are session-scoped and disappear on `clear`, unlike a
%   preference or a file. A demo should not leave anything behind that
%   outlives the session.
%
%   One struct per demo rather than a scatter of loose names, so nothing of
%   yours gets clobbered by accident, and distinct names per demo so a full
%   nominalexample_alldemos run leaves all of them rather than overwriting one.
%
%   The published names are *not* prefixed: they are workspace variables the
%   user is meant to type, and `nominalStream` is already distinctive enough.
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
%DESCRIBE  One line per field, whatever is in it.
%
%   Size-first, because the alternative is 500 timestamps down the console:
%   fprintf recycles its format across every element of a non-scalar, so
%   anything that is not scalar has to be summarised before it reaches %s.

    if istable(value) || istimetable(value)
        text = sprintf('%dx%d %s', height(value), width(value), class(value));

    elseif isempty(value)
        text = "(empty)";

    elseif ~isscalar(value)
        % A short string array is worth previewing; anything else, just say
        % how big it is and what type.
        if isstring(value) && numel(value) <= 6
            text = sprintf('1x%d string: %s', numel(value), join(value(:)', ", "));
        else
            text = sprintf('%dx%d %s', size(value, 1), size(value, 2), class(value));
        end

    elseif isdatetime(value) && isnat(value)
        % string(NaT) is a <missing> element, which %s will not format.
        text = "(not set)";

    elseif isstring(value) && strlength(value) == 0
        text = "(empty)";

    else
        text = string(value);
    end
end

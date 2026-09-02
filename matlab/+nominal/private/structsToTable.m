function t = structsToTable(s, variableNames)
%STRUCTSTOTABLE  Convert a struct array from the gateway into a table.
%
%   The MEX layer returns listings as struct arrays because that is what the C
%   side can build cheaply. A table is what MATLAB users actually want — it
%   displays legibly, supports logical indexing and sortrows, and drops
%   straight into the rest of the language.
%
%   struct2table is not enough on its own: it errors on a 0-by-1 struct array,
%   which is exactly what an empty listing is. An empty result is ordinary
%   here — a search that matched nothing, a dataset with no channels yet — so
%   it returns an empty table with the right variables rather than throwing.
%
%   variableNames is required for that reason: an empty struct array carries no
%   field names to recover them from.

    arguments
        s struct
        variableNames (1,:) string
    end

    if isempty(s)
        t = table('Size', [0 numel(variableNames)], ...
                  'VariableTypes', repmat("string", 1, numel(variableNames)), ...
                  'VariableNames', cellstr(variableNames));
        return
    end

    t = struct2table(s, 'AsArray', true);

    % struct2table gives cellstr columns for char fields. string is the type a
    % MATLAB user expects back from an API, and it compares with == .
    %
    % Read through t.(i) rather than t{:, i}: brace indexing on a cell-valued
    % table variable has different meanings depending on what is inside it,
    % and every listing here is text.
    for i = 1:width(t)
        if iscellstr(t.(i)) %#ok<ISCLSTR>
            t.(i) = string(t.(i));
        end
    end
end

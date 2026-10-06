function [pairKeys, pairValues] = keyValuePairs(map, what)
%KEYVALUEPAIRS  Split a struct or dictionary into parallel cellstrs.
%
%   The gateway takes keys and values as two cell arrays of char. A struct is
%   the short form, struct(UUT="A"); a dictionary carries keys that are not
%   valid field names, such as "test-stand".
%
%   Each value goes through string(), so UUT=3 is sent as "3". A value that
%   is not exactly one element is refused. what ("tag", "property") names the
%   pair in that error.

    if isstruct(map)
        names = string(fieldnames(map))';
        raw = cellfun(@(k) map.(k), cellstr(names), 'UniformOutput', false);
    elseif numEntries(map) == 0
        names = strings(1, 0);
        raw = {};
    else
        names = string(keys(map))';
        raw = values(map)';
        if ~iscell(raw)
            raw = num2cell(raw);
        end
    end

    pairValues = cell(size(raw));
    for k = 1:numel(raw)
        value = string(raw{k});
        if ~isscalar(value)
            error('nominal:invalidParameter', ...
                  '%s "%s" must have one value, not %d', what, names(k), numel(value));
        end
        pairValues{k} = char(value);
    end
    pairKeys = cellstr(names);
end

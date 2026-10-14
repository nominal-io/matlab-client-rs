function [pairKeys, pairValues] = keyValuePairs(map, what)
%KEYVALUEPAIRS  Split a struct, dictionary or containers.Map into cellstrs.
%
%   The gateway takes keys and values as two cell arrays of char. A struct is
%   the short form, struct(UUT="A"). A dictionary or containers.Map carries
%   keys that are not valid field names, such as "test-stand";
%   containers.Map is the one that works before R2022b.
%
%   Each value goes through string(), so UUT=3 is sent as "3". A value that
%   is not exactly one element is refused. what ("tag", "property") names the
%   pair in that error.

    % No (1,1) size check in the callers' arguments blocks: containers.Map
    % reports its entry count as its size. A struct array is refused here.
    if isstruct(map)
        if ~isscalar(map)
            error('nominal:invalidParameter', ...
                  '%ss must be a scalar struct, not %d elements', what, numel(map));
        end
        names = string(fieldnames(map))';
        raw = cellfun(@(k) map.(k), cellstr(names), 'UniformOutput', false);
    elseif isa(map, 'containers.Map')
        names = string(keys(map));
        raw = values(map);
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

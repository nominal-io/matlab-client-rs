function updated = editProperty(fresh, key, value)
%EDITPROPERTY  Set one property, or remove it when value is omitted.
%
%   fresh is the resource re-read from the server just now. update replaces
%   every property, so working from a stale handle would undo changes made
%   since it was fetched. There is still a window between the read and the
%   write; nothing on the server closes it.

    props = fresh.Properties;
    key = char(key);
    if nargin < 3
        if ~isKey(props, key)
            error('nominal:invalidParameter', 'no property called "%s"', key);
        end
        remove(props, key);
    else
        value = string(value);
        if ~isscalar(value)
            error('nominal:invalidParameter', ...
                  'property "%s" must have one value, not %d', key, numel(value));
        end
        props(key) = char(value);
    end
    updated = fresh.update(Properties=props);
end

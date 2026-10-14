function map = propertyMap(command, handle)
%PROPERTYMAP  Every property of a handle, as a containers.Map of char.
%
%   containers.Map rather than dictionary so it works on every release the
%   toolbox supports. Keys need not be valid field names, which rules out a
%   struct.

    [keys, values] = nominalmex(command, handle);
    map = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for k = 1:numel(keys)
        map(keys{k}) = values{k};
    end
end

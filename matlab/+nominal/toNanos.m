function nanos = toNanos(value)
%TONANOS  Convert a time to int64 nanoseconds since the Unix epoch.
%
%   Used wherever the toolbox takes a single instant, so callers can write
%   either
%
%       r = a.run("burn-12", datetime("now", TimeZone="UTC"));
%       r = a.run("burn-12", int64(1735689600000000000));
%
%   Args:
%       value: A zoned datetime or an int64 nanosecond count, taken
%           literally: int64(0) is 1970-01-01T00:00:00Z. A plain double is
%           refused: doubles lose integer precision past 2^53 nanoseconds,
%           which is 1970 plus 104 days, so any present-day timestamp passed
%           as one would be silently rounded.
%
%   Returns:
%       int64: Nanoseconds since the Unix epoch.
%
%   See also NOMINAL.FROMNANOS, NOMINAL.NOW

    if isa(value, 'datetime')
        if numel(value) ~= 1
            error('nominal:invalidParameter', ...
                  'expected a single datetime, got %d elements', numel(value));
        end
        if isempty(value.TimeZone)
            % An unzoned datetime is ambiguous. Guessing local time would
            % silently shift every timestamp by the machine's offset.
            error('nominal:invalidParameter', ...
                  ['datetime must carry a TimeZone so the instant is ' ...
                   'unambiguous; use datetime(..., TimeZone="UTC")']);
        end
        nanos = convertTo(value, 'epochtime', 'TicksPerSecond', 1e9);
        return
    end

    if isa(value, 'int64')
        if numel(value) ~= 1
            error('nominal:invalidParameter', ...
                  'expected a single timestamp, got %d elements', numel(value));
        end
        nanos = value;
        return
    end

    error('nominal:invalidParameter', ...
          ['time must be a zoned datetime or an int64 nanosecond count ' ...
           '(got %s); a double cannot represent a nanosecond timestamp exactly'], ...
          class(value));
end

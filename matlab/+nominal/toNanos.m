function nanos = toNanos(value)
%TONANOS  Convert a time to int64 nanoseconds since the Unix epoch.
%
%   Accepts a datetime, an int64 nanosecond count, or 0. Used wherever the
%   library takes a single instant, so callers can write either
%
%       r = a.run("burn-12", datetime("now", TimeZone="UTC"));
%       r = a.run("burn-12", int64(1735689600000000000));
%
%   A plain double is refused unless it is 0. Doubles hold integers exactly
%   only to 2^53, which in nanoseconds runs out about 104 days after 1970 —
%   so any real timestamp passed as a double would be silently rounded, and
%   rounding a timestamp is worse than rejecting it.
%
%   Zero is the exception because it is the library's "now" sentinel for run
%   and event times, and is commonly written as a bare 0.
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

    if isnumeric(value) && isscalar(value) && value == 0
        nanos = int64(0);
        return
    end

    error('nominal:invalidParameter', ...
          ['time must be a zoned datetime or an int64 nanosecond count ' ...
           '(got %s); a double cannot represent a nanosecond timestamp exactly'], ...
          class(value));
end

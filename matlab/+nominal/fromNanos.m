function dt = fromNanos(nanos)
%FROMNANOS  Convert int64 nanoseconds since the Unix epoch to a UTC datetime.
%
%   The inverse of nominal.toNanos, used for times coming back out of the
%   library. Always returns a UTC-zoned datetime, so the instant is
%   unambiguous; call datetime's TimeZone setter to view it locally.
%
%   Note that datetime's internal resolution does not reach nanoseconds, so a
%   round trip through this function is not exact at the nanosecond level. Read
%   the raw int64 if you need the exact instant.
%
%   See also NOMINAL.TONANOS, NOMINAL.NOW

    arguments
        nanos int64
    end
    dt = datetime(nanos, 'ConvertFrom', 'epochtime', ...
                  'TicksPerSecond', 1e9, 'TimeZone', 'UTC');
end

function dt = fromNanos(nanos)
%FROMNANOS  Convert int64 nanoseconds since the Unix epoch to a UTC datetime.
%
%   The inverse of nominal.toNanos. Always returns a UTC datetime; set its
%   TimeZone to view it locally.
%
%   datetime does not resolve to nanoseconds, so the conversion is not exact
%   at that level. Keep the raw int64 if you need the exact instant.
%
%   See also NOMINAL.TONANOS, NOMINAL.NOW

    arguments
        nanos int64
    end
    dt = datetime(nanos, 'ConvertFrom', 'epochtime', ...
                  'TicksPerSecond', 1e9, 'TimeZone', 'UTC');
end

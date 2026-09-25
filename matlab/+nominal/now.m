function nanos = now()
%NOW  Current time as int64 nanoseconds since the Unix epoch.
%
%   Use this instead of datetime("now") when you need full precision for
%   streaming timestamps; datetime does not resolve to nanoseconds.
%
%       t0 = nominal.now();
%       t  = t0 + int64(0:999)' * 1000000;   % 1 ms apart
%
%   See also NOMINAL.TONANOS, NOMINAL.FROMNANOS

    nanos = nominalmex('timestamp_now');
end

function nanos = now()
%NOW  Current time as int64 nanoseconds since the Unix epoch.
%
%   Reads the host clock at the finest resolution it offers. Use this rather
%   than datetime("now") when you need full precision for streaming
%   timestamps: datetime's internal resolution does not reach nanoseconds.
%
%       t0 = nominal.now();
%       t  = t0 + int64(0:999)' * 1000000;   % 1 ms apart
%
%   See also NOMINAL.TONANOS, NOMINAL.FROMNANOS

    nominal.setup();
    nanos = nominalmex('timestamp_now');
end

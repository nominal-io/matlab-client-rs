function nanos = toNanosVector(value)
%TONANOSVECTOR  Convert a vector of times to int64 nanoseconds.
%
%   The vector counterpart of nominal.toNanos, used by the push methods.
%   Accepts an int64 vector or a zoned datetime vector.
%
%   No zero-means-now sentinel here: streaming timestamps are literal.
%
%   See also NOMINAL.TONANOS, NOMINAL.STREAM

    if isa(value, 'datetime')
        if isempty(value.TimeZone)
            error('nominal:invalidParameter', ...
                  ['datetime must carry a TimeZone so the instants are ' ...
                   'unambiguous; use datetime(..., TimeZone="UTC")']);
        end
        nanos = convertTo(value(:), 'epochtime', 'TicksPerSecond', 1e9);
        return
    end

    if isa(value, 'int64')
        nanos = value(:);
        return
    end

    error('nominal:invalidParameter', ...
          ['timestamps must be an int64 vector or a zoned datetime vector ' ...
           '(got %s); doubles cannot represent nanosecond timestamps exactly'], ...
          class(value));
end

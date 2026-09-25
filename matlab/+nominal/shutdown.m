function shutdown()
%SHUTDOWN  Release everything the library holds and stop its worker threads.
%
%   You do not normally need to call this. It runs automatically on
%   `clear mex`, `clear all`, or exit.
%
%   Call it when you want the teardown at a known point, such as the end of
%   a long-running script that should not hold a connection open.
%
%   All outstanding handles become invalid. Existing nominal objects error if
%   used afterwards, though deleting them is still safe. Get fresh objects
%   instead of reusing old ones. The next call builds a new runtime, so the
%   library is usable again immediately.
%
%   See also CLEAR

    nominalmex('shutdown');
end

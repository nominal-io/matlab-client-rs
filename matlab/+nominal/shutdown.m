function shutdown()
%SHUTDOWN  Release everything the library holds and stop its worker threads.
%
%   You do not normally need to call this. The MEX gateway registers a
%   mexAtExit hook that runs it automatically before MATLAB unloads the
%   gateway — on `clear mex`, `clear all`, or exit — which is the moment it
%   matters. Without that hook the library's worker threads would outlive the
%   unloaded module and take MATLAB down with them.
%
%   Call it explicitly when you want the teardown to happen at a known point:
%   before a `clear mex` during development, say, or at the end of a
%   long-running script that should not hold a connection open.
%
%   All outstanding handles become invalid. Existing nominal objects will
%   report errors if used afterwards, though releasing them stays safe —
%   freeing an unknown handle is a no-op. Acquire fresh objects rather than
%   reusing old ones.
%
%   This is a pause rather than a one-way door: the next call builds a new
%   runtime, so the library is usable again immediately.
%
%   See also CLEAR

    nominalmex('shutdown');
end

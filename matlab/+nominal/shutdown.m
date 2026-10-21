function shutdown()
%SHUTDOWN  Shut the toolbox down, closing every connection.
%
%   You do not need to call this. It runs automatically on
%   `clear mex`, `clear all`, or exit.
%
%   Call it when you want the shutdown at a known point, such as the end of
%   a long-running script that should not hold a connection open.
%
%   Every nominal object you hold stops working, and using one raises
%   nominal:invalidHandle. Deleting one is still safe. New objects work as
%   normal.
%
%   See also CLEAR

    nominalmex('shutdown');
end

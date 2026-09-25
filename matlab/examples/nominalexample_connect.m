function client = nominalexample_connect()
%NOMINALEXAMPLE_CONNECT  Connect and say who you are — the demos' opening line.
%
%   Thin wrapper over nominal.Client.connect, which tries the profile first
%   and falls back to NOMINAL_TOKEN. This adds only the greeting.
%
%   In your own code call nominal.Client.connect(), or
%   nominal.Client.fromProfile() if you want to be sure which one is used.
%
%   Files in this folder carry the nominalexample_ prefix so they do not
%   shadow other functions if the folder is added to the path.
%
%   See also NOMINAL.CLIENT/CONNECT, NOMINAL.CLIENT/FROMPROFILE

    client = nominal.Client.connect();
    fprintf('Connected as %s\n', client.whoAmI());
end

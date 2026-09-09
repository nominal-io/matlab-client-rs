function client = nominalexample_connect()
%NOMINALEXAMPLE_CONNECT  Connect and say who you are — the demos' opening line.
%
%   Thin wrapper over nominal.Client.connect, which is where the actual
%   credential logic lives: profile first, NOMINAL_TOKEN as a fallback. All
%   this adds is the greeting, because printing and a round trip to whoAmI
%   belong in a demo rather than in a library constructor.
%
%   In your own code call nominal.Client.connect() — or better,
%   nominal.Client.fromProfile(), which cannot silently pick the other one.
%
%   Every file in this folder carries the nominalexample_ prefix. A folder of
%   examples put on the path claims every one of its filenames as a global
%   function, and names like `connect` or `rundemo` are ones a user or another
%   toolbox is entitled to want for themselves. The packaged toolbox does not
%   path this folder at all — see tools/package.m — but the prefix keeps the
%   names safe for anyone who adds it by hand.
%
%   See also NOMINAL.CLIENT/CONNECT, NOMINAL.CLIENT/FROMPROFILE

    client = nominal.Client.connect();
    fprintf('Connected as %s\n', client.whoAmI());
end

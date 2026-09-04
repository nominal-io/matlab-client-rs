function client = nominalconnect()
%NOMINALCONNECT  Authenticate the way every demo in this folder does.
%
%   Prefixed rather than just "connect": these example files land on the path
%   whenever this folder is added to it, and a bare `connect` is a name a user
%   or another toolbox is likely to want for themselves.
%
%   Credentials come from the profile stored on disk — the same
%   ~/.config/nominal/config.yml that the `nom` CLI and the Python client
%   read. Set it up once:
%
%       nom config profile add default -t <api-token>
%
%   or, if `nom` is not on the path:
%
%       python -m nominal.cli config profile add default
%
%   NOMINAL_TOKEN in the environment is honoured as a fallback, for CI and for
%   anyone who has not set up a profile yet. The profile wins when both exist,
%   because it also carries the base URL and workspace — an environment token
%   alone can only reach production.
%
%   See also NOMINAL.CLIENT/FROMPROFILE, NOMINAL.CLIENT/FROMTOKEN

    try
        client = nominal.Client.fromProfile();
    catch profileError
        token = string(getenv("NOMINAL_TOKEN"));
        if token == ""
            % Report the profile problem rather than a generic one: it names
            % the file it looked in and the command that would fix it.
            error('nominal:demo', ...
                  ['no credentials found.\n\n%s\n\n' ...
                   'Alternatively set NOMINAL_TOKEN in the environment. Note ' ...
                   'that MATLAB reads the environment it was launched with — ' ...
                   'on macOS, starting MATLAB from the Dock does not pick up ' ...
                   'shell exports.'], profileError.message);
        end
        client = nominal.Client.fromToken(token);
    end

    fprintf('Connected as %s\n', client.whoAmI());
end

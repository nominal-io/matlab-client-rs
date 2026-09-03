function profile = readProfile(name, configPath)
%READPROFILE  Read one connection profile from the Nominal config file.
%
%   Reads the same file the Python client and the `nom` CLI use, so a machine
%   set up for either is already set up for MATLAB:
%
%       nom config profile add default -t <api-token>
%
%   which writes ~/.config/nominal/config.yml in this shape:
%
%       version: 2
%       profiles:
%         default:
%           base_url: https://api.gov.nominal.io/api
%           token: nominal_api_key_...
%         staging:
%           base_url: https://api-staging.gov.nominal.io/api
%           token: eyJ...
%           workspace_rid: ri.security.gov-staging.workspace.82db1f3a-...
%
%   Returns a struct with BaseUrl, Token, and WorkspaceRid ("" when the
%   profile does not set one).
%
%   This is not a YAML parser. It reads the two-level key/value structure that
%   this one file has and nothing else — no anchors, no lists, no multi-line
%   scalars, no flow mappings. MATLAB has no YAML reader from the version (R2021a)
%   this client targets. If the config format grows past this shape, the fix
%   is to widen this function deliberately rather than to reach for a parser.

    arguments
        name (1,1) string = "default"
        configPath (1,1) string = defaultConfigPath()
    end

    if ~isfile(configPath)
        % Mirror the Python client's diagnosis: the usual reason the new file
        % is missing is that the machine predates profiles and still has the
        % old one.
        legacy = fullfile(homeDirectory(), ".nominal.yml");
        if isfile(legacy)
            error('nominal:configMissing', ...
                  ['no config file at %s, but the deprecated %s exists.\n' ...
                   'Migrate it with:  nom config migrate\n' ...
                   '(or: python -m nominal.cli config migrate)'], ...
                  configPath, legacy);
        end
        error('nominal:configMissing', ...
              ['no config file at %s\n' ...
               'Create one with:  nom config profile add %s -t <api-token>\n' ...
               '(or: python -m nominal.cli config profile add %s)'], ...
              configPath, name, name);
    end

    lines = string(splitlines(fileread(configPath)));

    inProfiles = false;
    current = "";
    available = strings(1, 0);
    found = false;
    profile = struct('BaseUrl', "", 'Token', "", 'WorkspaceRid', "");

    for i = 1:numel(lines)
        raw = lines(i);
        text = strtrim(raw);
        if text == "" || startsWith(text, "#")
            continue
        end

        % A key at column zero is top level: `version:` or `profiles:`.
        % Anything indented under `profiles:` is a profile or one of its keys.
        if ~startsWith(raw, " ") && ~startsWith(raw, sprintf('\t'))
            inProfiles = startsWith(text, "profiles:");
            current = "";
            continue
        end
        if ~inProfiles
            continue
        end

        % Split on the first colon only: values are URLs and tokens, which
        % contain colons of their own.
        colon = strfind(text, ':');
        if isempty(colon)
            continue
        end
        key = strtrim(extractBefore(text, colon(1)));
        value = unquote(strtrim(extractAfter(text, colon(1))));

        if value == ""
            % A key with no value opens a nested mapping — a profile name.
            current = key;
            available(end+1) = key; %#ok<AGROW>
            found = found || current == name;
            continue
        end
        if current ~= name
            continue
        end

        % An optional field the CLI did not set is written by PyYAML as the
        % literal `null`, so a profile created without -w really does contain
        % "workspace_rid: null" on disk. Without this, that reaches the client
        % as a four-character RID and every call fails with
        % "invalid RID 'null'". Treat YAML's null spellings as unset.
        if any(value == ["null" "Null" "NULL" "~"])
            value = "";
        end

        switch key
            case "base_url",      profile.BaseUrl = value;
            case "token",         profile.Token = value;
            case "workspace_rid", profile.WorkspaceRid = value;
            otherwise
                % Forward compatibility: a key this client does not know is
                % not an error, since the CLI may write more than we read.
        end
    end

    if ~found
        if isempty(available)
            error('nominal:configInvalid', ...
                  'no profiles in %s\nAdd one with:  nom config profile add %s -t <api-token>', ...
                  configPath, name);
        end
        error('nominal:profileNotFound', ...
              'profile "%s" not found in %s\nAvailable: %s', ...
              name, configPath, join(available, ", "));
    end
    if profile.Token == ""
        error('nominal:configInvalid', ...
              'profile "%s" in %s has no token', name, configPath);
    end
end

function path = defaultConfigPath()
    path = string(fullfile(homeDirectory(), ".config", "nominal", "config.yml"));
end

function home = homeDirectory()
    % MATLAB does not expand "~" in most functions, and the variable holding
    % the home directory differs by platform.
    if ispc
        home = getenv('USERPROFILE');
    else
        home = getenv('HOME');
    end
    if isempty(home)
        % -nojvm sessions have no Java, so this is a fallback rather than the
        % first choice.
        try
            home = char(java.lang.System.getProperty('user.home'));
        catch
            error('nominal:configMissing', ...
                  'cannot determine your home directory; pass a config path explicitly');
        end
    end
    home = string(home);
end

function text = unquote(text)
    % The CLI writes unquoted scalars, but a hand-edited file may not.
    if strlength(text) >= 2
        first = extractBetween(text, 1, 1);
        last = extractBetween(text, strlength(text), strlength(text));
        if first == last && (first == """" || first == "'")
            text = extractBetween(text, 2, strlength(text) - 1);
        end
    end
end

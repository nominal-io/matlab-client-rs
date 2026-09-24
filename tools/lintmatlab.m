function lintmatlab()
%LINTMATLAB  Run MATLAB's static analyser over every .m file in the repo.
%
%   The counterpart to `cargo clippy` for the MATLAB half. Run it from the
%   repository root:
%
%       just lint-matlab
%
%   or from inside MATLAB:
%
%       run tools/lintmatlab.m
%
%   checkcode is the engine behind the editor's warning markers, so this
%   reports what the IDE would: syntax errors, unset output arguments,
%   unreachable code, unused variables, and — the one that has bitten this
%   codebase repeatedly — names that shadow MATLAB builtins.
%
%   Exits non-zero when anything is reported, so it can gate a build.
%
%   Lives in tools/ rather than matlab/ deliberately. Everything in matlab/
%   lands on the user's path when they addpath the package, and a file called
%   lint.m there would become a global function in their session.
%
%   See also CHECKCODE

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    matlabRoot = fullfile(root, 'matlab');

    % Every place this project keeps MATLAB source. private/ is listed
    % explicitly because dir() does not recurse.
    folders = { ...
        matlabRoot, ...
        fullfile(matlabRoot, '+nominal'), ...
        fullfile(matlabRoot, '+nominal', 'private'), ...
        fullfile(matlabRoot, 'examples'), ...
        fullfile(matlabRoot, 'tests'), ...
        here};

    files = [];
    for i = 1:numel(folders)
        files = [files; dir(fullfile(folders{i}, '*.m'))]; %#ok<AGROW>
    end

    if isempty(files)
        error('nominal:lintFailed', 'no MATLAB files found under %s', root);
    end

    issueCount = 0;
    for i = 1:numel(files)
        path = fullfile(files(i).folder, files(i).name);
        issues = checkcode(path, '-id');
        if isempty(issues)
            continue
        end

        relative = erase(path, [root filesep]);
        for k = 1:numel(issues)
            % file:line: form, so terminals and the IDE make it clickable.
            fprintf('%s:%d: [%s] %s\n', relative, issues(k).line, ...
                    issues(k).id, issues(k).message);
        end
        issueCount = issueCount + numel(issues);
    end

    issueCount = issueCount + checkSignatures(root, matlabRoot);

    fprintf('\n%d issue(s) across %d file(s)\n', issueCount, numel(files));
    if issueCount > 0
        % Non-zero exit, so `just lint` fails rather than printing warnings
        % into a passing build.
        exit(1);
    end
end

function issueCount = checkSignatures(root, matlabRoot)
%CHECKSIGNATURES  Validate the tab-completion signatures, if present.
%
%   functionSignatures.json drives argument hints and tab completion. It is
%   hand-maintained and MATLAB loads it silently, so a malformed file simply
%   stops working with no error anywhere — which is exactly the kind of thing
%   a lint gate is for.
%
%   This checks the file's own grammar. It cannot tell whether the methods it
%   names still exist; a rename in the class is still a silent break.

    issueCount = 0;
    signatures = fullfile(matlabRoot, 'resources', 'functionSignatures.json');
    if ~isfile(signatures)
        return
    end

    problems = validateFunctionSignaturesJSON(signatures);
    if isempty(problems)
        return
    end

    relative = erase(signatures, [root filesep]);
    for k = 1:numel(problems)
        fprintf('%s:%d: [signatures] %s\n', relative, ...
                problems(k).LineNumber, problems(k).Message);
    end
    issueCount = numel(problems);
end

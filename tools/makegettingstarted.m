function makegettingstarted()
%MAKEGETTINGSTARTED  Regenerate the toolbox's Getting Started live script.
%
%   From the repository root:
%
%       just gettingstarted
%
%   Converts matlab/doc/GettingStarted.m into matlab/doc/GettingStarted.mlx,
%   which is what the Add-Ons panel opens for an installed toolbox.
%
%   The .m is the source of truth. An .mlx is a zip of XML: it does not diff,
%   does not review, and cannot be edited without MATLAB. Keeping the prose in
%   a plain file and generating the binary means changes show up in a pull
%   request as text.
%
%   Run this after editing the .m, and commit both. Packaging does not call
%   it — a packaging step that silently rewrites a tracked binary is worse
%   than one that uses a stale file, because the stale file is at least
%   visible in `git status`.
%
%   The converter is matlab.internal.liveeditor.openAndSave. It is
%   undocumented, which is why this is a separate command rather than part of
%   package.m: when a release breaks it, packaging still works and only this
%   fails, with the .mlx already committed.
%
%   See also TOOLS/PACKAGE

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);

    source = fullfile(root, 'matlab', 'doc', 'GettingStarted.m');
    target = fullfile(root, 'matlab', 'doc', 'GettingStarted.mlx');

    if ~isfile(source)
        error('nominal:docFailed', 'no source at %s', source);
    end

    % openAndSave opens the file in a headless Live Editor and saves it in the
    % target format, which it picks from the extension. It will not overwrite,
    % so clear the old one first.
    if isfile(target)
        delete(target);
    end

    try
        matlab.internal.liveeditor.openAndSave(char(source), char(target));
    catch conversionError
        error('nominal:docFailed', ...
              ['could not convert %s to a live script.\n' ...
               'matlab.internal.liveeditor.openAndSave is undocumented and ' ...
               'may have changed in this release.\n' ...
               'Underlying error: %s'], source, conversionError.message);
    end

    built = dir(target);
    fprintf('Wrote %s (%.1f KB)\n', target, built.bytes / 1024);
    fprintf('Commit both this and the .m it came from.\n');
end

function package()
%PACKAGE  Build an installable .mltbx toolbox from the current tree.
%
%   Run from the repository root:
%
%       just package
%
%   or from inside MATLAB:
%
%       run tools/package.m
%
%   Produces dist/NominalForMATLAB-<version>.mltbx, which installs with
%   matlab.addons.install or a double-click. An installed toolbox manages its
%   own path, so users need no addpath at all.
%
%   Packages whatever is in the tree right now — it does not build. `just
%   package` depends on `mex-win64`, so going through just always packages a
%   release-profile gateway; running this by hand packages whatever the last
%   build left behind, including a `-fast` one.
%
%   See also MATLAB.ADDONS.TOOLBOX.PACKAGETOOLBOX, MATLAB.ADDONS.INSTALL

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    matlabRoot = fullfile(root, 'matlab');

    % Stable for the life of the toolbox. MATLAB keys upgrades and uninstalls
    % on it, so a fresh one would install alongside the old rather than
    % replacing it. Never regenerate.
    identifier = "b7e4c2a1-5d3f-4e88-9a12-6f0c3d7b8e45";

    version = readVersion(fullfile(root, 'Cargo.toml'));
    opts = matlab.addons.toolbox.ToolboxOptions(matlabRoot, identifier);

    opts.ToolboxName    = "Nominal for MATLAB";
    opts.ToolboxVersion = version;
    opts.Summary        = "Native MATLAB client for Nominal";
    opts.Description    = join([ ...
        "An object-oriented MATLAB client for Nominal. The Nominal Rust SDK is"
        "wrapped in a C ABI and linked into a single MEX gateway, so MATLAB"
        "talks to native code rather than shelling out to Python."], " ");

    % A claim, not something the packager can check. See the Requirements
    % section of README.md for what has actually been run.
    opts.MinimumMatlabRelease = "R2021a";

    % Only +nominal goes on the installed path. The default would also add
    % examples/, src/ and tests/ — src/ is C source, and every file in
    % examples/ would become a global function name in the user's session.
    % They still ship inside the toolbox; they are just not pathed.
    opts.ToolboxMatlabPath = matlabRoot;

    opts.SupportedPlatforms = supportedPlatforms(matlabRoot);

    outDir = fullfile(root, 'dist');
    if ~isfolder(outDir)
        mkdir(outDir);
    end
    opts.OutputFile = fullfile(outDir, "NominalForMATLAB-" + version + ".mltbx");

    fprintf('Packaging %s %s\n', opts.ToolboxName, version);
    fprintf('  platforms: %s\n', platformSummary(opts.SupportedPlatforms));
    matlab.addons.toolbox.packageToolbox(opts);

    built = dir(opts.OutputFile);
    fprintf('Wrote %s (%.1f MB)\n', opts.OutputFile, built.bytes / 1048576);
    fprintf('\nInstall with:\n');
    fprintf('    matlab.addons.install("%s")\n', opts.OutputFile);
end

function version = readVersion(cargoToml)
%READVERSION  Take the toolbox version from the workspace Cargo.toml.
%
%   One version for the whole project rather than two that drift. The field is
%   under [workspace.package], which is the only `version =` at the start of a
%   line in that file.

    text = string(splitlines(fileread(cargoToml)));
    match = regexp(text, '^version\s*=\s*"([^"]+)"', 'tokens', 'once');
    found = match(~cellfun(@isempty, match));
    if isempty(found)
        error('nominal:packageFailed', ...
              'no version found in %s', cargoToml);
    end
    version = string(found{1}{1});
end

function platforms = supportedPlatforms(matlabRoot)
%SUPPORTEDPLATFORMS  Claim only the platforms a MEX binary exists for.
%
%   Overstating this installs the toolbox on a machine where the very first
%   call fails to resolve nominalmex. MATLAB picks the binary by mexext, so
%   several can sit side by side in private/ and each one enables its platform.

    privateDir = fullfile(matlabRoot, '+nominal', 'private');
    has = @(ext) isfile(fullfile(privateDir, "nominalmex." + ext));

    % MATLAB has one Mac flag, not one per architecture. Only Apple silicon is
    % supported here, so mexmaca64 is the only Mac binary that can appear.
    platforms.Win64   = has("mexw64");
    platforms.Glnxa64 = has("mexa64");
    platforms.Mac     = has("mexmaca64");

    % MATLAB Online cannot load a MEX file built here whatever the platform.
    platforms.MatlabOnline = false;

    if ~any([platforms.Win64, platforms.Glnxa64, platforms.Mac])
        error('nominal:packageFailed', ...
              ['no MEX gateway found in %s\n' ...
               'Build one first: just mex-win64'], privateDir);
    end
end

function text = platformSummary(platforms)
    names = string(fieldnames(platforms))';
    enabled = names(cellfun(@(n) platforms.(n), cellstr(names)));
    if isempty(enabled)
        text = "(none)";
    else
        text = join(enabled, ", ");
    end
end

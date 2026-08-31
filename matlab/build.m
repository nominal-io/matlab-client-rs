function build(options)
%BUILD  Compile the Nominal MEX gateway.
%
%   From the matlab/ folder:
%
%       build                    % release DLL
%       build(Profile="fast")    % the no-LTO iteration build
%
%   Requires that the shared library has already been built — run `just
%   build-win64` (or `just build-win64-fast`) at the repository root first.
%
%   The gateway is compiled into +nominal/private/, where only code in
%   +nominal/ can reach it. That is deliberate: nominalmex is an
%   implementation detail with no argument checking of its own, and calling it
%   directly bypasses every guarantee the classes provide.
%
%   The shared library is copied next to the gateway. That alone is not enough
%   for Windows to find it — it resolves a MEX file's dependencies relative to
%   the host executable, MATLAB's own bin folder — so nominal.setup prepends
%   this folder to PATH before the gateway is first loaded. That happens
%   automatically; see nominal.setup for the details.

    arguments
        options.Profile (1,1) string {mustBeMember(options.Profile, ["release" "fast"])} = "release"
    end

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    target = fullfile(root, 'target', 'x86_64-pc-windows-msvc', char(options.Profile));

    importLib = fullfile(target, 'nominal_ffi.dll.lib');
    sharedLib = fullfile(target, 'nominal_ffi.dll');
    header = fullfile(root, 'crates', 'ffi', 'include');
    source = fullfile(here, 'src', 'nominalmex.c');
    outDir = fullfile(here, '+nominal', 'private');

    if ~isfile(importLib)
        error('nominal:buildFailed', ...
              ['import library not found at %s\n' ...
               'Build the shared library first: just build-win64%s'], ...
              importLib, ternary(options.Profile == "fast", "-fast", ""));
    end

    if ~isfolder(outDir)
        mkdir(outDir);
    end

    fprintf('Compiling gateway (%s profile)...\n', options.Profile);
    mex('-R2018a', ...
        ['-I' header], ...
        source, ...
        importLib, ...
        '-outdir', outDir, ...
        '-output', 'nominalmex');

    % Alongside the gateway, not in bin/: see the note above about Windows
    % resolving DLLs relative to the host executable.
    copyfile(sharedLib, fullfile(outDir, 'nominal_ffi.dll'));

    fprintf('Built %s\n', fullfile(outDir, ['nominalmex.' mexext]));
    fprintf('\nAdd this folder to the path, then:\n');
    fprintf('    addpath(''%s'')\n', here);
    fprintf('    c = nominal.Client(getenv("NOMINAL_TOKEN"));\n');
    fprintf('    disp(c.whoAmI())\n');
end

function out = ternary(condition, whenTrue, whenFalse)
    if condition
        out = whenTrue;
    else
        out = whenFalse;
    end
end

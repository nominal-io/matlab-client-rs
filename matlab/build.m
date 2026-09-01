function build(options)
%BUILD  Compile the Nominal MEX gateway.
%
%   From the matlab/ folder:
%
%       build                    % release build
%       build(Profile="fast")    % the no-LTO iteration build
%
%   Requires that the Rust static library has already been built — run `just
%   build-win64` (or `just build-win64-fast`) at the repository root first.
%
%   The gateway is compiled into +nominal/private/, where only code in
%   +nominal/ can reach it. That is deliberate: nominalmex is an
%   implementation detail with no argument checking of its own, and calling it
%   directly bypasses every guarantee the classes provide.
%
%   The Rust library is linked *into* the gateway rather than shipped beside it
%   as a DLL. That is what makes +nominal/private/nominalmex.mexw64 the single
%   binary this client needs: there is no second file for Windows to find, and
%   so no PATH manipulation before first use.
%
%   Static linking is why this function has a list of system libraries. A Rust
%   staticlib does not record its own dependencies the way a DLL does, so the
%   linker has to be told. The list came from
%
%       cargo rustc -p nominal-ffi --crate-type staticlib -- --print native-static-libs
%
%   Re-run that if a dependency bump introduces an unresolved external symbol.

    arguments
        options.Profile (1,1) string {mustBeMember(options.Profile, ["release" "fast"])} = "release"
    end

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    target = fullfile(root, 'target', 'x86_64-pc-windows-msvc', char(options.Profile));

    staticLib = fullfile(target, 'nominal_ffi.lib');
    header = fullfile(root, 'crates', 'ffi', 'include');
    source = fullfile(here, 'src', 'nominalmex.c');
    outDir = fullfile(here, '+nominal', 'private');

    if ~isfile(staticLib)
        suffix = "";
        if options.Profile == "fast"
            suffix = "-fast";
        end
        error('nominal:buildFailed', ...
              ['static library not found at %s\n' ...
               'Build it first: just build-win64%s'], staticLib, suffix);
    end

    if ~isfolder(outDir)
        mkdir(outDir);
    end

    % Windows system libraries the Rust standard library and its dependencies
    % pull in. The MSVC toolchain finds these on its own search path, so they
    % are named rather than located.
    systemLibs = {'-lbcrypt', '-ladvapi32', '-lkernel32', '-lntdll', ...
                  '-luserenv', '-lws2_32', '-ldbghelp'};

    % The windows-targets crate ships its own import libraries inside the cargo
    % registry rather than relying on the Windows SDK, and rustc injects the
    % search path for them. Nothing does that for us here, so they are located
    % by absolute path.
    windowsLibs = findWindowsTargetLibs();

    fprintf('Compiling gateway (%s profile)...\n', options.Profile);
    mex('-R2018a', ...
        ['-I' header], ...
        source, ...
        staticLib, ...
        windowsLibs{:}, ...
        systemLibs{:}, ...
        '-outdir', outDir, ...
        '-output', 'nominalmex');

    fprintf('Built %s\n', fullfile(outDir, ['nominalmex.' mexext]));
    fprintf('\nAdd this folder to the path, then:\n');
    fprintf('    addpath(''%s'')\n', here);
    fprintf('    c = nominal.Client(getenv("NOMINAL_TOKEN"));\n');
    fprintf('    disp(c.whoAmI())\n');
end

function libs = findWindowsTargetLibs()
%FINDWINDOWSTARGETLIBS  Locate the windows-targets import libraries.
%
%   These live under the cargo registry at a version-stamped path, so they are
%   found by pattern rather than named: a dependency bump changes which
%   versions are present, and the build should not need editing for that.
%
%   Several versions can coexist, and more may be present than the current
%   dependency tree needs. All are passed to the linker, which takes only the
%   symbols actually referenced — an unused import library contributes nothing.
%   They are deduplicated by file name because the same library often appears
%   under more than one crate version.

    cargoHome = getenv('CARGO_HOME');
    if isempty(cargoHome)
        cargoHome = fullfile(char(java.lang.System.getProperty('user.home')), '.cargo');
    end

    pattern = fullfile(cargoHome, 'registry', 'src', '*', ...
                       'windows_x86_64_msvc-*', 'lib', 'windows.*.lib');
    found = dir(pattern);

    if isempty(found)
        error('nominal:buildFailed', ...
              ['no windows-targets import libraries found under %s\n' ...
               'Expected them at registry/src/*/windows_x86_64_msvc-*/lib/. ' ...
               'Run a cargo build first so the registry is populated.'], cargoHome);
    end

    [~, keep] = unique({found.name}, 'stable');
    found = found(keep);
    libs = arrayfun(@(f) fullfile(f.folder, f.name), found, 'UniformOutput', false)';
end

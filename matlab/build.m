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

    platform = platformSettings();
    target = fullfile(root, 'target', platform.Triple, char(options.Profile));

    staticLib = fullfile(target, platform.LibName);
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
               'Build it first: just %s%s'], staticLib, platform.Recipe, suffix);
    end

    if ~isfolder(outDir)
        mkdir(outDir);
    end

    fprintf('Compiling gateway (%s, %s profile)...\n', platform.Triple, options.Profile);
    mex('-R2018a', ...
        ['-I' header], ...
        source, ...
        staticLib, ...
        platform.ExtraLibs{:}, ...
        '-outdir', outDir, ...
        '-output', 'nominalmex');

    fprintf('Built %s\n', fullfile(outDir, ['nominalmex.' mexext]));
    fprintf('\nAdd this folder to the path, then:\n');
    fprintf('    addpath(''%s'')\n', here);
    fprintf('    c = nominal.Client.fromProfile();\n');
    fprintf('    disp(c.whoAmI())\n');
end

function platform = platformSettings()
%PLATFORMSETTINGS  Cargo target, library name, and linker flags for this host.
%
%   A Rust staticlib does not record the system libraries it needs the way a
%   shared library does, so the linker has to be told — and the list is
%   per-platform. Get the authoritative one for a host by running, on that host:
%
%       just native-libs
%
%   The Windows and macOS lists have been verified against a real link. The
%   Linux entries are the usual set for this dependency tree and are a starting
%   point, not a tested configuration; if the link reports an unresolved symbol,
%   run the command above and reconcile.

    if ispc
        platform.Triple = 'x86_64-pc-windows-msvc';
        platform.LibName = 'nominal_ffi.lib';
        platform.Recipe = 'build-win64';

        % Named rather than located: the MSVC toolchain has these on its own
        % search path. The windows-targets import libraries do not work that
        % way and are found by absolute path — see findWindowsTargetLibs.
        systemLibs = {'-lbcrypt', '-ladvapi32', '-lkernel32', '-lntdll', ...
                      '-luserenv', '-lws2_32', '-ldbghelp'};
        platform.ExtraLibs = [findWindowsTargetLibs(), systemLibs];

    elseif ismac
        % Apple silicon only. Intel Macs are not supported: the last one
        % shipped in 2020, and carrying a target nobody builds means shipping
        % a triple that has never been linked. Adding it back is this branch
        % plus x86_64-apple-darwin recipes in the justfile.
        if ~strcmp(computer('arch'), 'maca64')
            error('nominal:unsupportedPlatform', ...
                  ['Intel macOS is not supported (this is %s).\n' ...
                   'Apple silicon, Windows x86-64 and Linux x86-64 are.'], ...
                  computer('arch'));
        end
        platform.Triple = 'aarch64-apple-darwin';
        platform.Recipe = 'build-macos-arm64';
        platform.LibName = 'libnominal_ffi.a';

        % Frameworks cannot be passed as -l; they go through the linker flags.
        % This is the list `just native-libs` prints, minus -lSystem/-lc/-lm,
        % which clang links on its own:
        %   Security, CoreFoundation  rustls reading the system trust store
        %   SystemConfiguration      the system_configuration crate, and
        %                            hyper-util's system proxy matcher
        %   iconv                    pulled in transitively by CoreFoundation
        platform.ExtraLibs = { ...
            ['LDFLAGS=$LDFLAGS -framework Security -framework CoreFoundation' ...
             ' -framework SystemConfiguration -liconv'], ...
            '-lc++'};

    else
        platform.Triple = 'x86_64-unknown-linux-gnu';
        platform.LibName = 'libnominal_ffi.a';
        platform.Recipe = 'build-linux-x64';
        platform.ExtraLibs = {'-ldl', '-lpthread', '-lm', '-lrt'};
    end
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

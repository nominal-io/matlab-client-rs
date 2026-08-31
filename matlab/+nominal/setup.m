function setup()
%SETUP  Make the Nominal shared library findable in this MATLAB session.
%
%   Called automatically before the first use, so you should not normally need
%   it. Call it by hand only if you are diagnosing a load failure, or after
%   changing PATH yourself.
%
%   Why this is needed: the MEX gateway links against the Nominal shared
%   library, and Windows resolves a DLL's dependencies relative to the host
%   *executable* — MATLAB's own bin folder — not relative to the MEX file. So
%   putting the DLL beside the gateway is not enough on its own; the folder has
%   to be on PATH before the gateway is first loaded, which is what this does.
%
%   Idempotent, and cheap after the first call.
%
%   See also NOMINAL.SHUTDOWN

    persistent done
    if ~isempty(done)
        return
    end

    libDir = fullfile(fileparts(mfilename('fullpath')), 'private');

    if ~isfile(fullfile(libDir, 'nominal_ffi.dll'))
        error('nominal:libraryMissing', ...
              ['nominal_ffi.dll is not in %s\n' ...
               'Run build.m from the matlab/ folder to compile the gateway ' ...
               'and place the library beside it.'], libDir);
    end

    current = getenv('PATH');
    entries = string(strsplit(current, pathsep));
    if ~any(strcmpi(entries, libDir))
        % Prepended so a stale copy elsewhere on PATH cannot win.
        setenv('PATH', [libDir pathsep current]);
    end

    done = true;
end

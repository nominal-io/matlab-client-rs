function smoketest()
%SMOKETEST  Exercise the MATLAB layer without touching the network.
%
%   Run from the matlab/ folder:
%
%       addpath(pwd); tests.smoketest
%
%   or via `just mex-test`.
%
%   The client connects lazily, so everything short of an actual API call runs
%   offline. What this checks is the MATLAB layer itself — that the classes
%   load, that `arguments` validation fires, that the private MEX resolves from
%   package classes, that errors surface as identified exceptions, and that
%   destructors release handles. The C ABI beneath has its own tests.

    fprintf('Nominal MATLAB smoke test\n');
    fprintf('=========================\n\n');

    passed = 0;
    failed = 0;

    [passed, failed] = check('library loads and reports a timestamp', ...
        @timestampIsPlausible, passed, failed);

    [passed, failed] = check('nanosecond round trip through datetime', ...
        @nanosRoundTrip, passed, failed);

    [passed, failed] = check('doubles are refused as timestamps', ...
        @doubleTimestampRefused, passed, failed);

    [passed, failed] = check('client constructs and reports its base URL', ...
        @clientConstructs, passed, failed);

    [passed, failed] = check('empty optional arguments mean absent', ...
        @emptyOptionalsAbsent, passed, failed);

    [passed, failed] = check('whitespace is trimmed from arguments', ...
        @whitespaceTrimmed, passed, failed);

    [passed, failed] = check('failures raise identified exceptions', ...
        @errorsAreIdentified, passed, failed);

    [passed, failed] = check('delete releases the handle', ...
        @deleteReleases, passed, failed);

    [passed, failed] = check('use after release is rejected', ...
        @useAfterRelease, passed, failed);

    [passed, failed] = check('wrong argument type is rejected', ...
        @wrongTypeRejected, passed, failed);

    fprintf('\n%d passed, %d failed\n', passed, failed);
    if failed > 0
        error('nominal:smokeTestFailed', '%d check(s) failed', failed);
    end
end

% ---------------------------------------------------------------- helpers

function [passed, failed] = check(name, fn, passed, failed)
    try
        fn();
        fprintf('  ok    %s\n', name);
        passed = passed + 1;
    catch e
        fprintf('  FAIL  %s\n        %s: %s\n', name, e.identifier, e.message);
        failed = failed + 1;
    end
end

function assertTrue(condition, message)
    if ~condition
        error('nominal:assertionFailed', '%s', message);
    end
end

function c = offlineClient()
    % A host that does not resolve. Construction succeeds because the client
    % connects lazily; only a real API call would fail.
    c = nominal.Client("test-token", BaseUrl="https://api.example.invalid/api");
end

% ------------------------------------------------------------------ checks

function timestampIsPlausible()
    t = nominal.now();
    assertTrue(isa(t, 'int64'), 'expected int64');
    % Somewhere after 2020 and before 2100, i.e. the clock is real.
    assertTrue(t > 1577836800e9 && t < 4102444800e9, ...
               sprintf('implausible timestamp %d', t));
end

function nanosRoundTrip()
    dt = datetime(2026, 3, 4, 5, 6, 7, TimeZone="UTC");
    nanos = nominal.toNanos(dt);
    assertTrue(isa(nanos, 'int64'), 'expected int64');
    back = nominal.fromNanos(nanos);
    assertTrue(abs(seconds(back - dt)) < 1e-3, 'round trip drifted');
end

function doubleTimestampRefused()
    threw = false;
    try
        nominal.toNanos(1.7e18);
    catch e
        threw = strcmp(e.identifier, 'nominal:invalidParameter');
    end
    assertTrue(threw, 'a double timestamp should be refused');

    % Zero is the documented exception: it is the "now" sentinel.
    assertTrue(nominal.toNanos(0) == 0, 'zero should be accepted');
end

function clientConstructs()
    c = offlineClient();
    assertTrue(c.BaseUrl == "https://api.example.invalid/api", ...
               sprintf('unexpected base URL: %s', c.BaseUrl));
    assertTrue(c.Handle ~= 0, 'handle 0 must never be issued');
end

function emptyOptionalsAbsent()
    % LabVIEW cannot wire a null pointer and MATLAB users will pass "", so
    % both have to mean "unset" rather than "an empty RID".
    c = nominal.Client("test-token", Workspace="", BaseUrl="");
    assertTrue(c.WorkspaceRid == "", 'workspace should be unset');
    assertTrue(startsWith(c.BaseUrl, "https://"), ...
               'base URL should fall back to the default');
end

function whitespaceTrimmed()
    c = nominal.Client(sprintf("  test-token\r\n"), ...
                       BaseUrl=sprintf("\thttps://api.example.invalid/api  \n"));
    assertTrue(c.BaseUrl == "https://api.example.invalid/api", ...
               sprintf('whitespace survived: "%s"', c.BaseUrl));
end

function errorsAreIdentified()
    c = offlineClient();
    threw = false;
    try
        c.whoAmI();   % needs the network; the host does not resolve
    catch e
        threw = startsWith(e.identifier, 'nominal:');
        assertTrue(~isempty(e.message), 'exception carried no message');
    end
    assertTrue(threw, 'a failing API call should raise a nominal:* exception');
end

function deleteReleases()
    c = offlineClient();
    assertTrue(isvalid(c), 'should start valid');
    delete(c);
    assertTrue(~isvalid(c), 'should be invalid after delete');
end

function useAfterRelease()
    c = offlineClient();
    delete(c);
    threw = false;
    try
        c.BaseUrl;
    catch e
        threw = true;
    end
    assertTrue(threw, 'using a released client should error, not return junk');
end

function wrongTypeRejected()
    % The MATLAB analogue of a LabVIEW coercion dot, except it is an error:
    % a Client is not a Dataset, and the arguments block says so.
    c = offlineClient();
    threw = false;
    try
        nominal.Run(c, int32(1)).addDataset("ref", c);
    catch e
        threw = true;
    end
    assertTrue(threw, 'passing a Client where a Dataset belongs should fail');
end

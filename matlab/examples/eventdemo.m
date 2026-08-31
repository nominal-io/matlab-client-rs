function eventdemo(assetName)
%EVENTDEMO  Exercise event creation and accessors.
%
%   eventdemo                    % throwaway asset
%   eventdemo("engine-3")        % on an existing asset
%
%   Needs NOMINAL_TOKEN. Creates one event of each type on the asset — an
%   instantaneous one and a spanning one.
%
%   Events attach to **assets**, not to runs or datasets. A run displays the
%   events whose time falls inside its window; there is no separate link to
%   make. So to see these on a run, create a run covering the same period.
%
%   See also NOMINAL.EVENT, ASSETDEMO, RUNDEMO

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = connect();
    asset = client.asset(assetName);
    fprintf('Asset %s\n  %s\n', asset.Name, asset.Rid);

    now = datetime("now", TimeZone="UTC");

    % --- an instantaneous event ---------------------------------------
    %
    % Duration defaults to zero, which is what marks a single moment rather
    % than an interval.
    flag = client.createEvent(asset.Rid, "ignition", ...
                              Type = "info", ...
                              Timestamp = now - minutes(5));

    describe(flag);

    % --- a spanning event ---------------------------------------------
    %
    % Duration accepts a MATLAB duration, so seconds/minutes read naturally.
    overspeed = client.createEvent(asset.Rid, "overspeed", ...
                                   Type = "error", ...
                                   Timestamp = now - minutes(3), ...
                                   Duration = seconds(12.5));

    describe(overspeed);

    % --- one of each remaining type -----------------------------------
    %
    % Type drives how the event is presented; there is no behavioural
    % difference between them.
    kinds = ["flag" "success"];
    others = nominal.Event.empty(1, 0);
    for i = 1:numel(kinds)
        others(i) = client.createEvent(asset.Rid, "demo-" + kinds(i), ...
                                       Type = kinds(i), ...
                                       Timestamp = now - minutes(2 - i*0.5));
        describe(others(i));
    end

    % --- teardown -----------------------------------------------------
    %
    % Releasing an event handle does not delete the event in Nominal; it only
    % drops this process's reference to it.
    delete(others);
    delete(overspeed);
    delete(flag);
    delete(asset);
    delete(client);
    fprintf('Done. Events are visible on the asset, and on any run whose\n');
    fprintf('window covers them.\n');
end

function describe(e)
    fprintf('Event "%s" [%s]\n', e.Name, e.Type);
    fprintf('  rid      %s\n', e.Rid);
    fprintf('  at       %s\n', e.Timestamp);
    if e.Duration == seconds(0)
        fprintf('  duration instantaneous\n');
    else
        fprintf('  duration %s\n', e.Duration);
    end
    fprintf('  assets   %s\n', join(e.AssetRids, ", "));
end

function client = connect()
    token = string(getenv("NOMINAL_TOKEN"));
    if token == ""
        error('nominal:demo', 'set NOMINAL_TOKEN in the environment');
    end
    client = nominal.Client(token);
    fprintf('Connected as %s\n', client.whoAmI());
end

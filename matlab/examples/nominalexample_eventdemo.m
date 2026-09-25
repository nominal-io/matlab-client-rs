function results = nominalexample_eventdemo(assetName)
%NOMINALEXAMPLE_EVENTDEMO  Exercise event creation and accessors.
%
%   nominalexample_eventdemo                 % throwaway asset
%   nominalexample_eventdemo("engine-3")     % on an existing asset
%
%   Needs credentials. Creates one event of each type on the asset, including
%   an instantaneous one and a spanning one.
%
%   Events attach to assets, not to runs or datasets. A run shows the events
%   whose time falls inside its window, so to see these on a run, create a run
%   covering the same period.
%
%   See also NOMINAL.EVENT, NOMINALEXAMPLE_ASSETDEMO,
%   NOMINALEXAMPLE_RUNDEMO, NOMINALEXAMPLE_CONNECT

    arguments
        assetName (1,1) string = "nominal-matlab-demo-" + string(posixtime(datetime("now")))
    end

    client = nominalexample_connect();
    asset = client.getOrCreateAsset(assetName);
    fprintf('Asset %s\n  %s\n', asset.Name, asset.Rid);

    % Every event below is placed relative to this instant, so their order on
    % a chart is predictable.
    referenceTime = datetime("now", TimeZone="UTC");

    % --- an instantaneous event ---------------------------------------
    %
    % Duration defaults to zero: a single instant.
    ignitionEvent = client.createEvent(asset.Rid, "ignition", ...
                                       Type = "info", ...
                                       Timestamp = referenceTime - minutes(5));

    describe(ignitionEvent);

    % --- a spanning event ---------------------------------------------
    %
    % Duration accepts a MATLAB duration.
    overspeedEvent = client.createEvent(asset.Rid, "overspeed", ...
                                        Type = "error", ...
                                        Timestamp = referenceTime - minutes(3), ...
                                        Duration = seconds(12.5));

    describe(overspeedEvent);

    % --- one of each remaining type -----------------------------------
    %
    % Type only affects how the event is presented.
    remainingTypes = ["flag" "success"];
    otherEvents = nominal.Event.empty(1, 0);
    for typeIndex = 1:numel(remainingTypes)
        eventType = remainingTypes(typeIndex);
        otherEvents(typeIndex) = client.createEvent( ...
            asset.Rid, "demo-" + eventType, ...
            Type = eventType, ...
            Timestamp = referenceTime - minutes(2 - typeIndex * 0.5));

        describe(otherEvents(typeIndex));
    end

    % --- results ------------------------------------------------------
    %
    % One row per event. There is no list-events endpoint in this client, so
    % this table is the only record of what was created.
    allEvents = [ignitionEvent, overspeedEvent, otherEvents];
    results = struct('Events', table( ...
        arrayfun(@(e) e.Rid, allEvents)', ...
        arrayfun(@(e) e.Name, allEvents)', ...
        arrayfun(@(e) e.Type, allEvents)', ...
        arrayfun(@(e) e.Timestamp, allEvents)', ...
        arrayfun(@(e) e.Duration, allEvents)', ...
        VariableNames=["Rid" "Name" "Type" "Timestamp" "Duration"]));

    % --- teardown -----------------------------------------------------
    %
    % Releasing an event handle does not delete the event in Nominal.
    delete(otherEvents);
    delete(overspeedEvent);
    delete(ignitionEvent);
    delete(asset);
    delete(client);

    fprintf('Done. Events are visible on the asset, and on any run whose\n');
    fprintf('window covers them.\n');
    nominalexample_publish(results, "nominalEvents");
end

function describe(event)
    % Timestamp is a datetime and Duration a duration; string() converts them
    % for %s.
    fprintf('Event "%s" [%s]\n', event.Name, event.Type);
    fprintf('  rid      %s\n', event.Rid);
    fprintf('  at       %s\n', string(event.Timestamp));
    if event.Duration == seconds(0)
        fprintf('  duration instantaneous\n');
    else
        fprintf('  duration %s\n', string(event.Duration));
    end
    fprintf('  assets   %s\n', join(event.AssetRids, ", "));
end

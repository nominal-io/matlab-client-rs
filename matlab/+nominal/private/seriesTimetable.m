function tt = seriesTimetable(nanos, values, channel)
%SERIESTIMETABLE  One fetched channel as a timetable named after it.

    tt = timetable(nominal.fromNanos(nanos), values);

    % A channel really can be called "Time" or "Variables", and a timetable
    % cannot have a variable sharing either dimension name. Move the dimension
    % rather than the channel, so the variable still answers to the name the
    % data actually has.
    if strcmp(char(channel), tt.Properties.DimensionNames{1})
        tt.Properties.DimensionNames{1} = 'RowTimes';
    end
    if strcmp(char(channel), tt.Properties.DimensionNames{2})
        tt.Properties.DimensionNames{2} = 'TableVariables';
    end

    % Assigned rather than passed to the constructor: channel names routinely
    % contain dots ("engine.left.rpm"), and the constructor would quietly
    % rewrite those into valid identifiers.
    tt.Properties.VariableNames = {char(channel)};
end

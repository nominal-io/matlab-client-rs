%% Nominal for MATLAB
% Get data into and out of <https://nominal.io Nominal> from MATLAB.
%
% Run this guide a section at a time. It creates one asset named |engine-3|
% and writes half a second of synthetic telemetry to it.

%% 1. Connect
% Credentials come from a profile on disk, shared with the |nom| CLI and the
% Python client:
%
%  Linux, macOS   ~/.config/nominal/config.yml
%  Windows        %USERPROFILE%\.config\nominal\config.yml
%
% If you have none, run this in a terminal first:
%
%  nom config profile add default -t <api-token>

client = nominal.Client.connect();
disp(client.whoAmI())

%% 2. An asset and a dataset
% An asset is the thing under test. A dataset holds channels attached to it.
% Both are fetched by name and created only if absent, so re-running this is
% safe.

asset = client.getOrCreateAsset("engine-3");
dataset = asset.getOrCreateDataset("Bench run 7");

%% 3. Declare units
% Units are UCUM symbols: |"Cel"| not |"C"|, |"1/min"| not |"rpm"|. Set them
% before writing and the first plot comes out labelled.

dataset.setChannelMetadata("rpm", "double", Unit="1/min");
dataset.setChannelMetadata("egt", "double", Unit="Cel");
dataset.setChannelMetadata("psi", "double", Unit="[psi]");

%% 4. Write a matrix
% One column per channel, in the same order as the names.

rows = 500;
t = datetime("now", TimeZone="UTC") - seconds(rows/1000) ...
    + milliseconds(0:rows-1)';
v = [1500 + 10*sin(linspace(0, 6*pi, rows))', ...   % rpm
     700  + (1:rows)' * 0.1, ...                    % egt
     30   + (1:rows)' * 0.05];                      % psi

stackedplot(t, v, DisplayLabels=["rpm" "egt" "psi"])

dataset.write(["rpm" "egt" "psi"], t, v);

%% 5. Read it back
% |fetch| returns a timetable, so |plot|, |retime| and |synchronize| work on
% it directly. Add |Buckets=2000| to decimate a wide window server-side.

back = dataset.fetch("rpm", t(1) - seconds(1), t(end) + seconds(1));
plot(back.Time, back.("rpm"))
title("rpm, read back from Nominal")

%% 6. Release the handles
% Every object holds a native resource. |delete| releases it now; otherwise
% MATLAB does so when the variable is cleared.

delete(dataset);
delete(asset);
delete(client);

%% Things that catch people out
% * *Handles are snapshots.* |update| returns a new object rather than
% changing the one you have, and |a.datasources()| will not show a dataset
% attached since the handle was fetched. Pass |Refresh=true| for the current
% state.
% * *Labels and Properties replace, they do not merge.* Read the existing
% ones first if you mean to add.
% * *|fetch| and |export| take numeric channels only.* A string channel in
% the list fails the whole request.
% * *|job.wait()| raises* if an ingest fails, rather than returning a status.

%% Next
% The demos ship with this toolbox but are not on the path, so they cannot
% take names like |rundemo| in your session. Add them:
%
%  addpath(fullfile(fileparts(fileparts(which('nominal.Client'))), 'examples'))
%  nominalexample_alldemos
%
% For streaming, ingest, export and SQL, see |help nominal.Client| and the
% other classes. Every method has its own help.

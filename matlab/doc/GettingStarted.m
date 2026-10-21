%% Nominal for MATLAB
% Get data into and out of <https://nominal.io Nominal> from MATLAB.
%
% Run this guide a section at a time. It creates one asset named |engine-3|
% and writes half a second of synthetic telemetry to it.

%% 1. Connect
% Credentials come from a profile, the config file Nominal's other clients
% also read. If you don't have one yet, follow API keys setup in the Nominal
% docs:
% <https://nominal-io.github.io/pub-docs/quickstart/quickstart/api-keys-setup/ API keys setup>.

client = nominal.Client.fromProfile();
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
% it directly. Add |Buckets=2000| to have Nominal decimate a wide window.

back = dataset.fetch("rpm", t(1) - seconds(1), t(end) + seconds(1));
plot(back.Time, back.("rpm"))
title("rpm, read back from Nominal")

%% 6. Clean up
% Optional. Deleting an object, or clearing the last variable that holds
% it, releases everything it holds.

delete(dataset);
delete(asset);
delete(client);

%% Things to know
% * *Objects are snapshots.* |update| returns a new object and leaves the one
% you have unchanged. |a.datasources()| asks Nominal once and reuses the
% answer, so pass |Refresh=true| to see a dataset attached since then.
% * *Labels and Properties replace, they do not merge.* Read the existing
% ones first if you mean to add.
% * *|fetch| and |export| take numeric channels only.* A string channel in
% the list fails the whole request.
% * *|job.wait()| raises* if an ingest fails, rather than returning a status.

%% Next
% The demos ship with this toolbox but aren't on the MATLAB path. Add them:
%
%  addpath(fullfile(fileparts(fileparts(which('nominal.Client'))), 'examples'))
%  nominalexample_alldemos
%
% For streaming, ingest, export and SQL, see |help nominal.Client| and the
% other classes. Every method has its own help.

function client = nominalexample_connect()
%NOMINALEXAMPLE_CONNECT  Connect with the default profile and say who you are.
%
%   The demos' opening line: nominal.Client.fromProfile plus a greeting.
%   If you have no profile yet, help nominal.Client.fromProfile explains
%   how to create one.
%
%   Files in this folder carry the nominalexample_ prefix so they do not
%   shadow other functions if the folder is added to the path.
%
%   See also NOMINAL.CLIENT/FROMPROFILE

    client = nominal.Client.fromProfile();
    fprintf('Connected as %s\n', client.whoAmI());
end

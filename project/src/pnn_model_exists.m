function yes=pnn_model_exists(path)
%PNN_MODEL_EXISTS Ignore orphan temporary writes lacking a committed identity.
% An empty generation directory can remain if power is lost during the first
% temporary MAT save. Its unsealed temporary file is preserved, never loaded.
yes=isfile(path)||~isempty(dir(fullfile([path '.generations'],'generation_*.mat*')));
end

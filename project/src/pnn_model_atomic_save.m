function pnn_model_atomic_save(path,payload)
%PNN_MODEL_ATOMIC_SAVE Immutable sealed generations plus an atomic MAT mirror.
% Generations are never overwritten or removed. A torn mirror is harmless:
% pnn_model_load validates the newest intact generation, then falls back to
% an earlier intact generation while retaining and reporting failed records.
assert(isstruct(payload)&&isscalar(payload),'pnn:Save','Scalar struct required.');
folder=fileparts(path);if ~isfolder(folder),mkdir(folder);end
generationDir=[path '.generations'];if ~isfolder(generationDir),mkdir(generationDir);end
files=dir(fullfile(generationDir,'generation_*.mat*'));last=0;
for k=1:numel(files)
    token=regexp(files(k).name,'^generation_(\d+)\.mat','tokens','once');
    if ~isempty(token),last=max(last,str2double(token{1}));end
end
generation=fullfile(generationDir,sprintf('generation_%08d.mat',last+1));
[~,seal]=pnn_checkpoint('write',generation,payload);
temporary=[tempname(folder) '.mat'];clean=onCleanup(@()remove_temp(temporary)); %#ok<NASGU>
[ok,msg]=copyfile(generation,temporary);assert(ok,'pnn:Save','%s',msg);
assert(strcmp(pnn_model_hash(temporary,'file'),seal.sha256),'pnn:Save','Mirror copy hash mismatch.');
[ok,msg]=movefile(temporary,path,'f');assert(ok,'pnn:Save','%s',msg);
end
function remove_temp(path)
if isfile(path),delete(path);end
end

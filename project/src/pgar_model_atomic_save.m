function pgar_model_atomic_save(path,payload)
%PGAR_MODEL_ATOMIC_SAVE Save a scalar struct's fields, then rename atomically.
% Temp files live beside the destination; interruption never replaces a good
% checkpoint with a partially written MAT file. One trainer owns each run.
assert(isstruct(payload)&&isscalar(payload),'pgar:Save','Expected scalar struct.');
folder=fileparts(path);if ~exist(folder,'dir'),mkdir(folder);end
temporary=[tempname(folder) '.mat'];
cleanup=onCleanup(@()remove_temporary(temporary)); %#ok<NASGU>
save(temporary,'-struct','payload','-v7.3');
[ok,msg]=movefile(temporary,path,'f');assert(ok,'pgar:Save','%s',msg);
end
function remove_temporary(path)
if exist(path,'file'),delete(path);end
end

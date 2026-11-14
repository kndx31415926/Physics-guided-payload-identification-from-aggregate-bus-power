function prc_lao_atomic_save(path,payload)
%PRC_LAO_ATOMIC_SAVE Same-directory save then rename; one writer per outdir.
folder=fileparts(path);if ~exist(folder,'dir'),mkdir(folder);end
temporary=[tempname(folder) '.mat'];
try
    save(temporary,'-struct','payload','-v7.3');
    [ok,message]=movefile(temporary,path,'f');assert(ok,'prc:LaoSave','%s',message);
catch err
    if exist(temporary,'file'),delete(temporary);end
    rethrow(err);
end
end

function bpil_hefting_save(file,session_result)
% Atomic immutable capture save. Compressed MAT avoids HDF5 object overhead
% for thousands of small event/sample structs; very large captures use v7.3.
assert(isstruct(session_result)&&isscalar(session_result),'bpil:Session','Expected a scalar capture result.');
assert(~isfile(file),'bpil:SessionExists','Preserve the existing capture file.');
folder=fileparts(file);if isempty(folder),folder=pwd;end
if ~isfolder(folder),mkdir(folder);end
temporary=[tempname(folder) '.mat'];cleanup=onCleanup(@()remove_temp(temporary)); %#ok<NASGU>
metadata=whos('session_result');format='-v7';
if metadata.bytes>=1.5e9,format='-v7.3';end
save(temporary,'session_result',format);
saved=whos('-file',temporary,'session_result');
assert(numel(saved)==1&&isequal(saved.size,[1 1]),'bpil:SessionSave','Saved capture verification failed.');
assert(~isfile(file),'bpil:SessionExists','A capture with this name appeared during saving.');
[ok,message]=movefile(temporary,file);assert(ok,'bpil:SessionSave','%s',message);
end
function remove_temp(file)
if isfile(file),delete(file);end
end

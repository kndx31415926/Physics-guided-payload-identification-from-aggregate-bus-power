function bpil_capture_preflight(file)
%BPIL_CAPTURE_PREFLIGHT Check destination before opening an acquisition device.
assert((ischar(file)||(isstring(file)&&isscalar(file)))&&strlength(file)>0, ...
    'bpil:SessionName','Choose a capture filename.');
assert(~isfile(file),'bpil:SessionExists','Preserve the existing capture file.');
assert(~isfolder(file),'bpil:SessionName','The capture filename is a directory.');
folder=fileparts(file);if isempty(folder),folder=pwd;end
if ~isfolder(folder)
    [ok,message]=mkdir(folder);assert(ok,'bpil:SessionFolder','%s',message);
end
probe=[tempname(folder) '.capture-write-check'];
fid=fopen(probe,'w');assert(fid>=0,'bpil:SessionFolder','Capture directory is not writable.');
cleanup=onCleanup(@()remove_probe(probe)); %#ok<NASGU>
fclose(fid);
end
function remove_probe(file)
if isfile(file),delete(file);end
end

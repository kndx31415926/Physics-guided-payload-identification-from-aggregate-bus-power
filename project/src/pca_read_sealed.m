function [payload,audit]=pca_read_sealed(path,isGenerational)
%PCA_READ_SEALED Read-only verification; never repairs a source checkpoint.
if nargin<2,isGenerational=false;end
path=char(path);file=path;
if isGenerational
    listing=dir(fullfile([path '.generations'],'generation_*.mat'));
    assert(~isempty(listing),'pca:Source','No sealed model generations.');
    [~,ix]=sort({listing.name});listing=listing(ix);file=fullfile(listing(end).folder,listing(end).name);
end
assert(isfile(file)&&isfile([file '.sha256.json'])&&~isfile([file '.seal_pending.json']), ...
    'pca:SourceSeal','Source must already have a complete seal: %s',file);
seal=jsondecode(fileread([file '.sha256.json']));d=dir(file);hash=prc_file_hash(file);
assert(strcmpi(seal.file,file)&&seal.bytes==d.bytes&&strcmp(seal.sha256,hash), ...
    'pca:SourceSeal','Source checkpoint differs from its seal: %s',file);
if isGenerational
    assert(isfile(path)&&strcmp(prc_file_hash(path),hash),'pca:SourceMirror', ...
        'Source mirror mismatch requires separate recovery, not this reader.');
end
payload=load(file);audit=struct('requested_path',path,'sealed_path',file,'sha256',hash);
end

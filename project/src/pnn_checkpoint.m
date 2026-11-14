function [payload,seal]=pnn_checkpoint(action,file,payload)
%PNN_CHECKPOINT Atomic immutable MAT with a precommitted SHA-256 seal.
% A crash between MAT and seal renames is recoverable from the pending seal.
% Existing unsealed MAT files are never blessed by recomputing their hash.
file=char(file);sealfile=[file '.sha256.json'];pending=[file '.seal_pending.json'];
if nargin<3,payload=[];end
switch char(action)
    case 'exists'
        payload=isfile(file)||isfile(sealfile)||isfile(pending);seal=[];return
    case 'read'
        seal=recover(file,sealfile,pending);payload=load(file);return
    case 'write'
        assert(isstruct(payload)&&isscalar(payload),'pnn:CheckpointPayload','MAT payload must be a scalar struct.');
        assert(~isfile(file)&&~isfile(sealfile)&&~isfile(pending),'pnn:CheckpointExists','Refusing to replace %s.',file);
        folder=fileparts(file);assert(isfolder(folder),'pnn:CheckpointParent','Missing checkpoint folder.');
        temporary=fullfile(folder,['pnn_' char(javaMethod('randomUUID','java.util.UUID')) '.mat']);
        save(temporary,'-struct','payload','-v7.3');
        seal=struct('schema','pnn_atomic_sha256_v1','file',file,'temporary',temporary, ...
            'sha256',prc_file_hash(temporary),'bytes',dir_bytes(temporary));
        write_new_json(pending,seal);
        assert(~isfile(file),'pnn:CheckpointRace','Checkpoint appeared before commit.');
        [ok,msg]=movefile(temporary,file);assert(ok,'pnn:CheckpointSave','%s',msg);
        assert(~isfile(sealfile),'pnn:CheckpointRace','Seal appeared before commit.');
        [ok,msg]=movefile(pending,sealfile);assert(ok,'pnn:CheckpointSeal','%s',msg);
        seal=recover(file,sealfile,pending);
    otherwise,error('pnn:CheckpointAction','Unknown checkpoint action.');
end
end
function seal=recover(file,sealfile,pending)
if isfile(sealfile)
    seal=jsondecode(fileread(sealfile));
    assert(~isfile(pending),'pnn:CheckpointConflict','Both committed and pending seals exist.');
elseif isfile(pending)
    seal=jsondecode(fileread(pending));validate_seal(seal,file);
    if ~isfile(file)
        assert(isfile(seal.temporary)&&strcmp(prc_file_hash(seal.temporary),seal.sha256), ...
            'pnn:CheckpointRecovery','Pending MAT is missing or changed.');
        assert(strcmpi(fileparts(seal.temporary),fileparts(file)), ...
            'pnn:CheckpointRecovery','Temporary checkpoint escaped its destination folder.');
        [ok,msg]=movefile(seal.temporary,file);assert(ok,'pnn:CheckpointRecovery','%s',msg);
    end
    assert(strcmp(prc_file_hash(file),seal.sha256),'pnn:CheckpointChanged','Pending committed MAT changed.');
    [ok,msg]=movefile(pending,sealfile);assert(ok,'pnn:CheckpointRecovery','%s',msg);
else,error('pnn:CheckpointUnsealed','Missing precommitted seal for %s.',file);
end
validate_seal(seal,file);
assert(isfile(file)&&dir_bytes(file)==seal.bytes&&strcmp(prc_file_hash(file),seal.sha256), ...
    'pnn:CheckpointChanged','Sealed checkpoint changed: %s',file);
end
function validate_seal(seal,file)
assert(isstruct(seal)&&all(isfield(seal,{'schema','file','temporary','sha256','bytes'}))&& ...
    strcmp(seal.schema,'pnn_atomic_sha256_v1')&&strcmpi(seal.file,file)&& ...
    ~isempty(regexp(seal.sha256,'^[0-9a-f]{64}$','once')), ...
    'pnn:CheckpointSeal','Invalid checkpoint seal.');
end
function n=dir_bytes(file),d=dir(file);assert(isscalar(d),'pnn:CheckpointFile','Expected one file.');n=d.bytes;end
function write_new_json(file,value)
t=[file '.' char(javaMethod('randomUUID','java.util.UUID')) '.tmp'];
fid=fopen(t,'w','n','UTF-8');assert(fid>=0,'pnn:CheckpointWrite','Cannot create seal.');
c=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));clear c
assert(~isfile(file),'pnn:CheckpointRace','Pending seal appeared.');
[ok,msg]=movefile(t,file);assert(ok,'pnn:CheckpointWrite','%s',msg);
end

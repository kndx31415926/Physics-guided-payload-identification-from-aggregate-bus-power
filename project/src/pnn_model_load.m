function [payload,audit]=pnn_model_load(path)
%PNN_MODEL_LOAD Validate immutable checkpoint generations, newest first.
% A malformed generation is preserved and documented, never rehashed into
% acceptance. Successful fallback does not rewrite the canonical MAT mirror.
generationDir=[path '.generations'];assert(isfolder(generationDir),'pnn:UnsealedModel','Missing model generations.');
files=dir(fullfile(generationDir,'generation_*.mat*'));numbers=[];
for k=1:numel(files)
    token=regexp(files(k).name,'^generation_(\d+)\.mat','tokens','once');
    if ~isempty(token),numbers(end+1)=str2double(token{1});end %#ok<AGROW>
end
numbers=sort(unique(numbers),'descend');assert(~isempty(numbers),'pnn:UnsealedModel','No model generation found.');
failures=struct('generation',{},'identifier',{},'message',{});payload=[];seal=[];chosen='';
for n=numbers
    candidate=fullfile(generationDir,sprintf('generation_%08d.mat',n));
    try
        [payload,seal]=pnn_checkpoint('read',candidate);chosen=candidate;break
    catch err
        failures(end+1)=struct('generation',candidate,'identifier',err.identifier,'message',err.message); %#ok<AGROW>
    end
end
assert(~isempty(chosen),'pnn:NoValidCheckpoint','No valid sealed model generation remains.');
mirrorOK=isfile(path)&&strcmp(pnn_model_hash(path,'file'),seal.sha256);
audit=struct('generation',chosen,'sha256',seal.sha256,'mirror_matches',mirrorOK,'failures',failures);
if ~isempty(failures)||~mirrorOK
    report=struct('created_at',char(datetime('now','TimeZone','UTC')),'path',path,'audit',audit);
    name=fullfile(generationDir,['RECOVERY_' char(javaMethod('randomUUID','java.util.UUID')) '.json']);
    fid=fopen(name,'w');assert(fid>=0,'pnn:RecoveryAudit','Cannot preserve recovery report.');
    fwrite(fid,jsonencode(report,'PrettyPrint',true),'char');fclose(fid);
end
end

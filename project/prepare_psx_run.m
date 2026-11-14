function runDir=prepare_psx_run(name,profile)
%PREPARE_PSX_RUN Prepare an additional simulation study without launching it.
if nargin<2,profile='smoke';end
assert(ismember(profile,{'smoke','formal'}),'psx:Profile','Unknown profile.');
assert(~isempty(regexp(name,'^psx_[A-Za-z0-9_-]+$','once')),'psx:Name','Use a unique psx_ run name.');
root=fileparts(mfilename('fullpath'));addpath(root);startup_bpil;
runDir=fullfile(root,'results',name);assert(~isfolder(runDir),'psx:Exists','Use existing checkpoints or a new run identity.');
spec=struct('schema','psx_supplement_v1','run_id',name,'smoke_test',strcmp(profile,'smoke'), ...
    'source_run',fullfile(root,'results','pnn_large_training_20261031_v1'),'test_objects',500, ...
    'development_per_condition',Inf,'object_seed',26110601,'object_id_base',6100000, ...
    'sensor_seed_base',26120000,'communication_seed_base',26130000,'nuisance_seed_base',26140000, ...
    'bootstrap_seed',26110602,'bootstrap_replicates',5000,'severities',[0 .5 1], ...
    'workers',1,'automatic_start',false,'formal_authorization_required',true, ...
    'scope','Offline same-geometry cross-model and matched-loss studies; no hardware/online adaptation claim.', ...
    'created_utc',pnn_utc());
if spec.smoke_test
    spec.test_objects=2;spec.development_per_condition=4;spec.object_seed=27110601;spec.object_id_base=7100000;
    spec.sensor_seed_base=27120000;spec.communication_seed_base=27130000;spec.nuisance_seed_base=27140000;
    spec.bootstrap_replicates=0;spec.severities=[0 1];
end
required={'pix_config','pix_condition','pix_simulate_probe','pfl_train','pfl_spec','psx_evaluate','psx_generate_panel','psx_read_frozen'};
for i=1:numel(required),assert(exist(required{i},'file')==2,'psx:Missing','Missing %s.',required{i});end
mkdir(runDir);snapshot=fullfile(runDir,'source_snapshot');mkdir(snapshot);
for folder={'src','vendor','tests'},copyfile(fullfile(root,folder{1}),fullfile(snapshot,folder{1}));end
for file={'startup_bpil.m','prepare_psx_run.m','run_psx_job.m'},copyfile(fullfile(root,file{1}),fullfile(snapshot,file{1}));end
copyfile(fullfile(root,'docs','simulation_supplement_protocol_20261106.txt'),fullfile(runDir,'FROZEN_PROTOCOL.txt'));
save(fullfile(runDir,'configuration.mat'),'spec','-v7.3');prc_write_json(fullfile(runDir,'spec.json'),spec);
listing=dir(fullfile(snapshot,'**','*'));listing=listing(~[listing.isdir]);
relative_path=strings(numel(listing),1);sha256=relative_path;
for i=1:numel(listing)
    file=fullfile(listing(i).folder,listing(i).name);relative_path(i)=string(file(numel(snapshot)+2:end));sha256(i)=prc_file_hash(file);
end
writetable(table(relative_path,sha256),fullfile(runDir,'source_manifest.csv'));
lock=struct('source_manifest_sha256',prc_file_hash(fullfile(runDir,'source_manifest.csv')), ...
    'configuration_sha256',prc_file_hash(fullfile(runDir,'configuration.mat')), ...
    'protocol_sha256',prc_file_hash(fullfile(runDir,'FROZEN_PROTOCOL.txt')),'created_utc',pnn_utc());
prc_write_json(fullfile(runDir,'PREPARED_LOCK.json'),lock);
prc_write_json(fullfile(runDir,'status.json'),struct('state','prepared','phase','not_started','smoke_test',spec.smoke_test, ...
    'message','No execution authorized by preparation. Formal study awaits explicit user instruction.','updated_utc',pnn_utc()));
fprintf('Prepared only (%s): %s\n',profile,runDir);
end

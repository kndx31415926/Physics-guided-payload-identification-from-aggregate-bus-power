function runDir=prepare_pbd_run(name)
% Prepare a bounded exploratory study; preparation does not start generation.
root=fileparts(mfilename('fullpath'));
assert(~isempty(regexp(name,'^pbd_[A-Za-z0-9_]+$','once')));
runDir=fullfile(root,'results',name);assert(~isfolder(runDir),'pbd:Exists','Use a new run identity.');
parent=fullfile(root,'results','psx_supplement_formal_20261106_v1');
parentSnapshot=fullfile(parent,'source_snapshot');
addpath(parentSnapshot,fullfile(parentSnapshot,'src'),fullfile(parentSnapshot,'vendor','bdcl_v29'));
required={fullfile(root,'run_pbd_job.m'),fullfile(root,'src','pbd_analyze.m'),fullfile(root,'src','pbd_row_diagnostics.m'), ...
    fullfile(root,'scripts','pbd_worker.ps1'),fullfile(root,'scripts','pbd_background.ps1'), ...
    fullfile(root,'docs','pbd_exploration_protocol_20261110.txt')};
for k=1:numel(required),assert(isfile(required{k}),'pbd:Missing','Missing %s',required{k});end
L=jsondecode(fileread(fullfile(parent,'PREPARED_LOCK.json')));
assert(strcmp(L.source_manifest_sha256,prc_file_hash(fullfile(parent,'source_manifest.csv'))));
assert(strcmp(L.configuration_sha256,prc_file_hash(fullfile(parent,'configuration.mat'))));
assert(strcmp(L.protocol_sha256,prc_file_hash(fullfile(parent,'FROZEN_PROTOCOL.txt'))));
T=readtable(fullfile(parent,'source_manifest.csv'),'TextType','string','Delimiter',',');
for k=1:height(T),assert(strcmp(prc_file_hash(fullfile(parentSnapshot,T.relative_path(k))),T.sha256(k)));end
parentModel=fullfile(parent,'combined_bundle.mat');modelLock=jsondecode(fileread(fullfile(parent,'MODEL_LOCK.json')));
assert(strcmp(prc_file_hash(parentModel),modelLock.bundle_sha256)&&~modelLock.selection_uses_test);
B=pnn_checkpoint('read',parentModel);bundle=B.bundle;
oldSpec=load(fullfile(parent,'configuration.mat'),'spec');sourceRun=oldSpec.spec.source_run;
im=readtable(fullfile(sourceRun,'input_manifest.csv'),'TextType','string','Delimiter',',');
sourceConfig=fullfile(sourceRun,'configuration.mat');ix=endsWith(replace(im.input_path,'\','/'),'/configuration.mat');
assert(sum(ix)==1&&strcmp(prc_file_hash(sourceConfig),im.sha256(ix)));
C=load(sourceConfig,'cfg','spec');cfg=C.cfg;pnnSpec=C.spec;
spec=struct('schema','pbd_exploration_v1','run_id',name,'exploratory_only',true,'object_count',12, ...
    'object_seed',26111011,'object_id_base',8100000,'sensor_seed_base',28111000, ...
    'communication_seed_base',29111000,'nuisance_seed_base',30111000, ...
    'severity_levels',[0 .1 .25 .5 1],'bootstrap_seed',31111001,'bootstrap_replicates',5000, ...
    'source_run',parent,'original_training_run',sourceRun,'source_model_sha256',modelLock.bundle_sha256, ...
    'primary_method',bundle.primary_method,'automatic_start',false,'automatic_retry',false, ...
    'future_confirmation_authorized',false,'created_utc',pnn_utc());
stream=RandStream('mt19937ar','Seed',spec.object_seed);U=zeros(spec.object_count,3);
for j=1:3,U(:,j)=(randperm(stream,spec.object_count).'-rand(stream,spec.object_count,1))/spec.object_count;end
theta=pnnSpec.range_lower+U.*pnnSpec.range_span;
objects=table((spec.object_id_base+(1:spec.object_count)).',theta(:,1),theta(:,2),theta(:,3), ...
    'VariableNames',{'object_id','mass_kg','cx_m','cz_m'});
cells=struct('cell_id',1,'family','baseline','severity',0,'condition','baseline_s0');
for severity=spec.severity_levels(2:end)
    for family={'mechanical','electrical','combined'}
        cells(end+1)=struct('cell_id',numel(cells)+1,'family',family{1},'severity',severity, ...
            'condition',[family{1} '_s' num2str(severity)]); %#ok<AGROW>
    end
end
pixSpec=pix_config(cfg);pixSpec.severities=spec.severity_levels;
probes=bpil_probe_library(cfg);probe=probes(pnnSpec.probe_index);
% Algebraic pairing checks at all new severities; no inference outcome is used.
for severity=spec.severity_levels
    a=pix_condition(pixSpec,'mechanical',severity,spec.nuisance_seed_base+1);
    b=pix_condition(pixSpec,'electrical',severity,spec.nuisance_seed_base+1);
    c=pix_condition(pixSpec,'combined',severity,spec.nuisance_seed_base+1);
    assert(isequal(a.link_mass_scale,c.link_mass_scale)&&isequal(b.resistance_scale,c.resistance_scale));
    assert(all(a.resistance_scale==1)&&all(b.link_mass_scale==1));
end
mkdir(runDir);snapshot=fullfile(runDir,'source_snapshot');copyfile(parentSnapshot,snapshot);
copyfile(fullfile(root,'prepare_pbd_run.m'),fullfile(snapshot,'prepare_pbd_run.m'));
copyfile(fullfile(root,'run_pbd_job.m'),fullfile(snapshot,'run_pbd_job.m'));
for file={'pbd_analyze.m','pbd_row_diagnostics.m'},copyfile(fullfile(root,'src',file{1}),fullfile(snapshot,'src',file{1}));end
copyfile(required{end},fullfile(runDir,'FROZEN_PROTOCOL.txt'));
mkdir(fullfile(runDir,'launcher_snapshot'));
launch=struct('file',{},'sha256',{});
for k=1:2
    names={'pbd_worker.ps1','pbd_background.ps1'};file=names{k};
    dest=fullfile(runDir,'launcher_snapshot',file);copyfile(fullfile(root,'scripts',file),dest);
    launch(k)=struct('file',file,'sha256',prc_file_hash(dest));
end
prc_write_json(fullfile(runDir,'launcher_manifest.json'),launch);
pnn_checkpoint('write',fullfile(runDir,'inputs.mat'),struct('spec',spec,'cfg',cfg,'pnnSpec',pnnSpec, ...
    'objects',objects,'cells',cells,'pixSpec',pixSpec,'probe',probe));
pnn_checkpoint('write',fullfile(runDir,'model_bundle.mat'),struct('bundle',bundle));
prc_write_json(fullfile(runDir,'spec.json'),spec);writetable(objects,fullfile(runDir,'objects.csv'));
writetable(struct2table(cells),fullfile(runDir,'cells.csv'));
prc_write_json(fullfile(runDir,'MODEL_PROVENANCE.json'),struct('parent_model_sha256',modelLock.bundle_sha256, ...
    'bundle_content_hash',pnn_model_hash(bundle),'new_container_sha256',prc_file_hash(fullfile(runDir,'model_bundle.mat')), ...
    'weights_modified',false,'training_performed',false));
listing=dir(fullfile(snapshot,'**','*'));listing=listing(~[listing.isdir]);
relative_path=strings(numel(listing),1);sha256=relative_path;
for k=1:numel(listing),file=fullfile(listing(k).folder,listing(k).name);relative_path(k)=string(file(numel(snapshot)+2:end));sha256(k)=prc_file_hash(file);end
writetable(table(relative_path,sha256),fullfile(runDir,'source_manifest.csv'));
lock=struct('source_manifest_sha256',prc_file_hash(fullfile(runDir,'source_manifest.csv')), ...
    'inputs_sha256',prc_file_hash(fullfile(runDir,'inputs.mat')),'model_sha256',prc_file_hash(fullfile(runDir,'model_bundle.mat')), ...
    'protocol_sha256',prc_file_hash(fullfile(runDir,'FROZEN_PROTOCOL.txt')),'created_utc',pnn_utc());
prc_write_json(fullfile(runDir,'PREPARED_LOCK.json'),lock);
prc_write_json(fullfile(runDir,'status.json'),struct('state','prepared','phase','not_started','updated_utc',pnn_utc(), ...
    'message','Exploratory protocol prepared; manual start only.','exploratory_only',true));
fprintf('Prepared %d objects x %d cells = %d exploratory trajectories: %s\n',height(objects),numel(cells),height(objects)*numel(cells),runDir);
end

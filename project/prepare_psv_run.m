function run_dir=prepare_psv_run(run_name,options)
% Freeze new objects and all already-selected estimators before generation.
if nargin<1,run_name='psv_frozen_confirmation_20261030_v1';end
if nargin<2,options=struct();end
root=fileparts(mfilename('fullpath'));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
assert(~isempty(regexp(run_name,'^[a-zA-Z0-9][a-zA-Z0-9_-]*$','once')),'psv:Name','Invalid name.');
spec=struct('schema','psv_frozen_confirmation_v1','run_id',run_name,'smoke_test',false, ...
    'model_source_dir',fullfile(root,'results','psf_steady_development_20261030_v1'), ...
    'nominal_source_dir',fullfile(root,'results','pgar_nominal_20261029_v1'), ...
    'lao_source_dir',fullfile(root,'results','prc_lao_comparison_20261029_v3'),'inherit_unstarted_plan_dir','', ...
    'object_count',300,'object_seed',1130101,'object_id_base',2000000, ...
    'sensor_seed_base',11400000,'communication_seed_base',11500000,'bootstrap_seed',1160101,'bootstrap_replicates',3000, ...
    'workers',5,'probe_index',2,'range_lower',[.08 .05 -.018],'range_span',[.14 .14 .036], ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
names=fieldnames(options);for k=1:numel(names),assert(isfield(spec,names{k}),'psv:Option','Unknown option %s.',names{k});spec.(names{k})=options.(names{k});end
assert(spec.workers>=1&&spec.workers<=5&&spec.workers==floor(spec.workers));
if ~spec.smoke_test
    assert(spec.object_count==300&&spec.object_seed==1130101&&spec.sensor_seed_base==11400000&&spec.communication_seed_base==11500000, ...
        'psv:Protocol','Formal seeds/count frozen.');
else
    assert(spec.object_seed~=1130101&&spec.sensor_seed_base~=11400000&&spec.communication_seed_base~=11500000,'psv:SmokeSeeds','Smoke must not expose confirmatory draws.');
end
assert(isfile(fullfile(spec.model_source_dir,'COMPLETE.json'))&&isfile(fullfile(spec.nominal_source_dir,'COMPLETE.json')),'psv:Source','Completed model runs required.');
C=load(fullfile(spec.nominal_source_dir,'configuration.mat'),'cfg');cfg=C.cfg;plan=psv_plan(cfg,spec);audit=psv_seed_audit(root,plan);
run_dir=fullfile(root,'results',run_name);assert(~isfolder(run_dir),'psv:Exists','Existing run; Resume instead.');mkdir(run_dir);
snapshot=fullfile(run_dir,'source_snapshot');mkdir(snapshot);
for folder={'src','vendor','scripts','docs','tests'},copyfile(fullfile(root,folder{1}),fullfile(snapshot,folder{1}));end
files=dir(fullfile(root,'*.m'));for k=1:numel(files),copyfile(fullfile(files(k).folder,files(k).name),snapshot);end
fid=fopen(fullfile(snapshot,'run_pgar_job.m'),'w');assert(fid>=0);fprintf(fid,'function run_pgar_job(run_dir)\nrun_psv_job(run_dir);\nend\n');fclose(fid);
copyfile(fullfile(spec.model_source_dir,'models.mat'),fullfile(run_dir,'frozen_models.mat'));
copyfile(fullfile(spec.lao_source_dir,'models.mat'),fullfile(run_dir,'frozen_lao_models.mat'));
copyfile(fullfile(spec.model_source_dir,'selected_models.csv'),fullfile(run_dir,'frozen_selected_models.csv'));
copyfile(fullfile(root,'docs','psv_confirmation_protocol_20261030.txt'),fullfile(run_dir,'FROZEN_PROTOCOL.txt'));
cfg.root=snapshot;save(fullfile(run_dir,'configuration.mat'),'cfg','spec');save(fullfile(run_dir,'data_plan.mat'),'-struct','plan');
save(fullfile(run_dir,'seed_audit.mat'),'audit');writetable(audit.files,fullfile(run_dir,'seed_audit_inputs.csv'));
writetable(plan.objects,fullfile(run_dir,'objects.csv'));writetable(plan.manifest,fullfile(run_dir,'manifest.csv'));prc_write_json(fullfile(run_dir,'spec.json'),spec);
prc_write_json(fullfile(run_dir,'conditions.json'),plan.conditions);
L=dir(fullfile(snapshot,'**','*'));L=L(~[L.isdir]);relative_path=cell(numel(L),1);sha256=relative_path;
for k=1:numel(L),f=fullfile(L(k).folder,L(k).name);relative_path{k}=strrep(f(numel(snapshot)+2:end),'\','/');sha256{k}=prc_file_hash(f);end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
input_path=[string(fullfile(run_dir,{'configuration.mat','data_plan.mat','spec.json','conditions.json','FROZEN_PROTOCOL.txt','frozen_models.mat','frozen_lao_models.mat','frozen_selected_models.csv'})).'; ...
    string(fullfile(spec.model_source_dir,{'models.mat','selected_models.csv','LOCKED_SELECTION_BEFORE_EVALUATION.mat'})).'; ...
    string(fullfile(spec.nominal_source_dir,'configuration.mat'));string(fullfile(spec.lao_source_dir,'models.mat'));audit.files.input_path];
input_path=unique(input_path,'stable');sha256=strings(size(input_path));for k=1:numel(input_path),sha256(k)=string(prc_file_hash(input_path(k)));end
writetable(table(input_path,sha256),fullfile(run_dir,'input_manifest.csv'));
lock=struct('models_sha256',prc_file_hash(fullfile(run_dir,'frozen_models.mat')),'plan_sha256',prc_file_hash(fullfile(run_dir,'data_plan.mat')), ...
    'source_manifest_sha256',prc_file_hash(fullfile(run_dir,'source_manifest.csv')),'protocol_sha256',prc_file_hash(fullfile(run_dir,'FROZEN_PROTOCOL.txt')), ...
    'model_selection_uses_new_tests',false,'created_utc',spec.created_utc);
save(fullfile(run_dir,'LOCKED_BEFORE_GENERATION.mat'),'lock');
prc_write_json(fullfile(run_dir,'status.json'),struct('run_id',run_name,'state','prepared','phase','not_started','smoke_test',spec.smoke_test));
fprintf('Prepared PSV %d fresh objects x 4 conditions, %d workers: %s\n',spec.object_count,spec.workers,run_dir);
end

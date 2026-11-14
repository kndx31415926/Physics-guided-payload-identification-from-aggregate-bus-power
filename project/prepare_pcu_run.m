function run_dir=prepare_pcu_run(run_name,options)
% Freeze prospective independent stress confirmation, never mutate old runs.
if nargin<1,run_name='pcu_prospective_20261030_v1';end
if nargin<2,options=struct();end
root=fileparts(mfilename('fullpath'));addpath(root,fullfile(root,'src'));
assert(~isempty(regexp(run_name,'^[a-zA-Z0-9][a-zA-Z0-9_-]*$','once')),'pcu:Name','Invalid name.');
base=fullfile(root,'results','prb_joint_gate_dev_20261030_v1');
C=load(fullfile(base,'configuration.mat'),'cfg','spec');cfg=C.cfg;spec=C.spec;
spec.schema='pcu_prospective_confirmation_v1';spec.run_id=run_name;
spec.job_kind='prospective_continual';spec.data_source_dir='';spec.prb_source_dir=base;
spec.stream_seeds=1030101:1030108;spec.sensor_seed_base=10400000;
spec.blocks=4;spec.eval_per_block=4;spec.workers=5;spec.development_fixture=false;
spec.drift_law='smoothstep_axis_exponents_v1';
spec.pcu_keep_history=true;spec.pcu_use_offline=true;
spec.intervals=[1 2 4];spec.bootstrap_repeats=4000;spec.bootstrap_seed=1060101;
spec.study_role='Prospective stress confirmation: new objects/noise and new fixed smooth drift laws; not exact replication of the earlier eight-block linear-drift development.';
spec.scope='Four fixed laws, eight independent object/noise streams per law. Single aggregate power and encoders. Frozen PRB candidate/gate/NN settings. Reference access on 1:k:B, common frozen chronology.';
spec.created_utc=utc();
for f=fieldnames(options).'
    assert(isfield(spec,f{1}),'pcu:Option','Unknown option %s.',f{1});spec.(f{1})=options.(f{1});
end
assert(isequal(spec.intervals,[1 2 4]),'pcu:Schedule','Locked schedules are 1,2,4.');
assert(spec.workers>=1&&spec.workers<=5,'pcu:Workers','At most five workers.');
assert(strcmp(spec.drift_law,'smoothstep_axis_exponents_v1'),'pcu:Law','Locked law.');
% All scientific gate and learner choices are inherited from the frozen dev.
locked={'online_seeds','online_iterations','online_validation_patience','reference_weight','replay_capacity', ...
    'nominal_gate_ratio','reference_requires_teacher','expected_train_references','expected_validation_references', ...
    'gate_min_relative_improvement','gate_min_absolute_improvement','gate_component_mae_tolerance', ...
    'gate_worst_relative_tolerance','gate_worst_absolute_tolerance','reference_train_theta','reference_validation_theta'};
if ~spec.development_fixture
    assert(spec.blocks==4&&spec.eval_per_block==4&&numel(spec.stream_seeds)==8&&numel(spec.scenarios)==4,'pcu:Size','Formal protocol is 1408 trajectories.');
    for f=locked,assert(isequaln(spec.(f{1}),C.spec.(f{1})),'pcu:Locked','Changed frozen method %s.',f{1});end
end
for f={'prb_online_init.m','prb_online_update.m','prb_online_predict.m','prb_gate_candidate.m'}
    assert(strcmp(prc_file_hash(fullfile(root,'src',f{1})),prc_file_hash(fullfile(base,'source_snapshot','src',f{1}))), ...
        'pcu:MethodChanged','Frozen PRB source differs: %s',f{1});
end
assert(isempty(intersect(spec.stream_seeds,C.spec.stream_seeds))&&spec.sensor_seed_base>10000000,'pcu:Seeds','Fresh stream/noise seeds required.');
run_dir=fullfile(root,'results',run_name);assert(~isfolder(run_dir),'pcu:Exists','Use a new name or Resume.');
mkdir(run_dir);snapshot=fullfile(run_dir,'source_snapshot');mkdir(snapshot);
for folder={'src','vendor','scripts','docs','tests'},copyfile(fullfile(root,folder{1}),fullfile(snapshot,folder{1}));end
files=dir(fullfile(root,'*.m'));for i=1:numel(files),copyfile(fullfile(files(i).folder,files(i).name),snapshot);end
copyfile(fullfile(root,'README.md'),snapshot);
fid=fopen(fullfile(snapshot,'run_pgar_job.m'),'w');assert(fid>=0);fprintf(fid,'function run_pgar_job(run_dir)\nrun_pcu_job(run_dir);\nend\n');fclose(fid);
cfg.root=snapshot;spec.data_source_dir=run_dir;
save(fullfile(run_dir,'configuration.mat'),'cfg','spec');prc_write_json(fullfile(run_dir,'spec.json'),spec);
L=dir(fullfile(snapshot,'**','*'));L=L(~[L.isdir]);relative_path=cell(numel(L),1);sha256=relative_path;
for i=1:numel(L),f=fullfile(L(i).folder,L(i).name);relative_path{i}=strrep(f(numel(snapshot)+2:end),'\','/');sha256{i}=prc_file_hash(f);end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
input_path={fullfile(run_dir,'configuration.mat');fullfile(run_dir,'spec.json'); ...
    fullfile(base,'configuration.mat');fullfile(spec.source_dir,'configuration.mat'); ...
    fullfile(spec.source_dir,'model_bundle.mat');fullfile(spec.source_dir,'training_results.mat');fullfile(spec.source_dir,'data_plan.mat')};
for id=1:750,input_path{end+1,1}=fullfile(spec.source_dir,'features',sprintf('trial_%06d.mat',id));end %#ok<AGROW>
for id=spec.retention_ids(:).',input_path{end+1,1}=fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',id));end %#ok<AGROW>
sha256=cellfun(@prc_file_hash,input_path,'UniformOutput',false);writetable(table(input_path,sha256),fullfile(run_dir,'input_manifest.csv'));
prc_write_json(fullfile(run_dir,'status.json'),struct('state','prepared','phase','not_started','run_id',run_name));
fprintf('Prepared PCU: %s, %d trajectories; %d unknown events.\n',run_dir,numel(spec.scenarios)*numel(spec.stream_seeds)*spec.blocks*(spec.eval_per_block+7),numel(spec.scenarios)*numel(spec.stream_seeds)*spec.blocks*spec.eval_per_block);
end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end

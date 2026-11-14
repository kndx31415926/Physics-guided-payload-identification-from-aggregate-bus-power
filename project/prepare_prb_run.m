function run_dir=prepare_prb_run(run_name,options)
% Prepare immutable development replay; never modifies the earlier study.
if nargin<1,run_name='prb_joint_gate_dev_20261030_v1';end
if nargin<2,options=struct();end
root=fileparts(mfilename('fullpath'));addpath(root,fullfile(root,'src'));
assert(~isempty(regexp(run_name,'^[a-zA-Z0-9][a-zA-Z0-9_-]*$','once')),'prb:Name','Invalid run name.');
data_source=fullfile(root,'results','pra_continual_20261030_v1');
if isfield(options,'data_source_dir'),data_source=options.data_source_dir;end
A=load(fullfile(data_source,'configuration.mat'),'cfg','spec');cfg=A.cfg;spec=A.spec;
spec.schema='prb_joint_system_development_v1';spec.run_id=run_name;
spec.job_kind='joint_system_development';spec.data_source_dir=data_source;
spec.online_seeds=[970101 970102 970103];
spec.gate_min_relative_improvement=.05;spec.gate_min_absolute_improvement=1e-6;
spec.gate_component_mae_tolerance=[.00015 .0005 .0005];
spec.gate_worst_relative_tolerance=.05;spec.gate_worst_absolute_tolerance=1e-6;
spec.nominal_gate_ratio=1.25;spec.development_fixture=true;
spec.study_role='Development replay of previously inspected data; not independent confirmation.';
spec.scope='Unknown predictions precede references; eta and network deployed atomically using known references only.';
spec.created_utc=utc();
for f=fieldnames(options).'
    assert(isfield(spec,f{1}),'prb:Option','Unknown option %s.',f{1});spec.(f{1})=options.(f{1});
end
assert(spec.development_fixture,'prb:Role','Reused inspected data must remain development.');
assert(isfile(fullfile(data_source,'COMPLETE.json'))&&isfile(fullfile(data_source,'DATA_COMPLETE.json')),'prb:Source','Completed source required.');
assert(all(ismember(string(spec.scenarios),string(A.spec.scenarios)))&&all(ismember(spec.stream_seeds,A.spec.stream_seeds))&& ...
    spec.blocks>=1&&spec.blocks<=A.spec.blocks&&spec.blocks==fix(spec.blocks),'prb:Subset','Invalid source subset.');
assert(spec.eval_per_block==A.spec.eval_per_block&&isequal(spec.reference_train_theta,A.spec.reference_train_theta)&& ...
    isequal(spec.reference_validation_theta,A.spec.reference_validation_theta),'prb:Subset','Data/reference configuration cannot change during replay.');
run_dir=fullfile(root,'results',run_name);assert(~isfolder(run_dir),'prb:Exists','Use Resume or a new run name.');
mkdir(run_dir);snapshot=fullfile(run_dir,'source_snapshot');mkdir(snapshot);
for folder={'src','vendor','scripts','docs','tests'},copyfile(fullfile(root,folder{1}),fullfile(snapshot,folder{1}));end
files=dir(fullfile(root,'*.m'));for i=1:numel(files),copyfile(fullfile(files(i).folder,files(i).name),snapshot);end
copyfile(fullfile(root,'README.md'),snapshot);
fid=fopen(fullfile(snapshot,'run_pgar_job.m'),'w');assert(fid>=0);fprintf(fid,'function run_pgar_job(run_dir)\nrun_prb_job(run_dir);\nend\n');fclose(fid);
cfg.root=snapshot;save(fullfile(run_dir,'configuration.mat'),'cfg','spec');prc_write_json(fullfile(run_dir,'spec.json'),spec);
L=dir(fullfile(snapshot,'**','*'));L=L(~[L.isdir]);relative_path=cell(numel(L),1);sha256=relative_path;
for i=1:numel(L)
    f=fullfile(L(i).folder,L(i).name);relative_path{i}=strrep(f(numel(snapshot)+2:end),'\','/');sha256{i}=prc_file_hash(f);
end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
input_path={fullfile(run_dir,'configuration.mat');fullfile(run_dir,'spec.json');fullfile(data_source,'configuration.mat'); ...
    fullfile(data_source,'data_plan.mat');fullfile(data_source,'DATA_COMPLETE.json'); ...
    fullfile(data_source,'online_predictions.csv');fullfile(spec.source_dir,'configuration.mat'); ...
    fullfile(spec.source_dir,'model_bundle.mat');fullfile(spec.source_dir,'training_results.mat');fullfile(spec.source_dir,'data_plan.mat')};
for id=1:750,input_path{end+1,1}=fullfile(spec.source_dir,'features',sprintf('trial_%06d.mat',id));end %#ok<AGROW>
P=load(fullfile(data_source,'data_plan.mat'),'manifest');M=P.manifest;
M=M(ismember(string(M.scenario),string(spec.scenarios))&ismember(M.stream_seed,spec.stream_seeds)&M.block<=spec.blocks,:);
for id=M.trial_id(:).',input_path{end+1,1}=fullfile(data_source,'trials',sprintf('trial_%06d.mat',id));end %#ok<AGROW>
for id=spec.retention_ids(:).',input_path{end+1,1}=fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',id));end %#ok<AGROW>
input_path=unique(input_path,'stable');sha256=cellfun(@prc_file_hash,input_path,'UniformOutput',false);
writetable(table(input_path,sha256),fullfile(run_dir,'input_manifest.csv'));
prc_write_json(fullfile(run_dir,'status.json'),struct('state','prepared','phase','not_started','run_id',run_name));
fprintf('Prepared PRB development replay: %s (%d raw records, %d blocks).\n',run_dir,height(M),numel(spec.scenarios)*numel(spec.stream_seeds)*spec.blocks);
end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end

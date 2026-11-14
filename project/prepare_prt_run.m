function run_dir=prepare_prt_run(run_name,options)
% Freeze a separate full-servo communication robustness experiment.
if nargin<1,run_name='prt_comm_20261030_v1';end
if nargin<2,options=struct();end
root=fileparts(mfilename('fullpath'));addpath(root,fullfile(root,'src'));
assert(~isempty(regexp(run_name,'^[a-zA-Z0-9][a-zA-Z0-9_-]*$','once')),'prt:Name','Invalid run name.');
spec=struct('schema','prt_communication_study_v1','run_id',run_name, ...
    'source_dir',fullfile(root,'results','pgar_nominal_20261029_v1'), ...
    'lao_dir',fullfile(root,'results','prc_lao_comparison_20261029_v3'), ...
    'robust_source_dir',fullfile(root,'results','prc_holdout_20261029_v1'), ...
    'robust_ids',3:302,'robust_seeds',[950101 950102 950103], ...
    'workers',4,'train_budget',600,'probe_index',2,'development_fixture',false, ...
    'scope',['Frozen models and same held-out objects; nominal physical plant; ' ...
    'one-way command and encoder-return transport independently fixed 12.5 ms or Uniform(10,15) ms; ' ...
    '50 ms asynchronous schedule; 1 ms upward rounding; no packet loss, clock drift or power delay.'], ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
names=fieldnames(options);
for i=1:numel(names)
    assert(isfield(spec,names{i}),'prt:Option','Unknown option %s.',names{i});
    spec.(names{i})=options.(names{i});
end
assert(spec.workers>=1&&spec.workers==floor(spec.workers),'prt:Workers','Positive integer workers required.');
for source={spec.source_dir,spec.lao_dir,spec.robust_source_dir}
    assert(isfile(fullfile(source{1},'COMPLETE.json')),'prt:IncompleteSource','Source run must be complete.');
end
C=load(fullfile(spec.robust_source_dir,'configuration.mat'),'cfg');cfg=C.cfg;
assert(~isfield(cfg.sim,'communication'),'prt:SourceTiming','Expected legacy source timing.');
run_dir=fullfile(root,'results',run_name);
assert(~isfolder(run_dir),'prt:Exists','Use Resume for an existing frozen run.');
% Validate the entire data plan before making a run directory.
preflight_plan=prt_data_plan(cfg,spec);
mkdir(run_dir);snapshot=fullfile(run_dir,'source_snapshot');mkdir(snapshot);
for folder={'src','vendor','scripts','docs','tests'}
    copyfile(fullfile(root,folder{1}),fullfile(snapshot,folder{1}));
end
files=dir(fullfile(root,'*.m'));
for i=1:numel(files),copyfile(fullfile(files(i).folder,files(i).name),snapshot);end
copyfile(fullfile(root,'README.md'),snapshot);
copyfile(fullfile(root,'STUDIES.txt'),snapshot);
fid=fopen(fullfile(snapshot,'run_pgar_job.m'),'w');assert(fid>=0);
fprintf(fid,'function run_pgar_job(run_dir)\nrun_prt_job(run_dir);\nend\n');fclose(fid);
cfg.root=snapshot;save(fullfile(run_dir,'configuration.mat'),'cfg','spec');
prc_write_json(fullfile(run_dir,'spec.json'),spec);
L=dir(fullfile(snapshot,'**','*'));L=L(~[L.isdir]);
relative_path=cell(numel(L),1);sha256=relative_path;
for i=1:numel(L)
    f=fullfile(L(i).folder,L(i).name);
    relative_path{i}=strrep(f(numel(snapshot)+2:end),'\','/');sha256{i}=prc_file_hash(f);
end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
input_path={fullfile(run_dir,'configuration.mat');fullfile(spec.source_dir,'configuration.mat'); ...
    fullfile(spec.source_dir,'model_bundle.mat');fullfile(spec.source_dir,'training_results.mat'); ...
    fullfile(spec.lao_dir,'models.mat');fullfile(spec.robust_source_dir,'data_plan.mat'); ...
    fullfile(spec.robust_source_dir,'configuration.mat')};
for i=1:height(preflight_plan.objects)
    input_path{end+1,1}=char(preflight_plan.objects.source_path(i)); %#ok<AGROW>
end
sha256=cellfun(@prc_file_hash,input_path,'UniformOutput',false);
writetable(table(input_path,sha256),fullfile(run_dir,'input_manifest.csv'));
prc_write_json(fullfile(run_dir,'status.json'),struct('state','prepared','phase','not_started','run_id',run_name));
fprintf('Prepared communication study: %s\n',run_dir);
end

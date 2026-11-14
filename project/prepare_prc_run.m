function run_dir=prepare_prc_run(run_name,options)
% Freeze the literature-method transplantation benchmark before new test use.
if nargin<1,run_name='prc_lao_comparison_20261029_v3';end
if nargin<2,options=struct();end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'src'));
assert(~isempty(regexp(run_name,'^[a-zA-Z0-9][a-zA-Z0-9_-]*$','once')));
spec=struct('schema','prc_lao_fresh_holdout_v1','run_id',run_name, ...
    'source_dir',fullfile(root,'results','pgar_nominal_20261029_v1'), ...
    'holdout_dir',fullfile(root,'results','prc_holdout_20261029_v1'), ...
    'network_seeds',[830101 830102 830103],'train_budget',600, ...
    'torque_epochs',300,'attention_epochs',30,'lr',.0003,'attention_lr',.0001, ...
    'torque_batch',256,'attention_batch',32,'scale',[.14 .14 .036], ...
    'w_com',.3,'bootstrap_n',2000,'bootstrap_seed',830990,'expected_test_n',300,'development_fixture',false, ...
    'study_role','Prespecified implementations evaluated on a fresh test set after earlier exploratory studies.', ...
    'scope','Lao PE/T/TA method transplant to fixed PID 4R vertical-yaw, 8 poses, planar m/cx/cz. Not reproduction of the original hardware accuracy.', ...
    'test_policy','Use only the NEW holdout test split. The two placeholder train/validation objects in the data-only job are unused.', ...
    'selection_rule','Train-only feature statistics; validation-only epoch choice using common wide-bounds clipped predictions; raw validation diagnostics retained; all three seeds retained; lock before test loading.', ...
    'postprocessing','Report native predictions before common clipping and separately the same wide output bounds for every method; retain intrinsic algorithm constraints; report validity and coverage.', ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
fields=fieldnames(options);
for i=1:numel(fields),assert(isfield(spec,fields{i}));spec.(fields{i})=options.(fields{i});end
assert(isfile(fullfile(spec.source_dir,'COMPLETE.json')),'prc:Source','Source training run must be complete.');
C=load(fullfile(spec.source_dir,'configuration.mat'),'cfg');cfg=C.cfg;
spec.bounds=cfg.ident.bounds;
assert(exist('dlarray','class')==8,'prc:Toolbox','Deep Learning Toolbox required.');
required={'src/prc_lao_train.m','src/prc_lao_predict.m','src/prc_build_dataset.m', ...
    'src/prc_pe_fit.m','src/prc_pe_predict.m','src/prc_evaluate.m','run_prc_job.m'};
for i=1:numel(required),assert(isfile(fullfile(root,required{i})),'prc:Source','Missing %s.',required{i});end
run_dir=fullfile(root,'results',run_name);assert(~isfolder(run_dir),'prc:Exists','Run exists; use Resume.');
mkdir(run_dir);snapshot=fullfile(run_dir,'source_snapshot');mkdir(snapshot);
for folder={'src','vendor','scripts','docs'},copyfile(fullfile(root,folder{1}),fullfile(snapshot,folder{1}));end
files=dir(fullfile(root,'*.m'));
for i=1:numel(files),copyfile(fullfile(files(i).folder,files(i).name),snapshot);end
copyfile(fullfile(root,'README.md'),snapshot);
% The common scheduled-task worker dispatches this benchmark through its
% established entry name; the wrapper is part of this NEW source snapshot.
fid=fopen(fullfile(snapshot,'run_pgar_job.m'),'w');assert(fid>=0);
fprintf(fid,'function run_pgar_job(run_dir)\nrun_prc_job(run_dir);\nend\n');fclose(fid);
cfg.root=snapshot;save(fullfile(run_dir,'configuration.mat'),'cfg','spec');
prc_write_json(fullfile(run_dir,'spec.json'),spec);
listing=dir(fullfile(snapshot,'**','*'));listing=listing(~[listing.isdir]);
relative_path=cell(numel(listing),1);sha256=relative_path;
for i=1:numel(listing)
    f=fullfile(listing(i).folder,listing(i).name);relative_path{i}=strrep(f(numel(snapshot)+2:end),'\','/');
    sha256{i}=prc_file_hash(f);
end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
P=load(fullfile(spec.source_dir,'data_plan.mat'),'objects');
ids=P.objects.object_id(P.objects.split~="test");
input_path={fullfile(spec.source_dir,'configuration.mat');fullfile(spec.source_dir,'data_plan.mat'); ...
    fullfile(spec.source_dir,'training_results.mat');fullfile(spec.source_dir,'model_bundle.mat'); ...
    fullfile(spec.holdout_dir,'configuration.mat');fullfile(spec.holdout_dir,'source_manifest.csv'); ...
    fullfile(run_dir,'configuration.mat')};
for i=1:numel(ids),input_path{end+1,1}=fullfile(spec.source_dir,'trials',sprintf('trial_%06d.mat',ids(i)));end %#ok<AGROW>
sha256=cellfun(@prc_file_hash,input_path,'UniformOutput',false);
writetable(table(input_path,sha256),fullfile(run_dir,'input_manifest.csv'));
prc_write_json(fullfile(run_dir,'status.json'),struct('state','prepared','phase','not_started','run_id',run_name));
fprintf('Prepared PRC: %s\n',run_dir);
end

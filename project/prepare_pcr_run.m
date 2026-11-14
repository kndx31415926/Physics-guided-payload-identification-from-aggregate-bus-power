function run_dir=prepare_pcr_run(run_name)
% Freeze a supplemental matched replay; never mutate the original PCU study.
if nargin<1,run_name='pcr_online_ridge_20261031_v4';end
root=fileparts(mfilename('fullpath'));addpath(root,fullfile(root,'src'));
assert(~isempty(regexp(run_name,'^[a-zA-Z0-9][a-zA-Z0-9_-]*$','once')),'pcr:Name','Invalid run name.');
original=fullfile(root,'results','pcu_prospective_20261030_v1');
assert(isfile(fullfile(original,'COMPLETE.json')),'pcr:Incomplete','Completed original required.');
C=load(fullfile(original,'configuration.mat'),'cfg','spec');cfg=C.cfg;spec=C.spec;
spec.schema='pcr_supplemental_matched_replay_v1';spec.run_id=run_name;
spec.job_kind='online_residual_ridge';spec.data_source_dir=original;
spec.pcr_ridge_source_file=fullfile(root,'results','psv_frozen_confirmation_20261030_v2','frozen_models.mat');
spec.ridge_lambda=0.001;spec.ridge_standardization='fixed_offline';
spec.workers=1;spec.intervals=1;spec.pcu_keep_history=true;spec.pcu_use_offline=true;
spec.study_role='Supplemental post-hoc comparator on unchanged frozen PCU observations; no new plant trajectories.';
spec.scope='Matched online residual ridge with four main systems; fixed offline coordinates and validation-selected penalty, identical calibration/reference chronology/gates; raw primary, paired eight-stream inference.';
spec.created_utc=utc();
run_dir=fullfile(root,'results',run_name);assert(~isfolder(run_dir),'pcr:Exists','Use a new run name or explicit Resume.');
mkdir(run_dir);snapshot=fullfile(run_dir,'source_snapshot');mkdir(snapshot);
% Reuse the original frozen dependencies, then add only the new comparator.
old=fullfile(original,'source_snapshot');
for folder={'src','vendor'},copyfile(fullfile(old,folder{1}),fullfile(snapshot,folder{1}));end
mkdir(fullfile(snapshot,'scripts'));mkdir(fullfile(snapshot,'docs'));mkdir(fullfile(snapshot,'tests'));
copyfile(fullfile(root,'scripts','pgar_task_worker.ps1'),fullfile(snapshot,'scripts'));
for pattern={'src/pcr_*.m','tests/pcr_test*.m'}
    L=dir(fullfile(root,pattern{1}));assert(~isempty(L),'pcr:Source','Missing comparator files.');
    for i=1:numel(L),[~,folder]=fileparts(L(i).folder);copyfile(fullfile(L(i).folder,L(i).name),fullfile(snapshot,folder));end
end
for f={'run_pcr_job.m','prepare_pcr_run.m'},copyfile(fullfile(root,f{1}),snapshot);end
protocol=fullfile(root,'docs','pcr_protocol_20261031.txt');copyfile(protocol,fullfile(snapshot,'docs'));
checks=fullfile(root,'docs','pcr_prelaunch_tests_20261031.json');
J=jsondecode(fileread(checks));assert(J.weighted.passed&&J.core.passed,'pcr:Tests','Prelaunch contracts must pass.');
copyfile(checks,fullfile(snapshot,'docs'));
spec.protocol_file=fullfile(snapshot,'docs','pcr_protocol_20261031.txt');
fid=fopen(fullfile(snapshot,'run_pgar_job.m'),'w');assert(fid>=0);fprintf(fid,'function run_pgar_job(run_dir)\nrun_pcr_job(run_dir);\nend\n');fclose(fid);
cfg.root=snapshot;save(fullfile(run_dir,'configuration.mat'),'cfg','spec');prc_write_json(fullfile(run_dir,'spec.json'),spec);
L=dir(fullfile(snapshot,'**','*'));L=L(~[L.isdir]);relative_path=cell(numel(L),1);sha256=relative_path;
for i=1:numel(L),f=fullfile(L(i).folder,L(i).name);relative_path{i}=strrep(f(numel(snapshot)+2:end),'\','/');sha256{i}=prc_file_hash(f);end
writetable(table(relative_path,sha256),fullfile(run_dir,'source_manifest.csv'));
T=readtable(fullfile(original,'input_manifest.csv'),'TextType','string','Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'VariableNamingRule','preserve');input_path=cellstr(T.input_path);
for i=1:height(T),assert(strcmp(prc_file_hash(char(T.input_path(i))),T.sha256(i)),'pcr:InputDrift','Original input changed: %s',T.input_path(i));end
for f={'configuration.mat','spec.json'},input_path{end+1,1}=fullfile(run_dir,f{1});end
for f={'data_plan.mat','DATA_COMPLETE.json','COMPLETE.json','record_manifest.csv','online_predictions.csv','online_updates.csv','retention_predictions.csv'}
    input_path{end+1,1}=fullfile(original,f{1});
end
input_path{end+1,1}=spec.pcr_ridge_source_file;
sha256=cellfun(@prc_file_hash,input_path,'UniformOutput',false);writetable(table(input_path,sha256),fullfile(run_dir,'input_manifest.csv'));
% Raw records are checked by their already frozen manifest at worker entry.
copyfile(fullfile(original,'record_manifest.csv'),fullfile(run_dir,'inherited_record_manifest.csv'));
prc_write_json(fullfile(run_dir,'status.json'),struct('state','prepared','phase','not_started','run_id',run_name));
fprintf('Prepared supplemental ridge replay: %s\n',run_dir);
end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end

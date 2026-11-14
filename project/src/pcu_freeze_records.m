function T=pcu_freeze_records(run_dir)
P=load(fullfile(run_dir,'data_plan.mat'),'manifest');M=P.manifest;
trial_id=M.trial_id;relative_path=strings(height(M)+2,1);sha256=relative_path;
for i=1:height(M),relative_path(i)=string(fullfile('trials',sprintf('trial_%06d.mat',trial_id(i))));end
relative_path(end-1:end)=["data_plan.mat";"DATA_COMPLETE.json"];
for i=1:numel(relative_path),sha256(i)=string(prc_file_hash(fullfile(run_dir,relative_path(i))));end
T=table(relative_path,sha256);f=fullfile(run_dir,'record_manifest.csv');
if isfile(f),old=readtable(f,'TextType','string','Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'VariableNamingRule','preserve');assert(isequal(old,T),'pcu:RecordHash','Frozen raw records changed.');
else,writetable(T,f);end
end

function [training,evaluation]=psf_plan(spec)
% Separate training-only and evaluation tables prevent accidental test fitting.
P=load(fullfile(spec.source_dir,'data_plan.mat'));O=P.objects;S=string(O.split);
train=find(S=="train");val=find(S=="validation");train=train(1:max(spec.train_sizes));val=val(1:spec.validation_limit);
training=make_rows(O([train;val],:),spec.source_dir,true);training.case_id=(1:height(training)).';
H=load(fullfile(spec.holdout_dir,'data_plan.mat'));ids=double(spec.evaluation_ids(:));
assert(~isempty(ids)&&numel(unique(ids))==numel(ids),'psf:IDs','Unique evaluation IDs required.');
ix=zeros(numel(ids),1);for i=1:numel(ids)
    k=find(H.objects.object_id==ids(i)&string(H.objects.split)=="test");assert(isscalar(k),'psf:IDs','Unavailable heldout object.');ix(i)=k;
end
evaluation=make_rows(H.objects(ix,:),spec.holdout_dir,false);
evaluation.condition(:)="legacy_command20_encoder0";
if spec.include_communication
    C=load(fullfile(spec.comm_dir,'data_plan.mat'));M=C.manifest;
    take=find(ismember(M.object_id,ids));rows=cell(numel(take),1);
    for k=1:numel(take)
        j=take(k);mi=M(j,:);oi=find(evaluation.object_id==mi.object_id);assert(isscalar(oi));
        row=evaluation(oi,:);row.condition=string(mi.condition);row.jitter_seed=mi.jitter_seed;
        if ~mi.reuse_source
            row.record_path=string(fullfile(spec.comm_dir,'trials',sprintf('trial_%06d.mat',mi.trial_id)));
            row.trial_id=mi.trial_id;
        end
        row.feature_path=string(fullfile(spec.comm_dir,'evaluation_checkpoints',sprintf('case_%06d.mat',mi.trial_id)));
        row.feature_kind="prt";rows{k}=row;
    end
    evaluation=vertcat(rows{:});
end
evaluation.case_id=(1:height(evaluation)).';
for T={training,evaluation}
    assert(all(isfile(T{1}.record_path)),'psf:Source','Missing raw record.');
    nonempty=strlength(T{1}.feature_path)>0;assert(all(isfile(T{1}.feature_path(nonempty))),'psf:Source','Missing physical feature cache.');
end
end
function T=make_rows(O,root,training)
n=height(O);record_path=strings(n,1);feature_path=record_path;feature_kind=repmat("compute",n,1);
trial=O.object_id;if ismember('trial_id',O.Properties.VariableNames),trial=O.trial_id;end
for i=1:n
    record_path(i)=string(fullfile(root,'trials',sprintf('trial_%06d.mat',trial(i))));
    if training,feature_path(i)=string(fullfile(root,'features',sprintf('trial_%06d.mat',trial(i))));feature_kind(i)="pgar";end
end
T=table((1:n).',O.object_id,trial,string(O.split),O.mass_kg,O.cx_m,O.cz_m,record_path,feature_path,feature_kind, ...
    repmat("nominal",n,1),zeros(n,1),'VariableNames',{'case_id','object_id','trial_id','split','mass_kg','cx_m','cz_m', ...
    'record_path','feature_path','feature_kind','condition','jitter_seed'});
end

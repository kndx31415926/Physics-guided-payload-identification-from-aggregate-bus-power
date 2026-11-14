function plan=pnn_plan(cfg,spec)
%PNN_PLAN Frozen new object groups; test is a four-condition paired panel.
required={'run_id','counts','split_seeds','sensor_seed_base','communication_seed_base', ...
    'nuisance_seed_base','object_id_base','range_lower','range_span','probe_index','scale','gn_lambda'};
assert(all(isfield(spec,required)),'pnn:PlanSpec','Incomplete data specification.');
counts=double(spec.counts(:).');seeds=double(spec.split_seeds(:).');
assert(numel(counts)==3&&all(counts>=1&counts==floor(counts))&&numel(seeds)==3&&numel(unique(seeds))==3, ...
    'pnn:PlanSpec','Three positive integer split sizes and independent seeds required.');
assert(numel(spec.range_lower)==3&&numel(spec.range_span)==3&&all(spec.range_span>0),'pnn:PlanSpec','Invalid payload range.');
probes=bpil_probe_library(cfg);probe=probes(spec.probe_index);templates=psv_conditions(cfg,probe);
splitnames=["train","validation","test"];families=["nominal","mechanical","electrical","combined"];
theta=zeros(sum(counts),3);split=strings(sum(counts),1);assignment=zeros(sum(counts),1);cursor=0;
for k=1:3
    stream=RandStream('mt19937ar','Seed',seeds(k));n=counts(k);U=zeros(n,3);
    for j=1:3,U(:,j)=(randperm(stream,n).'-1+rand(stream,n,1))/n;end
    ix=cursor+(1:n);theta(ix,:)=spec.range_lower+U.*spec.range_span;split(ix)=splitnames(k);
    family=mod((0:n-1).',4)+1;assignment(ix)=family(randperm(stream,n));cursor=cursor+n;
end
assert(size(unique(theta,'rows'),1)==size(theta,1),'pnn:DuplicateObjects','Payload groups overlap.');
ids=spec.object_id_base+(1:size(theta,1)).';
objects=table(ids,split,theta(:,1),theta(:,2),theta(:,3),'VariableNames',{'object_id','split','mass_kg','cx_m','cz_m'});
N=counts(1)+counts(2)+4*counts(3);object_index=zeros(N,1);condition_index=zeros(N,1);cursor=0;
for i=1:height(objects)
    if split(i)=="test",ci=1:4;else,ci=assignment(i);end
    for c=ci,cursor=cursor+1;object_index(cursor)=i;condition_index(cursor)=c;end
end
trial_id=(1:N).';sensor_seed=spec.sensor_seed_base+trial_id;communication_seed=spec.communication_seed_base+trial_id;
nuisance_seed=spec.nuisance_seed_base+trial_id;
assert(all([seeds sensor_seed.' communication_seed.' nuisance_seed.']>=0)&& ...
    all([seeds sensor_seed.' communication_seed.' nuisance_seed.']<=2^32-1), ...
    'pnn:Seeds','Random seeds outside uint32 range.');
manifest=table(trial_id,ids(object_index),object_index,split(object_index),families(condition_index).', ...
    condition_index,sensor_seed,communication_seed,nuisance_seed, ...
    'VariableNames',{'trial_id','object_id','object_index','split','condition','condition_index','sensor_seed','communication_seed','nuisance_seed'});
conditions=repmat(pnn_conditions(cfg,probe,'nominal',nuisance_seed(1),templates),N,1);
for i=1:N,conditions(i)=pnn_conditions(cfg,probe,manifest.condition(i),nuisance_seed(i),templates);end
cfg_key=struct();for f={'legacy','payload','sensor','sim','ident'},cfg_key.(f{1})=cfg.(f{1});end
key=struct('schema','pnn_full_servo_new_groups_v1','spec',spec,'cfg_key',cfg_key, ...
    'objects',table2struct(objects),'manifest',table2struct(manifest),'conditions',conditions,'probe',probe);
plan=struct('schema',key.schema,'spec',spec,'cfg_key',cfg_key,'objects',objects,'manifest',manifest, ...
    'conditions',conditions,'probe',probe,'plan_signature',psv_hash(key));
end

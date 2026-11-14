function plan=pnn_load_plan(run_dir,cfg,spec)
%PNN_LOAD_PLAN Fail closed if any scientific plan or nominal config changed.
S=load(fullfile(run_dir,'data_plan.mat'));if isfield(S,'plan'),plan=S.plan;else,plan=S;end
required={'schema','spec','cfg_key','objects','manifest','conditions','probe','plan_signature'};
assert(all(isfield(plan,required))&&isequaln(plan.spec,spec),'pnn:PlanMismatch','Frozen specification changed.');
cfg_key=struct();for f={'legacy','payload','sensor','sim','ident'},cfg_key.(f{1})=cfg.(f{1});end
assert(isequaln(cfg_key,plan.cfg_key),'pnn:ConfigMismatch','Frozen simulation/estimator configuration changed.');
key=struct('schema',plan.schema,'spec',plan.spec,'cfg_key',plan.cfg_key, ...
    'objects',table2struct(plan.objects),'manifest',table2struct(plan.manifest), ...
    'conditions',plan.conditions,'probe',plan.probe);
assert(strcmp(psv_hash(key),plan.plan_signature),'pnn:PlanHash','Data plan identity changed.');
end

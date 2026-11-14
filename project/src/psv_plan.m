function plan=psv_plan(cfg,spec)
% New object/noise identities; paired conditions and no estimator fitting.
N=spec.object_count;assert(N>=1&&N==floor(N));
stream=RandStream('mt19937ar','Seed',spec.object_seed);U=zeros(N,3);
for j=1:3,U(:,j)=(randperm(stream,N).'-1+rand(stream,N,1))/N;end
theta=spec.range_lower+U.*spec.range_span;ids=(spec.object_id_base+(1:N)).';
objects=table(ids,theta(:,1),theta(:,2),theta(:,3),'VariableNames',{'object_id','mass_kg','cx_m','cz_m'});
probes=bpil_probe_library(cfg);probe=probes(spec.probe_index);conditions=psv_conditions(cfg,probe);rows=struct([]);
for c=1:numel(conditions),for i=1:N
    z=(c-1)*N+i;row=struct('trial_id',z,'object_id',ids(i),'object_index',i,'condition',string(conditions(c).id), ...
        'condition_index',c,'sensor_seed',spec.sensor_seed_base+i,'communication_seed',spec.communication_seed_base+i,'split',"test");
    if isempty(rows),rows=row;else,rows(z)=row;end %#ok<AGROW>
end,end
manifest=struct2table(rows);cfgkey=struct();for f={'legacy','payload','sensor','sim','ident'},cfgkey.(f{1})=cfg.(f{1});end
key=struct('schema','psv_independent_frozen_validation_v1','spec',spec,'cfg',cfgkey, ...
    'objects',table2struct(objects),'manifest',table2struct(manifest),'conditions',conditions,'probe',probe);
plan=struct('schema',key.schema,'spec',spec,'objects',objects,'manifest',manifest,'conditions',conditions,'probe',probe,'plan_signature',psv_hash(key));
end

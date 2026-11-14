function plan=prt_data_plan(cfg,spec)
%PRT_DATA_PLAN Paired, held-out full-servo communication sensitivity plan.
% Source labels define plant payloads and scores only. Sensor seeds remain
% identical across conditions; communication uses its own random streams.
required={'run_id','source_dir','lao_dir','robust_source_dir','robust_ids','robust_seeds','workers'};
assert(all(isfield(spec,required)),'prt:Spec','Missing communication specification.');
if ~isfield(spec,'probe_index'),spec.probe_index=2;end
if ~isfield(spec,'train_budget'),spec.train_budget=600;end
ids=double(spec.robust_ids(:));seeds=double(spec.robust_seeds(:));
assert(~isempty(ids)&&all(isfinite(ids)&ids>0&ids==floor(ids))&&numel(unique(ids))==numel(ids),'prt:IDs','Invalid IDs.');
assert(~isempty(seeds)&&all(isfinite(seeds)&seeds>=0&seeds<=2^32-1&seeds==floor(seeds))&&numel(unique(seeds))==numel(seeds),'prt:Seeds','Invalid communication seeds.');
assert(isscalar(spec.workers)&&spec.workers>=1&&spec.workers==floor(spec.workers),'prt:Workers','Invalid worker count.');
assert(~isfield(cfg.sim,'communication'),'prt:BaseConfig','Pass the nominal configuration; the plan sets communication per case.');
source=load(fullfile(spec.robust_source_dir,'data_plan.mat'));
for name={'legacy','payload','sensor','sim','ident'}
    assert(isequaln(cfg.(name{1}),source.cfg.(name{1})),'prt:Config','Nominal %s differs from held-out source.',name{1});
end
probes=bpil_probe_library(cfg);probe=probes(spec.probe_index);
assert(isequaln(probe,source.probe)&&size(probe.poses,1)==8,'prt:Probe','Expected identical eight-pose probe.');
C=struct('id',{'legacy_command20_encoder0','fixed_command12p5_encoder12p5','jitter_command10to15_encoder10to15'}, ...
    'randomized',{false,false,true},'reuse_source',{true,false,false}, ...
    'command_delay_s',{[.020 .020],[.0125 .0125],[.010 .015]}, ...
    'encoder_delay_s',{[0 0],[.0125 .0125],[.010 .015]});
N=numel(ids);source_path=strings(N,1);source_hash=strings(N,1);theta=zeros(N,3);sensor=zeros(N,1);source_trial=zeros(N,1);
for i=1:N
    oi=find(source.objects.object_id==ids(i));mi=find(source.manifest.object_id==ids(i));
    assert(isscalar(oi)&&isscalar(mi)&&string(source.objects.split(oi))=="test"&&string(source.manifest.split(mi))=="test", ...
        'prt:SourceSplit','Exactly one test trial is required for each source object.');
    theta(i,:)=[source.objects.mass_kg(oi),source.objects.cx_m(oi),source.objects.cz_m(oi)];
    sensor(i)=source.manifest.sensor_seed(mi);source_trial(i)=source.manifest.trial_id(mi);
    source_path(i)=string(fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',source_trial(i))));
    source_hash(i)=string(prc_file_hash(source_path(i)));
    expected=struct('schema',source.schema,'run_id',source.spec.run_id,'plan_signature',source.plan_signature, ...
        'trial_id',source_trial(i),'object_id',ids(i),'split','test','probe_id',probe.id, ...
        'probe_index',spec.probe_index,'theta_true',theta(i,:),'sensor_seed',sensor(i));
    pgar_data_inspect_record(source_path(i),expected);
end
objects=table(ids,theta(:,1),theta(:,2),theta(:,3),sensor,source_trial,source_path,source_hash, ...
    'VariableNames',{'object_id','mass_kg','cx_m','cz_m','sensor_seed','source_trial_id','source_path','source_sha256'});
rows=struct([]);communications=struct([]);z=0;
for c=1:numel(C)
    cs=0;if C(c).randomized,cs=seeds(:).';end
    for r=1:numel(cs)
        for i=1:N
            z=z+1;realized=0;if C(c).randomized,realized=mod(cs(r)+1009*ids(i),2^32);end
            row=struct('trial_id',z,'object_id',ids(i),'source_index',i,'condition',C(c).id, ...
                'condition_index',c,'replicate_index',r,'jitter_seed',cs(r),'realized_seed',realized, ...
                'sensor_seed',sensor(i),'reuse_source',C(c).reuse_source,'split','test');
            communication=struct('command_delay_s',C(c).command_delay_s,'encoder_delay_s',C(c).encoder_delay_s,'seed',realized);
            if z==1,rows=row;communications=communication;
            else,rows(z)=row;communications(z)=communication;end %#ok<AGROW>
        end
    end
end
manifest=struct2table(rows);cfg_key=struct();for name={'legacy','payload','sensor','sim','ident'},cfg_key.(name{1})=cfg.(name{1});end
input_path={fullfile(spec.source_dir,'training_results.mat');fullfile(spec.lao_dir,'models.mat'); ...
    fullfile(spec.robust_source_dir,'configuration.mat');fullfile(spec.robust_source_dir,'data_plan.mat')};
input_hash=cellfun(@prc_file_hash,input_path,'UniformOutput',false);
root=fileparts(fileparts(mfilename('fullpath')));source_files=source_identity(root,cfg);
data_spec=struct('run_id',spec.run_id,'robust_source_dir',spec.robust_source_dir,'ids',ids,'seeds',seeds, ...
    'probe_index',spec.probe_index,'train_budget',spec.train_budget);
schema='prt_full_servo_communication_v1';
key=struct('schema',schema,'data_spec',data_spec,'cfg_key',cfg_key,'conditions',C, ...
    'objects',table2struct(objects),'manifest',table2struct(manifest),'communications',communications, ...
    'probe',probe,'drift',source.drift,'source_files',table2struct(source_files), ...
    'input_path',{input_path},'input_hash',{input_hash});
plan=struct('schema',schema,'spec',spec,'cfg',cfg,'cfg_key',cfg_key,'data_spec',data_spec, ...
    'conditions',C,'objects',objects,'manifest',manifest,'communications',communications,'probe',probe, ...
    'drift',source.drift,'input_path',{input_path},'input_hash',{input_hash},'source_files',source_files, ...
    'plan_signature',hash_value(key),'created_utc',utc(), ...
    'scope','Paired full-servo command/encoder return delays; unchanged local PID, power timing, sensor seeds and frozen estimators.');
end
function T=source_identity(root,cfg)
files=[dir(fullfile(root,'src','*.m'));dir(fullfile(cfg.root,'vendor','bdcl_v29','**','*.m'))];
assert(~isempty(files),'prt:Source','Simulation source is missing.');
paths=strings(numel(files),1);hashes=paths;
for k=1:numel(files)
    p=fullfile(files(k).folder,files(k).name);paths(k)=replace(string(p),string(root)+filesep,'');
    paths(k)=replace(paths(k),'\','/');hashes(k)=string(prc_file_hash(p));
end
[paths,order]=sort(paths);T=table(paths,hashes(order),'VariableNames',{'relative_path','sha256'});
end
function value=hash_value(v)
md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');md.update(unicode2native(jsonencode(v),'UTF-8'));
value=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
function s=utc(),s=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));end

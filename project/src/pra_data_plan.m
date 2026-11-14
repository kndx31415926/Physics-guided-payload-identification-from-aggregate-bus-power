function plan=pra_data_plan(cfg,spec)
%PRA_DATA_PLAN Fixed chronological evaluation/reference servo stream.
% Unknown evaluation objects precede calibration at each block. Their labels
% are evaluation-only. Objects and sensor RNG seeds are paired by stream and
% episode across scenarios. A zero-mass anchor has conventional COM [.128,0].
spec=defaults(spec);schema='pra_full_servo_drift_v1';
cfg_key=critical_config(cfg);config_signature=signature(cfg_key);
[source_files,source_signature]=source_identity(cfg);
probes=bpil_probe_library(cfg);assert(spec.probe_index<=numel(probes),'pra:Probe','Invalid probe index.');
probe=probes(spec.probe_index);assert(size(probe.poses,1)==8,'pra:Probe','Eight-pose probe required.');
data_spec=dataset_spec(spec);
per_block=spec.eval_per_block+1+size(spec.reference_train_theta,1)+size(spec.reference_validation_theta,1);
per_stream=spec.blocks*per_block;nstreams=numel(spec.stream_seeds);
N=numel(spec.scenarios)*nstreams*per_stream;
theta=zeros(N,3);known_theta=nan(N,3);ids=(1:N).';
scenario=strings(N,1);role=strings(N,1);split=strings(N,1);
stream_seed=zeros(N,1);stream_index=zeros(N,1);block=zeros(N,1);role_index=zeros(N,1);
chronological_index=zeros(N,1);progress=zeros(N,1);sensor_seed=zeros(N,1);paired_object_id=zeros(N,1);
drifts=repmat(pra_drift(0,'stationary'),N,1);
eval_theta=cell(nstreams,1);old_rng=rng;cleanup=onCleanup(@()rng(old_rng)); %#ok<NASGU>
for s=1:nstreams
    rng(spec.stream_seeds(s),'twister');
    u=lhsdesign(spec.blocks*spec.eval_per_block,3,'criterion','maximin','iterations',10);
    eval_theta{s}=spec.range_lower+u.*spec.range_span;
    assert(size(unique(eval_theta{s},'rows'),1)==size(eval_theta{s},1),'pra:DuplicateEval','Duplicate evaluation object.');
    assert(~any(ismember(eval_theta{s},[spec.reference_train_theta;spec.reference_validation_theta],'rows')), ...
        'pra:ReferenceOverlap','An evaluation object equals a reference object.');
end
all_eval=vertcat(eval_theta{:});assert(size(unique(all_eval,'rows'),1)==size(all_eval,1), ...
    'pra:DuplicateEval','Evaluation objects must be distinct between streams.');
i=0;
for c=1:numel(spec.scenarios)
    for s=1:nstreams
        episode=0;
        for b=1:spec.blocks
            values=[eval_theta{s}((b-1)*spec.eval_per_block+(1:spec.eval_per_block),:); ...
                0 cfg.payload.geometry_center_m(1) 0;spec.reference_train_theta;spec.reference_validation_theta];
            roles=[repmat("eval",spec.eval_per_block,1);"anchor"; ...
                repmat("reference_train",size(spec.reference_train_theta,1),1); ...
                repmat("reference_validation",size(spec.reference_validation_theta,1),1)];
            role_ids=[(1:spec.eval_per_block).';1;(1:size(spec.reference_train_theta,1)).';(1:size(spec.reference_validation_theta,1)).'];
            for k=1:per_block
                i=i+1;episode=episode+1;t=(episode-1)/max(1,per_stream-1);
                theta(i,:)=values(k,:);scenario(i)=string(spec.scenarios{c});role(i)=roles(k);
                stream_seed(i)=spec.stream_seeds(s);stream_index(i)=s;block(i)=b;role_index(i)=role_ids(k);
                chronological_index(i)=episode;progress(i)=t;
                sensor_seed(i)=spec.sensor_seed_base+(s-1)*per_stream+episode;
                if roles(k)=="eval"
                    split(i)="test";
                    paired_object_id(i)=(s-1)*spec.blocks*spec.eval_per_block+(b-1)*spec.eval_per_block+k;
                else
                    split(i)=roles(k);known_theta(i,:)=values(k,:);
                end
                drifts(i)=pra_drift(t,spec.scenarios{c});
            end
        end
    end
end
objects=table(ids,split,theta(:,1),theta(:,2),theta(:,3),scenario,stream_seed,block,role, ...
    'VariableNames',{'object_id','split','mass_kg','cx_m','cz_m','scenario','stream_seed','block','role'});
manifest=table(ids,ids,repmat(spec.probe_index,N,1),split,scenario,stream_seed,stream_index,block,role,role_index, ...
    chronological_index,progress,sensor_seed,paired_object_id, ...
    'VariableNames',{'trial_id','object_id','probe_index','split','scenario','stream_seed','stream_index','block','role','role_index', ...
    'chronological_index','progress','sensor_seed','paired_object_id'});
plan_signature=signature(struct('schema',schema,'data_spec',data_spec,'config_signature',config_signature, ...
    'source_signature',source_signature,'probe',probe,'manifest',table2struct(manifest),'theta',theta,'drifts',drifts));
plan=struct('schema',schema,'cfg',cfg,'spec',spec,'cfg_key',cfg_key,'data_spec',data_spec, ...
    'objects',objects,'manifest',manifest,'theta',theta,'known_theta',known_theta,'drifts',drifts,'probe',probe, ...
    'config_signature',config_signature,'source_signature',source_signature,'source_files',source_files, ...
    'plan_signature',plan_signature,'created_utc',utc_now(), ...
    'scope','Accelerated discrete quasi-stationary drift; no empirical wear law; unknown-object labels are evaluation-only.');
end

function s=defaults(s)
assert(isstruct(s)&&isscalar(s),'pra:Spec','Specification must be a scalar struct.');
base=struct('scenarios',{{'stationary','electrical','mechanical','combined'}}, ...
    'stream_seeds',[930101 930102 930103],'blocks',8,'eval_per_block',8,'workers',6, ...
    'sensor_seed_base',940000,'probe_index',2,'range_lower',[.08 .05 -.018],'range_span',[.14 .14 .036], ...
    'reference_train_theta',[.09 .06 -.014;.21 .07 .014;.10 .18 .012;.20 .17 -.012], ...
    'reference_validation_theta',[.12 .10 -.005;.18 .145 .007]);
names=fieldnames(base);for k=1:numel(names),if ~isfield(s,names{k}),s.(names{k})=base.(names{k});end,end
assert(isfield(s,'run_id'),'pra:RunID','run_id is required.');s.run_id=char(string(s.run_id));
assert(isrow(s.run_id)&&~isempty(s.run_id),'pra:RunID','run_id must be nonempty.');
s.scenarios=cellstr(string(s.scenarios(:).'));assert(~isempty(s.scenarios)&&numel(unique(s.scenarios))==numel(s.scenarios), ...
    'pra:Scenario','Scenarios must be a nonempty unique list.');
for k=1:numel(s.scenarios),pra_drift(0,s.scenarios{k});end
s.stream_seeds=double(s.stream_seeds(:).');
assert(~isempty(s.stream_seeds)&&numel(unique(s.stream_seeds))==numel(s.stream_seeds)&& ...
    all(isfinite(s.stream_seeds))&&all(s.stream_seeds>=0)&all(s.stream_seeds<=2^32-1)&all(s.stream_seeds==floor(s.stream_seeds)), ...
    'pra:Seeds','Stream seeds must be unique valid RNG integers.');
for field={'blocks','eval_per_block','workers','sensor_seed_base','probe_index'}
    v=s.(field{1});assert(isnumeric(v)&&isreal(v)&&isscalar(v)&&isfinite(v)&&v==floor(v)&&v>=0, ...
        'pra:Spec','Invalid %s.',field{1});
end
assert(s.blocks>=1&&s.eval_per_block>=1&&s.workers>=1&&s.probe_index>=1,'pra:Spec','Positive counts required.');
for field={'range_lower','range_span'}
    s.(field{1})=double(s.(field{1})(:).');v=s.(field{1});
    assert(numel(v)==3&&isreal(v)&&all(isfinite(v)),'pra:Range','Invalid payload range.');
end
assert(s.range_lower(1)>0&&all(s.range_span>0),'pra:Range','Invalid payload range.');
for field={'reference_train_theta','reference_validation_theta'}
    v=s.(field{1});assert(isnumeric(v)&&isreal(v)&&size(v,2)==3&&size(v,1)>=1&&all(isfinite(v),'all')&&all(v(:,1)>0), ...
        'pra:References','Invalid %s.',field{1});s.(field{1})=double(v);
end
refs=[s.reference_train_theta;s.reference_validation_theta];
assert(size(unique(refs,'rows'),1)==size(refs,1),'pra:References','Train and validation references must be distinct.');
episodes=s.blocks*(s.eval_per_block+1+size(refs,1));
assert(s.sensor_seed_base+numel(s.stream_seeds)*episodes<=2^32-1,'pra:Seeds','Sensor seeds exceed RNG limits.');
end
function key=critical_config(cfg)
fields={'legacy','payload','sensor','sim','ident'};key=struct();
for k=1:numel(fields),assert(isfield(cfg,fields{k}),'pra:Config','Missing cfg.%s.',fields{k});key.(fields{k})=cfg.(fields{k});end
end
function data=dataset_spec(spec)
fields={'run_id','scenarios','stream_seeds','blocks','eval_per_block','sensor_seed_base','probe_index', ...
    'range_lower','range_span','reference_train_theta','reference_validation_theta'};
data=struct();for k=1:numel(fields),data.(fields{k})=spec.(fields{k});end
end
function [files,value]=source_identity(cfg)
root=fileparts(fileparts(mfilename('fullpath')));
names={'pra_data_plan.m','pra_generate_data.m','pra_drift.m','pra_data_trial.m', ...
    'bpil_simulate_probe.m','bpil_make_plant.m','bpil_probe_library.m','pgar_data_inspect_record.m','prc_file_hash.m'};
paths=cellfun(@(n)fullfile(root,'src',n),names,'UniformOutput',false);
vendor=dir(fullfile(cfg.root,'vendor','bdcl_v29','**','*.m'));
assert(~isempty(vendor),'pra:Source','Bundled robot-model source is missing.');
paths=[paths,reshape(arrayfun(@(d)fullfile(d.folder,d.name),vendor,'UniformOutput',false),1,[])];
keys=strings(numel(paths),1);hashes=strings(numel(paths),1);
for k=1:numel(paths)
    if k<=numel(names),keys(k)="src/"+string(names{k});
    else,keys(k)=replace(string(paths{k}),string(fullfile(cfg.root,'vendor'))+filesep,'vendor/');keys(k)=replace(keys(k),'\','/');end
    hashes(k)=string(prc_file_hash(paths{k}));
end
[keys,order]=sort(keys);hashes=hashes(order);
files=table(keys,hashes,'VariableNames',{'relative_path','sha256'});value=signature(table2struct(files));
end
function value=signature(input)
md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');md.update(unicode2native(jsonencode(input),'UTF-8'));
value=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
function value=utc_now()
value=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));
end

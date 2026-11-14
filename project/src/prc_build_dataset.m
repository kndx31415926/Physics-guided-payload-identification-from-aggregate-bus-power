function D=prc_build_dataset(source_dir,cache_path,indices,cfg)
%PRC_BUILD_DATASET Load only explicitly requested trial/object IDs in order.
% Labels are separate from observations. Test torque labels are always NaN.
% A directory cache stores one entry per source-record/config hash. A .mat
% cache_path additionally writes the assembled D there (objects beside it).
source_dir=char(source_dir);cache_path=char(cache_path);indices=double(indices(:));
assert(isfolder(source_dir)&&~isempty(indices)&&all(isfinite(indices))&& ...
    all(indices>=1&indices==floor(indices))&&numel(unique(indices))==numel(indices), ...
    'prc:Indices','Expected a source directory and unique positive object IDs.');
[parent,~,ext]=fileparts(cache_path);assembled=strcmpi(ext,'.mat');
if assembled,cache_dir=[cache_path '.objects'];else,cache_dir=cache_path;end
if ~isfolder(cache_dir),mkdir(cache_dir);end
if assembled&&~isempty(parent)&&~isfolder(parent),mkdir(parent);end
schema='prc_encoder_static_dataset_v1';
key=struct('schema',schema,'legacy',cfg.legacy,'payload',cfg.payload,'sim',cfg.sim,'sensor',cfg.sensor);
config_hash=hash_bytes(unicode2native(jsonencode(key),'UTF-8'));
N=numel(indices);
provenance_template=struct('source_record','','source_sha256','','config_sha256',config_hash, ...
    'feature_schema',schema,'cache_hit',false,'record_run_id','','record_plan_signature','');
D=struct('schema',schema,'object_id',indices,'split',strings(N,1), ...
    'theta',nan(N,3),'state',nan(N,8,4,4),'g0',nan(N,8,4),'Y',nan(N,8,4,3), ...
    'tau_label',nan(N,8,4),'usable',false(N,1),'reasons',strings(N,1), ...
    'direction_delta_rad',nan(N,8,4),'direction_unknown',true(N,8,4), ...
    'initial_direction_no_motion',true(N,1),'provenance',repmat(provenance_template,N,1), ...
    'source_dir',source_dir,'config_hash',config_hash,'bounds',cfg.ident.bounds, ...
    'label_scope','theta is scoring/supervision metadata; tau_label exists only for train/validation, never test.', ...
    'observation_scope','t, measured q, issued q_command, observed stationarity; no truth.q/dq/tau.');
for i=1:N
    id=indices(i);file=fullfile(source_dir,'trials',sprintf('trial_%06d.mat',id));
    provenance=struct('source_record',file,'source_sha256','','config_sha256',config_hash, ...
        'feature_schema',schema,'cache_hit',false,'record_run_id','','record_plan_signature','');
    if ~isfile(file)
        D.reasons(i)="missing_source_record";D.provenance(i)=provenance;continue
    end
    provenance.source_sha256=hash_file(file);
    cache_file=fullfile(cache_dir,sprintf('object_%06d_%s_%s.mat',id,provenance.source_sha256,config_hash));
    if isfile(cache_file)
        saved=load(cache_file,'row');row=saved.row;provenance.cache_hit=true;
        assert(row.object_id==id&&strcmp(row.config_hash,config_hash)&&strcmp(row.source_hash,provenance.source_sha256), ...
            'prc:CacheMismatch','Cached object metadata mismatch.');
    else
        row=extract_row(file,id,cfg,config_hash,provenance.source_sha256);
        temporary=[tempname(cache_dir) '.mat'];
        save(temporary,'row','-v7.3');[ok,message]=movefile(temporary,cache_file);assert(ok,'prc:CacheSave','%s',message);
    end
    D.split(i)=row.split;D.theta(i,:)=row.theta;D.state(i,:,:,:)=reshape(row.observation.state,1,8,4,4);
    D.g0(i,:,:)=reshape(row.g0,1,8,4);D.Y(i,:,:,:)=reshape(row.Y,1,8,4,3);
    D.tau_label(i,:,:)=reshape(row.tau_label,1,8,4);D.usable(i)=row.usable;D.reasons(i)=strjoin(row.reasons,'; ');
    D.direction_delta_rad(i,:,:)=reshape(row.observation.direction_delta_rad,1,8,4);
    D.direction_unknown(i,:,:)=reshape(row.observation.direction_unknown,1,8,4);
    provenance.record_run_id=row.run_id;provenance.record_plan_signature=row.plan_signature;D.provenance(i)=provenance;
end
if assembled
    temporary_parent=parent;if isempty(temporary_parent),temporary_parent=pwd;end
    temporary=[tempname(temporary_parent) '.mat'];
    save(temporary,'D','-v7.3');[ok,message]=movefile(temporary,cache_path,'f');assert(ok,'prc:DatasetSave','%s',message);
end
end

function row=extract_row(file,id,cfg,config_hash,source_hash)
empty=prc_observation(struct(),cfg);
row=struct('object_id',id,'split',"unknown",'theta',nan(1,3),'observation',empty, ...
    'g0',nan(8,4),'Y',nan(8,4,3),'tau_label',nan(8,4),'usable',false, ...
    'reasons',{{}},'config_hash',config_hash,'source_hash',source_hash,'run_id','','plan_signature','');
try
    saved=load(file,'record');r=saved.record;
    assert(r.object_id==id&&r.trial_id==id,'prc:ObjectIdentity','Trial/object ID mismatch.');
    row.split=string(r.split);assert(isscalar(row.split)&&any(row.split==["train","validation","test"]),'prc:Split','Unknown split.');
    row.theta=double(r.theta_true(:).');assert(numel(row.theta)==3&&all(isfinite(row.theta)),'prc:Label','Invalid evaluation/supervision label.');
    if isfield(r,'run_id'),row.run_id=r.run_id;end
    if isfield(r,'plan_signature'),row.plan_signature=r.plan_signature;end
    % Pass obs only: no record labels or simulator-state arrays reach observer.
    row.observation=prc_observation(r.obs,cfg);row.reasons=row.observation.reasons;
    row.usable=row.observation.usable;
    if ~isempty(r.error),row.usable=false;row.reasons{end+1}='source_simulation_error';end
    q=row.observation.state(:,:,1);
    if all(isfinite(q),'all')
        [row.g0,row.Y]=bpil_static_design(cfg,q);
        if row.split~="test"
            phi=[row.theta(1),row.theta(1)*row.theta(2),row.theta(1)*row.theta(3)];
            row.tau_label=row.g0;
            for k=1:3,row.tau_label=row.tau_label+row.Y(:,:,k)*phi(k);end
        end
    end
catch err
    row.usable=false;row.reasons{end+1}=['record_extraction_error:' err.identifier];
end
end
function value=hash_file(file)
fid=fopen(file,'r');assert(fid>=0,'prc:SourceRead','Cannot read source record.');cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
value=hash_bytes(fread(fid,Inf,'*uint8'));
end
function value=hash_bytes(bytes)
md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');md.update(bytes);
value=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function [D,audit]=psx_generate_panel(runDir,cfg,pnnSpec,spec,panel,bundleHash)
%PSX_GENERATE_PANEL New independent objects, immutable observations/features.
assert(ismember(panel,{'original','independent'}));
locked=jsondecode(fileread(fullfile(runDir,'MODEL_LOCK.json')));
assert(strcmp(locked.bundle_sha256,bundleHash)&&~locked.selection_uses_test,'psx:ModelLock','Model lock must precede tests.');
probes=bpil_probe_library(cfg);probe=probes(pnnSpec.probe_index);
rs=RandStream('mt19937ar','Seed',spec.object_seed);
theta=pnnSpec.range_lower+rand(rs,spec.test_objects,3).*pnnSpec.range_span;
family=["nominal","mechanical","electrical","combined"];level=[0 1 1 1];
if strcmp(panel,'independent')
    family="combined";level=0;
    for severity=spec.severities(spec.severities>0)
        family=[family "mechanical" "electrical" "combined"];level=[level severity severity severity]; %#ok<AGROW>
    end
end
nc=numel(family);N=spec.test_objects*nc;folder=fullfile(runDir,[panel '_records']);if ~isfolder(folder),mkdir(folder);end
D=struct('schema','pnn_dataset_v1','X13',nan(N,13),'Xaug',nan(N,52),'base',nan(N,3),'physics8',nan(N,3), ...
    'theta',nan(N,3),'usable',false(N,1),'accepted',false(N,1),'physics8accepted',false(N,1), ...
    'physics8usable',false(N,1),'physical_success',false(N,1),'feature_usable',false(N,1), ...
    'object_id',zeros(N,1),'trial_id',(1:N).','split',repmat("test",N,1),'condition',strings(N,1));
templates=psv_conditions(cfg,probe);pixSpec=pix_config(cfg);rows=struct([]);started=tic;
inputIdentity=struct('cfg_hash',pnn_model_hash(cfg),'pnn_spec_hash',pnn_model_hash(pnnSpec), ...
    'probe_hash',pnn_model_hash(probe),'frozen_source_manifest_sha256',prc_file_hash(fullfile(runDir,'source_manifest.csv')));
panelOffset=0;if strcmp(panel,'independent'),panelOffset=100000;end
for i=1:N
    oi=ceil(i/nc);ci=mod(i-1,nc)+1;conditionName=family(ci);
    if strcmp(panel,'independent'),conditionName="independent_"+family(ci)+"_s"+string(level(ci));end
    seed=i+panelOffset;
    communication=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',spec.communication_seed_base+seed);
    if strcmp(panel,'independent'),condition=pix_condition(pixSpec,char(family(ci)),level(ci),spec.nuisance_seed_base+seed);
    else,condition=pnn_conditions(cfg,probe,family(ci),spec.nuisance_seed_base+seed,templates);end
    key=struct('schema','psx_record_v1','panel',panel,'trial_id',i,'object_id',spec.object_id_base+oi, ...
        'theta',theta(oi,:),'condition',condition,'communication',communication,'sensor_seed',spec.sensor_seed_base+seed, ...
        'model_bundle_sha256',bundleHash,'spec_hash',pnn_model_hash(spec),'pix_spec_hash',pnn_model_hash(pixSpec),'inputs',inputIdentity);
    file=fullfile(folder,sprintf('trial_%06d.mat',i));
    if pnn_checkpoint('exists',file)
        saved=pnn_checkpoint('read',file);record=saved.record;
        assert(isequaln(record.key,key),'psx:ResumeIdentity','Episode changed.');
    else
        record=struct('key',key,'obs',[],'truth',[],'features',[],'error',[],'completed_utc','');
        payload=struct('mass',theta(oi,1),'com',[theta(oi,2) 0 theta(oi,3)],'dimensions_m',cfg.payload.dimensions_m);
        try
            if strcmp(panel,'independent')
                [record.obs,record.truth]=pix_simulate_probe(cfg,payload,probe,condition,key.sensor_seed,communication,pixSpec);
            else
                [record.obs,record.truth]=psv_simulate_probe(cfg,payload,probe,condition,key.sensor_seed,communication);
            end
        catch err,record.error=struct('identifier',err.identifier,'message',err.message,'stack',err.stack);end
        record.features=pnn_features(cfg,record.obs,pnnSpec);
        record.completed_utc=pnn_utc();pnn_checkpoint('write',file,struct('record',record));
    end
    F=record.features;physical=isempty(record.error)&&isstruct(record.truth)&&isfield(record.truth,'physical_success')&&record.truth.physical_success;
    for field={'X13','Xaug','base','physics8'},D.(field{1})(i,:)=F.(field{1});end
    D.theta(i,:)=theta(oi,:);D.object_id(i)=key.object_id;D.condition(i)=conditionName;
    D.physical_success(i)=physical;D.feature_usable(i)=F.usable;D.usable(i)=physical&&F.usable;
    D.accepted(i)=physical&&F.accepted;D.physics8usable(i)=physical&&F.physics8usable;D.physics8accepted(i)=physical&&F.physics8accepted;
    reasons="";stationary=false;energy=NaN;completed=false;
    if ~isempty(record.truth)
        reasons=strjoin(string(record.truth.reasons),';');stationary=all(record.obs.stationary);
        completed=numel(record.obs.t)==round((cfg.sim.initial_hold_s+8*(cfg.sim.move_s+cfg.sim.hold_s))/.01);
        if isfield(record.truth,'energy'),energy=record.truth.energy.pass;end
    end
    if ~isempty(record.error),reasons=reasons+";"+string(record.error.identifier);end
    row=struct('trial_id',i,'object_id',key.object_id,'condition',conditionName,'physical_success',physical, ...
        'stationary',stationary,'complete_samples',completed,'feature_usable',F.usable,'energy_pass',energy,'reasons',reasons);
    if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
    prc_write_json(fullfile(runDir,['progress_' panel '.json']),struct('done',i,'total',N,'updated_utc',pnn_utc(),'elapsed_s',toc(started)));
    fprintf('%s trial %d/%d physical=%d stationary=%d features=%d\n',panel,i,N,physical,stationary,F.usable);
end
D.planned_n=N;D.failed_n=sum(~D.usable);
audit=struct('panel',panel,'smoke_only',spec.smoke_test,'planned_n',N,'independent_objects',spec.test_objects, ...
    'physical_success_n',sum(D.physical_success),'usable_n',sum(D.usable),'rows',rows, ...
    'scope','Physical-success field is simulation audit metadata, not a hardware-observable gate.');
writetable(struct2table(rows),fullfile(runDir,[panel '_simulation_audit.csv']));
end

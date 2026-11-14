function run_pbd_job(runDir,authorizeExploration,maxNewEpisodes)
% A finite exploratory parameter map; no training or automatic confirmation.
if nargin<2,authorizeExploration=false;end
if nargin<3,maxNewEpisodes=Inf;end
assert(isequal(authorizeExploration,true),'pbd:Authorization','Explicit exploratory authorization required.');
assert(isscalar(maxNewEpisodes)&&maxNewEpisodes>=1&&(isinf(maxNewEpisodes)||fix(maxNewEpisodes)==maxNewEpisodes));
snapshot=fileparts(mfilename('fullpath'));assert(strcmpi(snapshot,fullfile(runDir,'source_snapshot')));
reset_path(snapshot);maxNumCompThreads(1); %#ok<MAXNCT>
fh=java.io.RandomAccessFile(fullfile(runDir,'job.lock'),'rw');ch=fh.getChannel();lk=ch.tryLock();
assert(~isempty(lk),'pbd:Busy','Another runner owns this study.');cleanup=onCleanup(@()release(lk,ch,fh)); %#ok<NASGU>
diary(fullfile(runDir,'job.log'));dc=onCleanup(@()diary('off')); %#ok<NASGU>
phase='integrity';newEpisodes=0;
try
    L=jsondecode(fileread(fullfile(runDir,'PREPARED_LOCK.json')));
    checks={'source_manifest.csv','inputs.mat','model_bundle.mat','FROZEN_PROTOCOL.txt'};
    expected={L.source_manifest_sha256,L.inputs_sha256,L.model_sha256,L.protocol_sha256};
    for j=1:numel(checks),assert(strcmp(prc_file_hash(fullfile(runDir,checks{j})),expected{j}),'pbd:Identity','Changed frozen input.');end
    T=readtable(fullfile(runDir,'source_manifest.csv'),'Delimiter',',','TextType','string');
    for j=1:height(T),assert(strcmp(prc_file_hash(fullfile(snapshot,T.relative_path(j))),T.sha256(j)),'pbd:Source','Changed source.');end
    I=pnn_checkpoint('read',fullfile(runDir,'inputs.mat'));B=pnn_checkpoint('read',fullfile(runDir,'model_bundle.mat'));bundle=B.bundle;
    spec=I.spec;cfg=I.cfg;pnnSpec=I.pnnSpec;S=I.pixSpec;probe=I.probe;
    assert(spec.exploratory_only&&~spec.future_confirmation_authorized);
    if isfile(fullfile(runDir,'COMPLETE.json'))
        finish=jsondecode(fileread(fullfile(runDir,'COMPLETE.json')));
        for j=1:numel(finish.outputs)
            assert(strcmp(prc_file_hash(finish.outputs(j).path),finish.outputs(j).sha256));
            if endsWith(finish.outputs(j).path,'SNAPSHOT_COMPLETE.json')
                ss=jsondecode(fileread(finish.outputs(j).path));
                for h=1:numel(ss.outputs),assert(strcmp(prc_file_hash(ss.outputs(h).path),ss.outputs(h).sha256));end
            end
        end
        publish('complete','complete','Existing exploratory completion verified.');return
    end
    nc=numel(I.cells);N=height(I.objects)*nc;D=empty_data(N);rows=struct([]);
    folder=fullfile(runDir,'records');if ~isfolder(folder),mkdir(folder);end
    options=struct('smoke_test',false,'bootstrap_replicates',spec.bootstrap_replicates, ...
        'bootstrap_seed',spec.bootstrap_seed,'bounds',pnnSpec.bounds, ...
        'pairs',{{spec.primary_method,'ridge13';spec.primary_method,'ridgeAug';spec.primary_method,'interactionRidge'; ...
        spec.primary_method,'affine_fixed';spec.primary_method,'affine_selected'; ...
        'nonlinear_fixed','affine_fixed';'nonlinear_selected','affine_selected'}});
    phase='exploratory_generation';publish('running',phase,'Fixed exploratory grid; models and comparison methods remain frozen.');
    for i=1:N
        if isfile(fullfile(runDir,'PAUSE_REQUEST.json'))
            prc_write_json(fullfile(runDir,'PAUSED.json'),struct('state','paused','reason','Requested boundary pause', ...
                'committed_episodes',i-1,'next_trial',i,'paused_utc',pnn_utc()));
            publish('paused','paused','Cooperative pause at an episode boundary.');return
        end
        oi=ceil(i/nc);ci=mod(i-1,nc)+1;cellSpec=I.cells(ci);
        theta=[I.objects.mass_kg(oi),I.objects.cx_m(oi),I.objects.cz_m(oi)];
        family=cellSpec.family;if strcmp(family,'baseline'),family='combined';end
        condition=pix_condition(S,family,cellSpec.severity,spec.nuisance_seed_base+oi);
        communication=struct('command_delay_s',[.010 .015],'encoder_delay_s',[.010 .015],'seed',spec.communication_seed_base+oi);
        key=struct('schema','pbd_record_v1','run_id',spec.run_id,'trial_id',i,'object_id',I.objects.object_id(oi), ...
            'cell_id',ci,'family',cellSpec.family,'severity',cellSpec.severity,'theta',theta,'condition',condition, ...
            'communication',communication,'sensor_seed',spec.sensor_seed_base+oi,'spec_hash',pnn_model_hash(spec), ...
            'inputs_sha256',L.inputs_sha256,'source_manifest_sha256',L.source_manifest_sha256,'model_sha256',L.model_sha256);
        file=fullfile(folder,sprintf('trial_%06d.mat',i));
        if pnn_checkpoint('exists',file)
            saved=pnn_checkpoint('read',file);record=saved.record;assert(isequaln(record.key,key),'pbd:ResumeIdentity','Record identity changed.');
        else
            record=struct('key',key,'obs',[],'truth',[],'features',[],'error',[],'diagnostics',[],'wall_s',NaN,'completed_utc','');
            payload=struct('mass',theta(1),'com',[theta(2) 0 theta(3)],'dimensions_m',cfg.payload.dimensions_m);
            timer=tic;
            try,[record.obs,record.truth]=pix_simulate_probe(cfg,payload,probe,condition,key.sensor_seed,communication,S);
            catch err,record.error=struct('identifier',err.identifier,'message',err.message,'stack',err.stack);end
            record.features=pnn_features(cfg,record.obs,pnnSpec);record.wall_s=toc(timer);
            record.diagnostics=pbd_row_diagnostics(record,cfg,pnnSpec,bundle,probe);record.completed_utc=pnn_utc();
            pnn_checkpoint('write',file,struct('record',record));newEpisodes=newEpisodes+1;
        end
        F=record.features;r=record.diagnostics;physical=r.physical_success;
        for f={'X13','Xaug','base','physics8'},D.(f{1})(i,:)=F.(f{1});end
        D.theta(i,:)=theta;D.object_id(i)=key.object_id;D.trial_id(i)=i;D.condition(i)=string(cellSpec.condition);
        D.physical_success(i)=physical;D.feature_usable(i)=F.usable;D.usable(i)=physical&&F.usable;
        D.accepted(i)=physical&&F.accepted;D.physics8usable(i)=physical&&F.physics8usable;D.physics8accepted(i)=physical&&F.physics8accepted;
        if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        progress=struct('done',i,'total',N,'complete_objects',floor(i/nc),'total_objects',height(I.objects), ...
            'current_family',cellSpec.family,'current_severity',cellSpec.severity,'updated_utc',pnn_utc(), ...
            'new_episodes_this_attempt',newEpisodes,'last_generation_wall_s',record.wall_s,'exploratory_only',true);
        prc_write_json(fullfile(runDir,'progress.json'),progress);
        fprintf('trial %d/%d object=%d condition=%s physical=%d features=%d energy=%d\n',i,N,oi,cellSpec.condition,physical,F.usable,r.energy_pass);
        if mod(i,nc)==0
            phase='exploratory_snapshot';publish('running',phase,sprintf('Analyzing %d complete exploratory objects.',oi));
            partial=slice_data(D,i);pbd_analyze(runDir,partial,bundle,rows,options);
            phase='exploratory_generation';publish('running',phase,'Continuing the fixed grid; no outcome-based early stopping.');
        end
        if newEpisodes>=maxNewEpisodes&&i<N
            prc_write_json(fullfile(runDir,'ENGINEERING_CHECKPOINT.json'),struct('completed_utc',pnn_utc(), ...
                'committed_episodes',i,'new_episodes',newEpisodes,'physical_success',all([rows.physical_success]), ...
                'energy_pass',all([rows.energy_pass]),'stationary',all([rows.stationary]),'features_usable',all([rows.feature_usable]), ...
                'meaning','Execution check only; no model performance requirement.'));
            publish('paused','engineering_checkpoint','Bounded execution check complete; manual continuation required.');return
        end
    end
    files={fullfile(runDir,'inputs.mat'),fullfile(runDir,'model_bundle.mat'),fullfile(runDir,'progress.json')};
    for j=1:N
        f=fullfile(folder,sprintf('trial_%06d.mat',j));pnn_checkpoint('read',f);
        files=[files {f,[f '.sha256.json']}]; %#ok<AGROW>
    end
    for j=1:height(I.objects)
        files{end+1}=fullfile(runDir,'snapshots',sprintf('snapshot_%03d',j),'SNAPSHOT_COMPLETE.json'); %#ok<AGROW>
    end
    outputs=struct('path',{},'sha256',{});
    for j=1:numel(files),outputs(j)=struct('path',files{j},'sha256',prc_file_hash(files{j}));end
    prc_write_json(fullfile(runDir,'COMPLETE.json'),struct('schema','pbd_complete_v1','completed_utc',pnn_utc(), ...
        'exploratory_only',true,'planned_episodes',N,'independent_objects',height(I.objects), ...
        'physical_success_n',sum([rows.physical_success]),'feature_usable_n',sum([rows.feature_usable]), ...
        'automatic_confirmation',false,'outputs',outputs,'scope','Development exploration only; fresh confirmation remains separate and unstarted.'));
    publish('complete','complete','Bounded exploratory map complete. No confirmation run started.');
catch err
    failures=fullfile(runDir,'failures');if ~isfolder(failures),mkdir(failures);end
    f=struct('phase',phase,'identifier',err.identifier,'message',err.message,'stack',err.stack,'failed_utc',pnn_utc());
    prc_write_json(fullfile(failures,[char(java.util.UUID.randomUUID()) '.json']),f);
    prc_write_json(fullfile(runDir,'FAILED.json'),f);publish('failed',phase,err.message);rethrow(err)
end
    function publish(state,p,message)
        prc_write_json(fullfile(runDir,'status.json'),struct('state',state,'phase',p,'message',message, ...
            'matlab_pid',feature('getpid'),'updated_utc',pnn_utc(),'exploratory_only',true));
    end
end
function D=empty_data(N)
D=struct('schema','pnn_dataset_v1','X13',nan(N,13),'Xaug',nan(N,52),'base',nan(N,3),'physics8',nan(N,3), ...
    'theta',nan(N,3),'usable',false(N,1),'accepted',false(N,1),'physics8accepted',false(N,1), ...
    'physics8usable',false(N,1),'physical_success',false(N,1),'feature_usable',false(N,1), ...
    'object_id',zeros(N,1),'trial_id',zeros(N,1),'split',repmat("test",N,1),'condition',strings(N,1));
end
function Q=slice_data(D,n)
Q=D;names=fieldnames(Q);
for k=1:numel(names),name=names{k};if strcmp(name,'schema'),continue;end;value=D.(name);Q.(name)=value(1:n,:);end
Q.planned_n=n;Q.failed_n=sum(~Q.usable);
end
function reset_path(snapshot)
restoredefaultpath;addpath(snapshot,fullfile(snapshot,'src'),fullfile(snapshot,'vendor','bdcl_v29'));
end
function release(l,c,f)
try,l.release();catch,end;try,c.close();catch,end;try,f.close();catch,end
end

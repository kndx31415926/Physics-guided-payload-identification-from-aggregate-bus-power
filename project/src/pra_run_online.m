function info=pra_run_online(run_dir,cfg,spec)
% All unknown evaluation labels stay in this scorer, outside learning state.
assert(isfile(fullfile(run_dir,'DATA_COMPLETE.json')),'pra:Data','Generate all records first.');
plan=load(fullfile(run_dir,'data_plan.mat'));M=plan.manifest;
verify_data_manifest(run_dir,M);
initial=pra_online_init(cfg,spec);eta0=struct('coefficients',cfg.legacy.power.coefficients);
bundle_hash=prc_file_hash(fullfile(spec.source_dir,'model_bundle.mat'));
outdir=fullfile(run_dir,'online');if ~isfolder(outdir),mkdir(outdir);end
allrows=struct([]);allretention=struct([]);audit=struct([]);total=numel(spec.scenarios)*numel(spec.stream_seeds)*spec.blocks;done=0;
for c=1:numel(spec.scenarios)
    scenario=char(spec.scenarios{c});
    for seed=spec.stream_seeds
        identity=struct('run_id',spec.run_id,'plan_signature',plan.plan_signature, ...
            'scenario',scenario,'stream_seed',seed,'source_bundle_sha256',bundle_hash,'spec',spec);
        checkpoint=fullfile(outdir,sprintf('%s_%d.mat',scenario,seed));
        if isfile(checkpoint)
            saved=load(checkpoint);assert(isfield(saved,'identity')&&isequaln(saved.identity,identity),'pra:CheckpointIdentity','Online checkpoint identity mismatch.');
            state=saved.state;eta=saved.eta;completed=saved.completed;rows=saved.rows;events=saved.events;
            assert(isscalar(completed)&&completed==floor(completed)&&completed>=0&&completed<=spec.blocks&& ...
                numel(events)==completed&&state.block_count==completed&&numel(state.processed_keys)==completed,'pra:CheckpointCount','Invalid block checkpoint.');
            assert(numel(rows)==completed*spec.eval_per_block*14,'pra:CheckpointCount','Invalid prediction count.');
            for k=1:completed
                expected_key=sprintf('%s_seed%d_block%d',scenario,seed,k);
                assert(strcmp(events(k).block_key,expected_key)&&strcmp(state.processed_keys{k},expected_key),'pra:CheckpointOrder','Checkpoint stream ordering mismatch.');
            end
        else,state=initial;eta=eta0;completed=0;rows=struct([]);events=struct([]);
        end
        done=done+completed;
        for block=completed+1:spec.blocks
            select=string(M.scenario)==string(scenario)&M.stream_seed==seed&M.block==block;
            blockM=M(select,:);assert(height(blockM)==spec.eval_per_block+1+size(spec.reference_train_theta,1)+size(spec.reference_validation_theta,1));
            ev=blockM(string(blockM.role)=="eval",:);pre=struct([]);started=tic;
            for i=1:height(ev)
                r=record(ev.trial_id(i));assert(strcmp(r.role,'eval')&&isempty(r.known_theta),'pra:Role','Evaluation payload is not a training reference.');
                prediction=pra_online_predict(state,r.obs,eta,'all');
                pre=append_predictions(pre,prediction.methods,r,scenario,seed,block,'drift',block-1);
            end
            % Commit predictions before calibration/update. Never score this
            % block again with the subsequently trained model.
            prefile=fullfile(outdir,sprintf('pre_%s_%d_%02d.mat',scenario,seed,block));
            if isfile(prefile)
                previous=load(prefile);assert(isfield(previous,'identity')&&isequaln(previous.identity,identity),'pra:CheckpointIdentity','Pre-update checkpoint identity mismatch.');
                assert(isequaln(previous.pre,pre),'pra:ResumePrediction','Pre-update prediction changed on resume.');
            else
                pgar_model_atomic_save(prefile,struct('identity',identity,'pre',pre,'prediction_saved_utc',utc(),'update_not_started',true));
            end
            rows=[rows pre]; %#ok<AGROW>
            ar=blockM(string(blockM.role)=="anchor",:);assert(height(ar)==1);r=record(ar.trial_id);
            calibration=struct('accepted',false,'reasons',{{'unusable_anchor'}});candidate=eta;
            if isstruct(r.obs)&&all(isfield(r.obs,{'plateau_q','plateau_P','plateau_sd_P','stationary'}))
                anchor=r.obs;anchor.is_anchor=true;anchor.known_mass_kg=0;
                [candidate,calibration]=bpil_calibrate_anchor(cfg,anchor,eta);
            end
            if calibration.accepted,eta=candidate;end
            train_refs=references(blockM,"reference_train");validation_refs=references(blockM,"reference_validation");
            key=sprintf('%s_seed%d_block%d',scenario,seed,block);
            [state,update]=pra_online_update(state,train_refs,validation_refs,eta,key);
            event=struct('scenario',scenario,'stream_seed',seed,'block',block,'block_key',key, ...
                'calibration',calibration,'update',update,'eta',eta,'elapsed_s',toc(started), ...
                'preupdate_prediction_file',prefile,'phase_order','unknown evaluation -> empty calibration -> independent reference training -> next block');
            events=append(events,event);completed=block;
            pgar_model_atomic_save(checkpoint,struct('identity',identity,'state',state,'eta',eta,'completed',completed,'rows',rows,'events',events));
            done=done+1;progress('stream_blocks',done,total,scenario,seed,block);
            fprintf('PRA %s seed%d block%d/%d calibration=%d, %.1fs\n',scenario,seed,block,spec.blocks,calibration.accepted,toc(started));
        end
        allrows=[allrows rows];audit=[audit events]; %#ok<AGROW>
        retentionfile=fullfile(outdir,sprintf('retention_%s_%d.mat',scenario,seed));
        if isfile(retentionfile)
            saved=load(retentionfile);assert(isfield(saved,'identity')&&isequaln(saved.identity,identity),'pra:CheckpointIdentity','Retention checkpoint identity mismatch.');
            retention=saved.retention;
            assert(numel(retention)==numel(spec.retention_ids)*14,'pra:CheckpointCount','Invalid retention count.');
        else
            retention=struct([]);
            for id=spec.retention_ids(:).'
                p=fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',id));s=load(p,'record');r=s.record;
                assert(strcmp(r.split,'test'),'pra:Retention','Retention objects must be held out.');
                prediction=pra_online_predict(state,r.obs,eta0,'all');
                retention=append_predictions(retention,prediction.methods,r,scenario,seed,spec.blocks,'nominal_retention',spec.blocks);
            end
            pgar_model_atomic_save(retentionfile,struct('identity',identity,'retention',retention,'scope','Counterfactual cached nominal input; not simulated mechanical recovery.'));
        end
        allretention=[allretention retention]; %#ok<AGROW>
    end
end
R=struct2table(allrows);writetable(R,fullfile(run_dir,'online_predictions.csv'));
if ~isempty(allretention),writetable(struct2table(allretention),fullfile(run_dir,'retention_predictions.csv'));end
pgar_model_atomic_save(fullfile(run_dir,'online_audit.mat'),struct('events',audit,'spec',spec));
info=pra_summarize_online(run_dir,spec);progress('complete',total,total,'',0,0);
    function r=record(id)
        f=fullfile(run_dir,'trials',sprintf('trial_%06d.mat',id));s=load(f,'record');r=s.record;
        assert(r.trial_id==id&&strcmp(r.plan_signature,plan.plan_signature),'pra:Identity','Data plan mismatch.');
    end
    function refs=references(B,role)
        Q=B(string(B.role)==role,:);refs=struct([]);
        for j=1:height(Q)
            r=record(Q.trial_id(j));assert(strcmp(r.role,role)&&numel(r.known_theta)==3,'pra:Reference','Explicit known reference required.');
            f=fullfile(run_dir,'trials',sprintf('trial_%06d.mat',r.trial_id));
            one=struct('obs',r.obs,'known_theta',r.known_theta,'is_reference',true,'role',char(role), ...
                'record_key',sprintf('%s/trial_%06d',spec.run_id,r.trial_id),'record_hash',prc_file_hash(f));
            refs=append(refs,one);
        end
    end
    function progress(stage,n,total,sc,seed,b)
        prc_write_json(fullfile(run_dir,'progress_online.json'),struct('stage',stage,'blocks_done',n,'blocks_total',total, ...
            'scenario',sc,'stream_seed',seed,'block',b,'updated_utc',utc()));
    end
end
function verify_data_manifest(run_dir,M)
file=fullfile(run_dir,'online_data_manifest.csv');N=height(M);
trial_id=M.trial_id;sha256=cell(N,1);
for i=1:N,sha256{i}=prc_file_hash(fullfile(run_dir,'trials',sprintf('trial_%06d.mat',trial_id(i))));end
if isfile(file)
    A=readtable(file,'Delimiter',',','ReadVariableNames',true,'NumHeaderLines',0,'TextType','string');
    assert(isequal(A.trial_id,trial_id)&&isequal(string(A.sha256),string(sha256)),'pra:ChangedData','A raw data record changed since online scoring started.');
else
    temp=fullfile(run_dir,['t_' char(javaMethod('randomUUID','java.util.UUID')) '.csv']);
    writetable(table(trial_id,sha256),temp);[ok,message]=movefile(temp,file);assert(ok,'pra:Manifest','%s',message);
end
end
function rows=append_predictions(rows,methods,r,scenario,seed,block,domain,updates_before)
T=double(r.theta_true(:).');physical=false;
if isstruct(r.truth)&&isfield(r.truth,'physical_success'),physical=logical(r.truth.physical_success);end
for m=1:numel(methods)
    M=methods(m);
    for post=1:2
        if post==1,p=M.raw;label='raw';else,p=M.clipped;label='common_clip';end
        finite=all(isfinite(p));accepted=finite&&M.accepted&&physical;
        one=struct('scenario',scenario,'stream_seed',seed,'block',block,'domain',domain, ...
            'method',M.name,'postprocessing',label,'trial_id',r.trial_id,'object_id',r.object_id, ...
            'mass_true_kg',T(1),'cx_true_m',T(2),'cz_true_m',T(3), ...
            'mass_est_kg',p(1),'cx_est_m',p(2),'cz_est_m',p(3), ...
            'finite_prediction',finite,'accepted',accepted,'physical_success',physical, ...
            'bounds_hit',M.bounds_hit,'updates_possible_before_prediction',updates_before, ...
            'evaluated_before_current_update',true,'reasons',strjoin(string(M.reasons),';'));
        rows=append(rows,one);
    end
end
end
function A=append(A,row)
if isempty(A),A=row;else,A(end+1)=row;end
end
function t=utc()
t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
end

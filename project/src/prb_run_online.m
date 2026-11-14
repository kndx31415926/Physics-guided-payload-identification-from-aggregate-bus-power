function info=prb_run_online(run_dir,cfg,spec)
% Development replay scorer. Only this layer reads unknown payload truth.
assert(spec.development_fixture,'prb:Role','Previously inspected data are development only.');
P=load(fullfile(spec.data_source_dir,'data_plan.mat'),'manifest','plan_signature');M=P.manifest;
initial=prb_online_init(cfg,spec);outdir=fullfile(run_dir,'online');if ~isfolder(outdir),mkdir(outdir);end
rows=struct([]);retention_rows=struct([]);events=struct([]);done=0;
total=numel(spec.scenarios)*numel(spec.stream_seeds)*spec.blocks;
for c=1:numel(spec.scenarios)
    scenario=char(spec.scenarios{c});
    for seed=spec.stream_seeds
        identity=struct('run_id',spec.run_id,'source_plan_signature',P.plan_signature, ...
            'scenario',scenario,'stream_seed',seed,'spec',spec);
        checkpoint=fullfile(outdir,sprintf('%s_%d.mat',scenario,seed));
        if isfile(checkpoint)
            S=load(checkpoint);assert(isequaln(S.identity,identity),'prb:CheckpointIdentity','Changed replay identity.');
            state=S.state;completed=S.completed;stream_rows=S.stream_rows;stream_events=S.stream_events;
            assert(completed>=0&&completed<=spec.blocks&&completed==fix(completed)&&state.block_count==completed&& ...
                numel(stream_events)==completed&&numel(stream_rows)==completed*spec.eval_per_block*8,'prb:CheckpointCount','Invalid checkpoint.');
            for b=1:completed
                assert(strcmp(state.processed_keys{b},sprintf('%s_seed%d_block%d',scenario,seed,b)),'prb:CheckpointOrder','Checkpoint ordering changed.');
            end
        else,state=initial;completed=0;stream_rows=struct([]);stream_events=struct([]);
        end
        done=done+completed;
        for block=completed+1:spec.blocks
            B=M(string(M.scenario)==string(scenario)&M.stream_seed==seed&M.block==block,:);
            assert(height(B)==spec.eval_per_block+1+spec.expected_train_references+spec.expected_validation_references,'prb:Plan','Incomplete block.');
            E=B(string(B.role)=="eval",:);pre=struct([]);timer=tic;
            for j=1:height(E)
                r=read_record(E.trial_id(j));assert(strcmp(r.role,'eval')&&isempty(r.known_theta),'prb:Role','Unknown evaluation expected.');
                prediction=prb_online_predict(state,r.obs);
                pre=append_predictions(pre,prediction.methods,r,scenario,seed,block,'drift',block-1);
            end
            prefile=fullfile(outdir,sprintf('pre_%s_%d_%02d.mat',scenario,seed,block));
            if isfile(prefile)
                S=load(prefile);assert(isequaln(S.identity,identity)&&isequaln(S.pre,pre),'prb:ResumePrediction','Pre-update predictions changed on resume.');
            else
                pgar_model_atomic_save(prefile,struct('identity',identity,'pre',pre,'update_not_started',true,'saved_utc',utc()));
            end
            A=B(string(B.role)=="anchor",:);assert(height(A)==1);r=read_record(A.trial_id);
            assert(strcmp(r.role,'anchor')&&numel(r.known_theta)==3&&all(isfinite(r.known_theta))&& ...
                r.known_theta(1)==0,'prb:Anchor','Explicit known empty anchor required.');
            anchor=r.obs;anchor.is_anchor=true;anchor.known_mass_kg=0;
            tr=references(B,"reference_train");va=references(B,"reference_validation");
            key=sprintf('%s_seed%d_block%d',scenario,seed,block);
            [state,update]=prb_online_update(state,anchor,tr,va,key);
            assert(~update.unknown_truth_used,'prb:Leakage','Unknown truth entered update.');
            event=struct('scenario',string(scenario),'stream_seed',seed,'block',block,'block_key',key, ...
                'update',update,'elapsed_s',toc(timer),'preupdate_prediction_file',prefile);
            stream_rows=[stream_rows pre];stream_events=append(stream_events,event);completed=block; %#ok<AGROW>
            pgar_model_atomic_save(checkpoint,struct('identity',identity,'state',state,'completed',completed, ...
                'stream_rows',stream_rows,'stream_events',stream_events));
            done=done+1;progress('stream_blocks',scenario,seed,block);
            fprintf('PRB %s seed%d block%d/%d %.1fs; next unknown block uses accepted whole system.\n',scenario,seed,block,spec.blocks,toc(timer));
        end
        rows=[rows stream_rows];events=[events stream_events]; %#ok<AGROW>
        % A diagnostic of network retention at the ORIGINAL calibration. It
        % does not claim that a worn robot physically returned to nominal.
        retfile=fullfile(outdir,sprintf('retention_%s_%d.mat',scenario,seed));
        if isfile(retfile)
            S=load(retfile);assert(isequaln(S.identity,identity),'prb:CheckpointIdentity','Retention identity changed.');ret=S.ret;
            assert(numel(ret)==numel(spec.retention_ids)*8,'prb:CheckpointCount','Retention count changed.');
        else
            rs=state;for f=fieldnames(rs.systems).',rs.systems.(f{1}).eta=rs.eta0;end
            ret=struct([]);
            for id=spec.retention_ids(:).'
                D=load(fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',id)),'record');r=D.record;
                assert(strcmp(r.split,'test'),'prb:Retention','Nominal held-out diagnostic expected.');
                prediction=prb_online_predict(rs,r.obs);
                ret=append_predictions(ret,prediction.methods,r,scenario,seed,spec.blocks,'nominal_network_retention',spec.blocks);
            end
            pgar_model_atomic_save(retfile,struct('identity',identity,'ret',ret,'scope','Cached nominal inputs with eta0; W-only retention diagnostic, never used by update.'));
        end
        retention_rows=[retention_rows ret]; %#ok<AGROW>
    end
end
R=struct2table(rows);old=readtable(fullfile(spec.data_source_dir,'online_predictions.csv'),'TextType','string');
old=old(ismember(old.scenario,string(spec.scenarios))&ismember(old.stream_seed,spec.stream_seeds)&old.block<=spec.blocks,:);
old=normalize_bools(old);verify_frozen(R,old);
legacy=old(old.method=="full",:);legacy.method(:)="legacy_full";
assert(isequal(legacy.Properties.VariableNames,R.Properties.VariableNames),'prb:ArchiveSchema','Prior score schema mismatch.');
R=[R;legacy];writetable(R,fullfile(run_dir,'online_predictions.csv'));
writetable(struct2table(retention_rows),fullfile(run_dir,'retention_predictions.csv'));
pgar_model_atomic_save(fullfile(run_dir,'online_audit.mat'),struct('events',events,'spec',spec));
info=prb_summarize_online(run_dir,spec);progress('complete','',0,0);
    function r=read_record(id)
        D=load(fullfile(spec.data_source_dir,'trials',sprintf('trial_%06d.mat',id)),'record');r=D.record;
        assert(r.trial_id==id&&strcmp(r.plan_signature,P.plan_signature),'prb:RecordIdentity','Source record differs from source plan.');
    end
    function refs=references(B,role)
        Q=B(string(B.role)==role,:);refs=struct([]);
        for k=1:height(Q)
            r=read_record(Q.trial_id(k));assert(strcmp(r.role,role)&&numel(r.known_theta)==3,'prb:Role','Known reference expected.');
            p=fullfile(spec.data_source_dir,'trials',sprintf('trial_%06d.mat',r.trial_id));
            one=struct('obs',r.obs,'known_theta',r.known_theta,'is_reference',true,'role',char(role), ...
                'record_key',sprintf('%s/trial_%06d',spec.data_source_dir,r.trial_id),'record_hash',prc_file_hash(p));
            refs=append(refs,one);
        end
    end
    function progress(stage,sc,seed,b)
        prc_write_json(fullfile(run_dir,'progress_online.json'),struct('stage',stage,'blocks_done',done,'blocks_total',total, ...
            'scenario',sc,'stream_seed',seed,'block',b,'updated_utc',utc(),'development_fixture',true));
    end
end
function rows=append_predictions(rows,methods,r,scenario,seed,block,domain,updates_before)
t=double(r.theta_true(:).');physical=isstruct(r.truth)&&isfield(r.truth,'physical_success')&&logical(r.truth.physical_success);
for k=1:numel(methods)
    m=methods(k);
    for post=1:2
        if post==1,p=m.raw;label="raw";else,p=m.clipped;label="common_clip";end
        finite=all(isfinite(p));
        one=struct('scenario',string(scenario),'stream_seed',seed,'block',block,'domain',string(domain), ...
            'method',string(m.name),'postprocessing',label,'trial_id',r.trial_id,'object_id',r.object_id, ...
            'mass_true_kg',t(1),'cx_true_m',t(2),'cz_true_m',t(3), ...
            'mass_est_kg',p(1),'cx_est_m',p(2),'cz_est_m',p(3), ...
            'finite_prediction',finite,'accepted',finite&&m.accepted&&physical,'physical_success',physical, ...
            'bounds_hit',m.bounds_hit,'updates_possible_before_prediction',updates_before, ...
            'evaluated_before_current_update',true,'reasons',strjoin(string(m.reasons),';'));
        rows=append(rows,one);
    end
end
end
function R=normalize_bools(R)
for f={'finite_prediction','accepted','physical_success','bounds_hit','evaluated_before_current_update'}
    x=R.(f{1});if isstring(x)||iscellstr(x),x=ismember(lower(string(x)),["true","1"]);end;R.(f{1})=logical(x);
end
end
function verify_frozen(R,O)
keys={'scenario','stream_seed','trial_id','postprocessing'};
A=sortrows(R(R.method=="frozen",:),keys);B=sortrows(O(O.method=="frozen",:),keys);
assert(isequal(A(:,keys),B(:,keys)),'prb:ArchivePairing','Archived objects differ.');
x=[A.mass_est_kg A.cx_est_m A.cz_est_m];y=[B.mass_est_kg B.cx_est_m B.cz_est_m];
assert(isequal(isfinite(x),isfinite(y))&&all(abs(x(isfinite(x))-y(isfinite(y)))<1e-10),'prb:FrozenChanged','Frozen predictor changed relative to archived source.');
assert(isequal(A.accepted,B.accepted),'prb:FrozenChanged','Frozen acceptance changed.');
end
function A=append(A,row),if isempty(A),A=row;else,A(end+1)=row;end,end
function t=utc(),t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));end

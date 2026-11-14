function info=pcr_run_online(run_dir,cfg,spec)
% Only this scoring layer reads unknown labels; update receives known refs.
data_root=spec.data_source_dir;
assert(isfile(fullfile(data_root,'DATA_COMPLETE.json')),'pcu:Data','Complete data required.');
P=load(fullfile(data_root,'data_plan.mat'),'manifest','plan_signature');M=P.manifest;
initial=pcr_online_init(cfg,spec);V=pcr_variants();method_count=sum(cellfun(@numel,{V.systems}));
outdir=fullfile(run_dir,'online');if ~isfolder(outdir),mkdir(outdir);end
rows=struct([]);retention_rows=struct([]);events=struct([]);costs=struct([]);done=0;
total=numel(spec.scenarios)*numel(spec.stream_seeds)*spec.blocks;
for c=1:numel(spec.scenarios)
    scenario=char(spec.scenarios{c});
    for seed=spec.stream_seeds
        identity=struct('run_id',spec.run_id,'plan_signature',P.plan_signature,'scenario',scenario,'stream_seed',seed,'spec',spec,'variants',V);
        checkpoint=fullfile(outdir,sprintf('%s_%d.mat',scenario,seed));
        if isfile(checkpoint)
            S=load(checkpoint);assert(isequaln(S.identity,identity),'pcu:Identity','Checkpoint identity changed.');
            states=S.states;completed=S.completed;stream_rows=S.stream_rows;stream_events=S.stream_events;stream_costs=S.stream_costs;
            assert(numel(stream_rows)==completed*spec.eval_per_block*method_count*2,'pcu:Count','Checkpoint prediction count differs.');
            for v=1:numel(V)
                assert(states{v}.block_count==numel(1:V(v).interval:completed),'pcu:Count','Update count differs from locked schedule.');
            end
        else
            states=cell(1,numel(V));
            for v=1:numel(V)
                states{v}=initial;states{v}.spec.pcu_keep_history=V(v).keep_history;states{v}.spec.pcu_use_offline=V(v).use_offline;
            end
            completed=0;stream_rows=struct([]);stream_events=struct([]);stream_costs=struct([]);
        end
        done=done+completed;
        for block=completed+1:spec.blocks
            B=M(string(M.scenario)==string(scenario)&M.stream_seed==seed&M.block==block,:);
            assert(height(B)==spec.eval_per_block+7,'pcu:Plan','Incomplete block.');
            E=B(string(B.role)=="eval",:);pre=struct([]);timer=tic;
            for j=1:height(E)
                r=record(E.trial_id(j));assert(strcmp(r.role,'eval')&&isempty(r.known_theta),'pcu:Role','Unknown object required.');
                for v=1:numel(V)
                    pred=pcr_predict(states{v},r.obs);selected=select(pred.methods,V(v));
                    pre=score(pre,selected,r,scenario,seed,block,'drift',states{v}.block_count);
                end
            end
            prefile=fullfile(outdir,sprintf('pre_%s_%d_%02d.mat',scenario,seed,block));
            if isfile(prefile)
                S=load(prefile);assert(isequaln(S.identity,identity)&&isequaln(S.pre,pre),'pcu:ResumePrediction','Prediction changed before update.');
            else,pgar_model_atomic_save(prefile,struct('identity',identity,'pre',pre,'update_not_started',true));end
            A=B(string(B.role)=="anchor",:);ar=record(A.trial_id);assert(strcmp(ar.role,'anchor')&&ar.known_theta(1)==0,'pcu:Anchor','Known empty required.');
            anchor=ar.obs;if ~isstruct(anchor),anchor=struct();end;anchor.is_anchor=true;anchor.known_mass_kg=0;
            tr=references(B,"reference_train");va=references(B,"reference_validation");
            for v=1:numel(V)
                open=pcu_schedule(block,V(v).interval);
                if open
                    states{v}.spec.pcu_chronological_block=block;
                    key=sprintf('%s_seed%d_block%d',scenario,seed,block);
                    [states{v},update]=pcr_online_update(states{v},anchor,tr,va,key);
                    assert(~update.unknown_truth_used,'pcu:Leakage','Unknown truth in update.');
                    event=struct('scenario',string(scenario),'stream_seed',seed,'block',block,'variant',string(V(v).name), ...
                        'update',update,'elapsed_s',update.elapsed_s,'has_following_unknown_block',block<spec.blocks);
                    stream_events=append(stream_events,event);
                end
                for s=1:numel(V(v).systems)
                    name=V(v).systems{s};label=method_label(name,V(v).name);
                    if strcmp(name,'frozen'),empty_n=0;train_n=0;validation_n=0;
                    elseif strcmp(name,'empty_only'),empty_n=double(open);train_n=0;validation_n=0;
                    elseif strcmp(name,'gated_calibration'),empty_n=double(open);train_n=0;validation_n=2*double(open);
                    else,empty_n=double(open);train_n=4*double(open);validation_n=2*double(open);end
                    cost=struct('scenario',string(scenario),'stream_seed',seed,'block',block,'method',string(label), ...
                        'reference_access_open',open&&~strcmp(name,'frozen'),'empty_observations_used',empty_n, ...
                        'training_references_used',train_n,'validation_references_used',validation_n, ...
                        'has_following_unknown_block',block<spec.blocks,'shared_plant_reference_trajectories',7, ...
                        'configured_offline_training_pool_n',600*double(V(v).use_offline&&strcmp(name,'gated_full')), ...
                        'historical_reference_replay',V(v).keep_history&&strcmp(name,'gated_full'),'reference_weight',spec.reference_weight);
                    stream_costs=append(stream_costs,cost);
                end
            end
            stream_rows=[stream_rows pre];completed=block; %#ok<AGROW>
            pgar_model_atomic_save(checkpoint,struct('identity',identity,'states',{states},'completed',completed, ...
                'stream_rows',stream_rows,'stream_events',stream_events,'stream_costs',stream_costs));
            done=done+1;progress('blocks',scenario,seed,block);
            fprintf('PCR %s seed%d block%d/%d, %.1fs, total %d/%d.\n',scenario,seed,block,spec.blocks,toc(timer),done,total);
        end
        rows=[rows stream_rows];events=[events stream_events];costs=[costs stream_costs]; %#ok<AGROW>
        retfile=fullfile(outdir,sprintf('retention_%s_%d.mat',scenario,seed));
        if isfile(retfile)
            S=load(retfile);assert(isequaln(S.identity,identity),'pcu:Identity','Retention identity changed.');ret=S.ret;
            assert(numel(ret)==numel(spec.retention_ids)*method_count*2,'pcu:Count','Retention count mismatch.');
        else
            ret=struct([]);nominal_states=states;
            for v=1:numel(V),for f=fieldnames(nominal_states{v}.systems).',nominal_states{v}.systems.(f{1}).eta=initial.eta0;end,end
            for id=spec.retention_ids(:).'
                D=load(fullfile(spec.robust_source_dir,'trials',sprintf('trial_%06d.mat',id)),'record');r=D.record;
                assert(strcmp(r.split,'test'),'pcu:Retention','Test-only diagnostic.');
                for v=1:numel(V)
                    pred=pcr_predict(nominal_states{v},r.obs);selected=select(pred.methods,V(v));
                    ret=score(ret,selected,r,scenario,seed,spec.blocks,'nominal_network_retention',states{v}.block_count);
                end
            end
            pgar_model_atomic_save(retfile,struct('identity',identity,'ret',ret,'scope','Nominal cached observations at eta0; W-only diagnostic, never used for updates.'));
        end
        retention_rows=[retention_rows ret]; %#ok<AGROW>
    end
end
writetable(struct2table(rows),fullfile(run_dir,'online_predictions.csv'));
writetable(struct2table(retention_rows),fullfile(run_dir,'retention_predictions.csv'));
writetable(struct2table(costs),fullfile(run_dir,'reference_cost_by_block.csv'));
pgar_model_atomic_save(fullfile(run_dir,'online_audit.mat'),struct('events',events,'spec',spec));
info=pcr_summarize_online(run_dir,spec);progress('complete','',0,0);
    function r=record(id)
        D=load(fullfile(data_root,'trials',sprintf('trial_%06d.mat',id)),'record');r=D.record;
        assert(r.trial_id==id&&strcmp(r.plan_signature,P.plan_signature),'pcu:Record','Wrong record identity.');
    end
    function refs=references(B,role)
        Q=B(string(B.role)==role,:);refs=struct([]);
        for k=1:height(Q)
            r=record(Q.trial_id(k));assert(strcmp(r.role,role)&&numel(r.known_theta)==3,'pcu:Role','Explicit known reference required.');
            f=fullfile(data_root,'trials',sprintf('trial_%06d.mat',r.trial_id));
            one=struct('obs',r.obs,'known_theta',r.known_theta,'is_reference',true,'role',char(role), ...
                'record_key',sprintf('%s/trial_%06d',data_root,r.trial_id),'record_hash',prc_file_hash(f));refs=append(refs,one);
        end
    end
    function progress(stage,sc,seed,b)
        prc_write_json(fullfile(run_dir,'progress_online.json'),struct('stage',stage,'blocks_done',done,'blocks_total',total, ...
            'scenario',sc,'stream_seed',seed,'block',b,'updated_utc',char(datetime('now','TimeZone','UTC')), ...
            'development_fixture',spec.development_fixture));
    end
end
function out=select(methods,V)
out=methods(ismember({methods.name},V.systems));
for i=1:numel(out),out(i).name=method_label(out(i).name,V.name);end
end
function n=method_label(system,variant)
if strcmp(variant,'main'),n=system;else,n=[system '_' variant];end
end
function A=score(A,methods,r,sc,seed,block,domain,updates)
t=double(r.theta_true(:).');physical=isstruct(r.truth)&&isfield(r.truth,'physical_success')&&logical(r.truth.physical_success);
for k=1:numel(methods)
    m=methods(k);
    for post=1:2
        if post==1,p=m.raw;label="raw";else,p=m.clipped;label="common_clip";end
        finite=all(isfinite(p));
        row=struct('scenario',string(sc),'stream_seed',seed,'block',block,'domain',string(domain), ...
            'method',string(m.name),'postprocessing',label,'trial_id',r.trial_id,'object_id',r.object_id, ...
            'mass_true_kg',t(1),'cx_true_m',t(2),'cz_true_m',t(3),'mass_est_kg',p(1),'cx_est_m',p(2),'cz_est_m',p(3), ...
            'finite_prediction',finite,'accepted',finite&&m.accepted&&physical,'physical_success',physical, ...
            'bounds_hit',m.bounds_hit,'updates_possible_before_prediction',updates,'evaluated_before_current_update',true,'reasons',strjoin(string(m.reasons),';'));
        A=append(A,row);
    end
end
end
function A=append(A,row),if isempty(A),A=row;else,A(end+1)=row;end,end

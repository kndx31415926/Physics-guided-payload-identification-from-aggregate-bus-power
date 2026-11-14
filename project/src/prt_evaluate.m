function info=prt_evaluate(run_dir,cfg,spec)
%PRT_EVALUATE Frozen models, complete denominators, object-cluster pairing.
% Every communication replicate is scored separately. Only model-seed
% ensembles average predictions; communication replicates never do.
started=tic;run_dir=char(run_dir);assert(isfile(fullfile(run_dir,'DATA_COMPLETE.json')),'prt:DataIncomplete','Finish data generation before evaluation.');
candidate=prt_data_plan(cfg,spec);plan=load(fullfile(run_dir,'data_plan.mat'));
assert(strcmp(plan.plan_signature,candidate.plan_signature),'prt:PlanMismatch','Evaluation inputs differ from fixed plan.');clear candidate
lockfile=javaObject('java.io.RandomAccessFile',fullfile(run_dir,'evaluation_stage.lock'),'rw');channel=lockfile.getChannel();
try,stage_lock=channel.tryLock();catch err,channel.close();lockfile.close();rethrow(err);end
if isempty(stage_lock),channel.close();lockfile.close();error('prt:EvaluationBusy','Another evaluator owns this run.');end
lock_cleanup=onCleanup(@()release_lock(stage_lock,channel,lockfile)); %#ok<NASGU>
directory=fullfile(run_dir,'evaluation_checkpoints');if ~isfolder(directory),mkdir(directory);end
predictor=pra_frozen_predict('load',cfg,spec);N=height(plan.objects);total=height(plan.manifest);
tables=cell(total,1);timing=cell(total,1);record_paths=strings(total,1);record_hashes=record_paths;done=0;reused=0;status('evaluating');
try
    for i=1:total
        row=plan.manifest(i,:);object=plan.objects(row.source_index,:);truth=[object.mass_kg object.cx_m object.cz_m];
        if row.reuse_source
            record_path=char(object.source_path);
            assert(strcmp(prc_file_hash(record_path),object.source_sha256),'prt:SourceChanged','Baseline source changed.');
        else
            record_path=fullfile(run_dir,'trials',sprintf('trial_%06d.mat',i));
            expected=struct('schema',plan.schema,'run_id',spec.run_id,'plan_signature',plan.plan_signature, ...
                'trial_id',i,'object_id',row.object_id,'theta_true',truth,'sensor_seed',row.sensor_seed, ...
                'condition',char(row.condition),'jitter_seed',row.jitter_seed,'realized_seed',row.realized_seed, ...
                'communication',plan.communications(i),'source_sha256',char(object.source_sha256));
            pgar_data_inspect_record(record_path,expected);
        end
        record_paths(i)=string(record_path);record_hashes(i)=string(prc_file_hash(record_path));
        file=fullfile(directory,sprintf('case_%06d.mat',i));
        if isfile(file)
            saved=load(file,'checkpoint');cp=saved.checkpoint;
            assert(strcmp(cp.run_key,plan.plan_signature)&&cp.case_id==i&&cp.object_id==row.object_id&& ...
                strcmp(cp.record_hash,record_hashes(i)),'prt:CheckpointMismatch','Evaluation checkpoint does not match immutable record.');
            reused=reused+1;
        else
            saved=load(record_path,'record');r=saved.record;
            assert(r.object_id==row.object_id&&all(abs(double(r.theta_true(:).')-truth)<=1e-12), ...
                'prt:SourceIdentity','Record identity/labels disagree with source plan.');
            physical=isempty(r.error)&&isstruct(r.truth)&&isfield(r.truth,'physical_success')&&isequal(r.truth.physical_success,true);
            prediction_error=[];
            try
                if ~isempty(r.error)||isempty(r.obs),prediction=pra_frozen_predict(predictor,struct());
                else,prediction=pra_frozen_predict(predictor,r.obs);end
            catch err
                prediction=pra_frozen_predict(predictor,struct());
                prediction_error=struct('identifier',err.identifier,'message',err.message);
            end
            cp=struct('schema','prt_communication_checkpoint_v1','run_key',plan.plan_signature,'case_id',i, ...
                'object_id',row.object_id,'condition_id',char(row.condition),'jitter_seed',row.jitter_seed, ...
                'realized_seed',row.realized_seed,'sensor_seed',row.sensor_seed,'record_path',record_path, ...
                'record_hash',char(record_hashes(i)),'theta_true',truth,'physical_success',physical, ...
                'prediction',prediction,'prediction_error',prediction_error,'record_exception',~isempty(r.error), ...
                'timing',timing_row(row,r),'completed_utc',utc());
            pgar_model_atomic_save(file,struct('checkpoint',cp));
        end
        tables{i}=prediction_rows(cp);timing{i}=struct2table(cp.timing);done=done+1;
        if mod(done,25)==0||done==total
            status('evaluating');fprintf('PRT frozen evaluation %d/%d; reused %d; %.1fs.\n',done,total,reused,toc(started));
        end
    end
    P=vertcat(tables{:});T=vertcat(timing{:});status('summarizing');
    S=summarize(P,N);B=paired_bootstrap(P,plan);
    writetable(P,fullfile(run_dir,'comm_predictions.csv'));writetable(S,fullfile(run_dir,'comm_summary.csv'));
    writetable(B,fullfile(run_dir,'comm_paired_differences.csv'));writetable(T,fullfile(run_dir,'comm_timing.csv'));
    writetable(table(plan.manifest.trial_id,plan.manifest.object_id,record_paths,record_hashes, ...
        'VariableNames',{'case_id','object_id','record_path','sha256'}),fullfile(run_dir,'comm_record_manifest.csv'));
    info=struct('schema','prt_communication_complete_v1','run_key',plan.plan_signature,'planned_objects',N, ...
        'condition_count',numel(plan.conditions),'planned_object_condition_replicates',total, ...
        'new_servo_episodes',sum(~plan.manifest.reuse_source),'reused_baseline_episodes',sum(plan.manifest.reuse_source), ...
        'prediction_rows',height(P),'summary_rows',height(S),'paired_difference_rows',height(B),'reused_checkpoints',reused, ...
        'elapsed_s',toc(started),'completed_utc',utc(), ...
        'scope','Full-servo timing sensitivity; held-out objects paired across conditions; frozen estimators, no tuning.');
    write_report(run_dir,plan,info);
    pgar_model_atomic_save(fullfile(run_dir,'comm_results.mat'),struct('info',info,'plan',plan,'summary',S,'paired',B,'timing',T));
    prc_write_json(fullfile(run_dir,'COMM_COMPLETE.json'),info);status('complete');
catch err
    status('failed',err.message);rethrow(err)
end
    function status(phase,message)
        if nargin<2,message='';end
        prc_write_json(fullfile(run_dir,'progress_evaluation.json'),struct('phase',phase,'done',done,'total',total, ...
            'reused',reused,'elapsed_s',toc(started),'utc',utc(),'message',message));
    end
end

function T=prediction_rows(cp)
methods=cp.prediction.methods;rows=struct([]);
for m=1:numel(methods)
    M=methods(m);ns=numel(M.seeds);
    for s=1:ns+(ns>1)
        if s<=ns
            seed=M.seeds(s);kind='single';if ns==1,kind='deterministic';end
            raw=M.theta_raw(s,:);bounded=M.theta_clipped(s,:);valid=M.valid(s);hit=M.bound_hit(s);
        else
            seed=0;kind='ensemble';raw=M.ensemble_raw;bounded=M.ensemble_clipped;valid=M.ensemble_valid;hit=M.ensemble_bound_hit;
        end
        positive=all(isfinite(raw))&&raw(1)>0;
        for post=1:2
            if post==1,p=raw;processing='raw';else,p=bounded;processing='common_clip';end
            finite=all(isfinite(p));accepted=finite&&valid&&positive&&cp.physical_success;
            r=struct('case_id',cp.case_id,'sensor_seed',cp.sensor_seed,'condition',cp.condition_id,'jitter_seed',cp.jitter_seed, ...
                'realized_seed',cp.realized_seed,'object_id',cp.object_id,'method',M.name, ...
                'model_seed',seed,'model_kind',kind,'postprocessing',processing, ...
                'true_mass_kg',cp.theta_true(1),'true_cx_m',cp.theta_true(2),'true_cz_m',cp.theta_true(3), ...
                'pred_mass_kg',p(1),'pred_cx_m',p(2),'pred_cz_m',p(3), ...
                'finite_prediction',finite,'model_valid',logical(valid),'accepted',accepted, ...
                'raw_positive_mass',positive,'bounds_hit',logical(hit),'physical_success',cp.physical_success, ...
                'teacher_accepted',cp.prediction.features.teacher_accepted);
            if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
        end
    end
end
T=struct2table(rows);
end

function S=summarize(P,N)
keys={'condition','jitter_seed','method','model_seed','model_kind','postprocessing'};
[G,K]=findgroups(P(:,keys));rows=struct([]);
for k=1:height(K)
    Q=P(G==k,:);assert(height(Q)==N&&numel(unique(Q.object_id))==N,'prt:SummaryDenominator','A replicate must include every planned object once.');
    true=[Q.true_mass_kg Q.true_cx_m Q.true_cz_m];prediction=[Q.pred_mass_kg Q.pred_cx_m Q.pred_cz_m];
    e=abs(prediction-true)*1000;finite=logical(Q.finite_prediction);accepted=logical(Q.accepted);
    mae=nan(1,3);rmse=mae;p95=mae;maximum=mae;accepted_mae=mae;mape=NaN;distance=NaN;distance95=NaN;
    if any(finite)
        mae=mean(e(finite,:),1);rmse=sqrt(mean(e(finite,:).^2,1));p95=prctile(e(finite,:),95,1);maximum=max(e(finite,:),[],1);
        mape=100*mean(e(finite,1)./(true(finite,1)*1000));
        d=vecnorm((prediction(finite,2:3)-true(finite,2:3))*1000,2,2);distance=mean(d);distance95=prctile(d,95);
    end
    if any(accepted),accepted_mae=mean(e(accepted,:),1);end
    row=struct('condition',char(string(Q.condition(1))),'jitter_seed',Q.jitter_seed(1), ...
        'method',char(string(Q.method(1))),'model_seed',Q.model_seed(1),'model_kind',char(string(Q.model_kind(1))), ...
        'postprocessing',char(string(Q.postprocessing(1))),'aggregation','single_communication_replicate', ...
        'replicate_count',1,'planned_objects',N,'planned_prediction_count',N, ...
        'finite_n',sum(finite),'model_valid_n',sum(Q.model_valid),'accepted_n',sum(accepted), ...
        'raw_positive_mass_n',sum(Q.raw_positive_mass),'bounds_hit_n',sum(Q.bounds_hit), ...
        'physical_success_n',sum(Q.physical_success),'prediction_coverage',mean(finite), ...
        'accepted_coverage',mean(accepted),'bounds_hit_rate',mean(Q.bounds_hit), ...
        'mass_mae_g',mae(1),'cx_mae_mm',mae(2),'cz_mae_mm',mae(3), ...
        'mass_rmse_g',rmse(1),'cx_rmse_mm',rmse(2),'cz_rmse_mm',rmse(3), ...
        'mass_p95_g',p95(1),'cx_p95_mm',p95(2),'cz_p95_mm',p95(3), ...
        'mass_max_g',maximum(1),'cx_max_mm',maximum(2),'cz_max_mm',maximum(3), ...
        'mass_mape_percent',mape,'planar_com_mean_distance_mm',distance,'planar_com_p95_distance_mm',distance95, ...
        'accepted_mass_mae_g',accepted_mae(1),'accepted_cx_mae_mm',accepted_mae(2),'accepted_cz_mae_mm',accepted_mae(3));
    if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
end
S=struct2table(rows);keys={'condition','method','model_seed','model_kind','postprocessing'};
[G,K]=findgroups(S(:,keys));aggregate=struct([]);
counts={'finite_n','model_valid_n','accepted_n','raw_positive_mass_n','bounds_hit_n','physical_success_n'};
metrics={'prediction_coverage','accepted_coverage','bounds_hit_rate', ...
    'mass_mae_g','cx_mae_mm','cz_mae_mm','mass_rmse_g','cx_rmse_mm','cz_rmse_mm', ...
    'mass_p95_g','cx_p95_mm','cz_p95_mm','mass_max_g','cx_max_mm','cz_max_mm', ...
    'mass_mape_percent','planar_com_mean_distance_mm','planar_com_p95_distance_mm', ...
    'accepted_mass_mae_g','accepted_cx_mae_mm','accepted_cz_mae_mm'};
for k=1:height(K)
    Q=S(G==k,:);if height(Q)==1,continue,end
    row=table2struct(Q(1,:));row.jitter_seed=-1;row.aggregation='mean_metrics_over_communication_replicates';
    row.replicate_count=height(Q);row.planned_prediction_count=N*height(Q);
    for j=1:numel(counts),row.(counts{j})=sum(Q.(counts{j}));end
    for j=1:numel(metrics),row.(metrics{j})=mean(Q.(metrics{j}));end
    if isempty(aggregate),aggregate=row;else,aggregate(end+1)=row;end %#ok<AGROW>
end
if ~isempty(aggregate),S=[S;struct2table(aggregate)];end
end

function B=paired_bootstrap(P,plan)
% One resampling unit is a payload object with all its timing replicates.
% A pair enters error CI only when both conditions have finite predictions
% for every planned replicate; pair_n and full N are always reported.
Q=P(ismember(string(P.model_kind),["ensemble","deterministic"]),:);
comparisons=[2 1;3 1;3 2];keys={'method','model_kind','postprocessing'};[G,K]=findgroups(Q(:,keys));
ids=plan.objects.object_id;N=numel(ids);rows=struct([]);draws=2000;bootstrap_seed=105001;
stream=RandStream('mt19937ar','Seed',bootstrap_seed);
for k=1:height(K)
    group=Q(G==k,:);E=nan(N,3,numel(plan.conditions));A=zeros(N,numel(plan.conditions));
    for c=1:numel(plan.conditions)
        for i=1:N
            x=group(string(group.condition)==string(plan.conditions(c).id)&group.object_id==ids(i),:);
            expected=1;if plan.conditions(c).randomized,expected=numel(plan.spec.robust_seeds);end
            assert(height(x)==expected,'prt:PairDenominator','Pairing lost a planned communication replicate.');
            truth=[x.true_mass_kg x.true_cx_m x.true_cz_m];pred=[x.pred_mass_kg x.pred_cx_m x.pred_cz_m];
            if all(x.finite_prediction),E(i,:,c)=mean(abs(pred-truth)*1000,1);end
            A(i,c)=mean(x.accepted);
        end
    end
    for j=1:size(comparisons,1)
        c=comparisons(j,1);b=comparisons(j,2);delta=E(:,:,c)-E(:,:,b);
        valid=all(isfinite(delta),2);n=sum(valid);mu=nan(1,3);lo=mu;hi=mu;
        if n>0
            d=delta(valid,:);mu=mean(d,1);ix=randi(stream,n,[n draws]);
            for axis=1:3
                v=d(:,axis);boot=mean(reshape(v(ix),n,draws),1);interval=prctile(boot,[2.5 97.5]);lo(axis)=interval(1);hi(axis)=interval(2);
            end
        end
        coverage=A(:,c)-A(:,b);ix=randi(stream,N,[N draws]);boot=mean(reshape(coverage(ix),N,draws),1);ci=prctile(boot,[2.5 97.5]);
        r=struct('condition',plan.conditions(c).id,'reference_condition',plan.conditions(b).id, ...
            'method',char(string(group.method(1))),'model_kind',char(string(group.model_kind(1))), ...
            'postprocessing',char(string(group.postprocessing(1))),'planned_objects',N,'paired_finite_objects',n, ...
            'paired_complete_fraction',n/N,'bootstrap_draws',draws,'bootstrap_seed',bootstrap_seed, ...
            'mass_delta_mae_g',mu(1),'mass_ci_low_g',lo(1),'mass_ci_high_g',hi(1), ...
            'cx_delta_mae_mm',mu(2),'cx_ci_low_mm',lo(2),'cx_ci_high_mm',hi(2), ...
            'cz_delta_mae_mm',mu(3),'cz_ci_low_mm',lo(3),'cz_ci_high_mm',hi(3), ...
            'accepted_coverage_delta',mean(coverage),'coverage_ci_low',ci(1),'coverage_ci_high',ci(2), ...
            'sign_convention','condition minus reference; positive error delta is worse');
        if isempty(rows),rows=r;else,rows(end+1)=r;end %#ok<AGROW>
    end
end
B=struct2table(rows);
end

function row=timing_row(manifest,record)
row=struct('case_id',manifest.trial_id,'object_id',manifest.object_id,'condition',string(manifest.condition), ...
    'jitter_seed',manifest.jitter_seed,'realized_seed',manifest.realized_seed,'sensor_seed',manifest.sensor_seed, ...
    'reuse_source',manifest.reuse_source,'communication_logged',false,'power_samples',0,'physical_success',false, ...
    'observation_stationary',false,'record_exception',~isempty(record.error), ...
    'configured_command_min_ms',NaN,'configured_command_max_ms',NaN, ...
    'configured_encoder_min_ms',NaN,'configured_encoder_max_ms',NaN, ...
    'command_requested_min_ms',NaN,'command_requested_max_ms',NaN,'command_requested_mean_ms',NaN, ...
    'command_applied_min_ms',NaN,'command_applied_max_ms',NaN,'command_applied_mean_ms',NaN, ...
    'encoder_requested_min_ms',NaN,'encoder_requested_max_ms',NaN,'encoder_requested_mean_ms',NaN, ...
    'encoder_applied_min_ms',NaN,'encoder_applied_max_ms',NaN,'encoder_applied_mean_ms',NaN, ...
    'command_interval_min_ms',NaN,'command_interval_max_ms',NaN, ...
    'encoder_age_max_ms',NaN,'encoder_receive_age_max_ms',NaN,'causality_violations',NaN, ...
    'command_sent_n',NaN,'command_applied_n',NaN,'encoder_sampled_n',NaN,'encoder_received_n',NaN);
if manifest.reuse_source
    row.configured_command_min_ms=20;row.configured_command_max_ms=20;
    row.configured_encoder_min_ms=0;row.configured_encoder_max_ms=0;
elseif isfield(record,'communication')
    row.configured_command_min_ms=1000*record.communication.command_delay_s(1);
    row.configured_command_max_ms=1000*record.communication.command_delay_s(2);
    row.configured_encoder_min_ms=1000*record.communication.encoder_delay_s(1);
    row.configured_encoder_max_ms=1000*record.communication.encoder_delay_s(2);
end
if isstruct(record.truth)&&isfield(record.truth,'physical_success'),row.physical_success=logical(record.truth.physical_success);end
if isstruct(record.obs)
    if isfield(record.obs,'communication'),row.communication_logged=true;end
    if isfield(record.obs,'t'),row.power_samples=numel(record.obs.t);end
    if isfield(record.obs,'stationary'),row.observation_stationary=all(record.obs.stationary);end
end
if ~isempty(record.error),return,end
if isstruct(record.truth)&&isfield(record.truth,'communication')
    C=record.truth.communication;command=C.command_packets;encoder=C.encoder_packets;
    sent=isfinite(command.q(:,1));applied=isfinite(command.applied_t);sampled=isfinite(encoder.q(:,1));received=isfinite(encoder.receive_t);
    row.command_sent_n=sum(sent);row.command_applied_n=sum(applied);row.encoder_sampled_n=sum(sampled);row.encoder_received_n=sum(received);
    [row.command_requested_min_ms,row.command_requested_max_ms,row.command_requested_mean_ms]=stats_ms(command.requested_delay_s(sent));
    [row.command_applied_min_ms,row.command_applied_max_ms,row.command_applied_mean_ms]=stats_ms(command.applied_t(applied)-command.issued_t(applied));
    [row.encoder_requested_min_ms,row.encoder_requested_max_ms,row.encoder_requested_mean_ms]=stats_ms(encoder.requested_delay_s(sampled));
    [row.encoder_applied_min_ms,row.encoder_applied_max_ms,row.encoder_applied_mean_ms]=stats_ms(encoder.receive_t(received)-encoder.sample_t(received));
    [row.command_interval_min_ms,row.command_interval_max_ms]=stats_ms(diff(command.issued_t(sent)));
    O=record.obs.communication;t=record.obs.t(:);st=O.power_record_encoder_sample_t(:);rt=O.power_record_encoder_receive_t(:);
    if ~isempty(t)
        row.encoder_age_max_ms=1000*max(t-st);row.encoder_receive_age_max_ms=1000*max(t-rt);
        row.causality_violations=sum(st>rt+1e-10|rt>t+1e-10|st< -1e-10);
    end
end
end
function [minimum,maximum,average]=stats_ms(x)
x=double(x(:))*1000;x=x(isfinite(x));minimum=NaN;maximum=NaN;average=NaN;
if ~isempty(x),minimum=min(x);maximum=max(x);average=mean(x);end
end

function write_report(root,plan,info)
fid=fopen(fullfile(root,'COMM_README.txt'),'w','n','UTF-8');assert(fid>=0);cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'Frozen-model full-servo communication robustness\nRun key: %s\n',plan.plan_signature);
fprintf(fid,'%d held-out payload objects; %d conditions; %d object-condition-repeat cases (%d new servo episodes).\n', ...
    info.planned_objects,info.condition_count,info.planned_object_condition_replicates,info.new_servo_episodes);
fprintf(fid,'Legacy baseline is the unchanged source record with fixed 20 ms command delay and zero host encoder return delay.\n');
fprintf(fid,'New fixed control uses 12.5 ms requested one-way delay on command and encoder return independently. Jitter uses independently drawn uniform [10,15] ms delays for every packet and link.\n');
fprintf(fid,'The rigid-body/PID plant is rerun at 1 ms. Requested delays are conservatively ceiled to the plant grid and requested/effective packet times are saved in truth.communication for auditing only; observation.communication contains host-observable issue/receive timestamps.\n');
fprintf(fid,'50 ms command/encoder cadence is asynchronous and is not increased by the communication delay. Local PID remains at 1 ms; host power samples remain at 10 ms with accurate timestamps.\n');
fprintf(fid,'The original sensor RNG seed is retained per object in every condition. Communication has separate seeded RNG streams. There are no new objects, test-label inputs, network updates or hyperparameter tuning.\n');
fprintf(fid,'The fixed 12.5 ms comparator separates part of the timing mean shift from randomness. On the 1 ms grid fixed 12.5 ms applies at 13 ms; continuous uniform 10-15 ms rounds to 11-15 ms with expected 13 ms.\n');
fprintf(fid,'Raw/common_clip outputs, model single seeds and model ensembles are distinct. Communication repetitions are NEVER averaged into predictions; per-repetition metrics are computed first.\n');
fprintf(fid,'Every condition retains the full planned denominator; failures and rejected finite candidates are retained. Candidate error metrics condition on finite output and must be read together with finite/accepted coverage.\n');
fprintf(fid,'Rows jitter_seed=-1 are arithmetic means of per-repetition metrics, including RMSE and P95; maxima in these rows are means of repetition maxima, not pooled maxima.\n');
fprintf(fid,'Paired differences first average absolute error within each object over timing repetitions, then bootstrap objects 2000 times. Error pairs require all repetitions finite on both sides; coverage differences use every object.\n');
fprintf(fid,'Positive error differences mean worse performance. Confidence intervals concern this object distribution and fixed three timing seeds, not every possible network or hardware deployment.\n');
fprintf(fid,'This isolates bounded latency jitter without packet loss, clock offset, bandwidth contention, power acquisition delay or physical wear. Communication packet logs remain in immutable raw trial records.\n');
end
function release_lock(lock,channel,file)
try,lock.release();catch,end
try,channel.close();catch,end
try,file.close();catch,end
end
function s=utc(),s=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));end

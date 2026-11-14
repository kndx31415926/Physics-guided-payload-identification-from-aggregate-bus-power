function info=prc_evaluate(run_dir,cfg,spec,model,pe)
% Compare immutable models on fresh test objects, preserving raw predictions.
assert(isfile(fullfile(run_dir,'LOCKED_SELECTION_BEFORE_TEST.mat')),'prc:Unlocked','Model selection is not locked.');
assert(isfile(fullfile(spec.holdout_dir,'COMPLETE.json')),'prc:Data','Holdout data job is incomplete.');
plan=load(fullfile(spec.holdout_dir,'data_plan.mat'));test=find(plan.objects.split=="test");
assert(numel(test)==spec.expected_test_n,'prc:TestSize','Unexpected holdout size.');
D=prc_build_dataset(spec.holdout_dir,fullfile(run_dir,'test_data.mat'),test,cfg);
prc_validate_dataset(D,plan,test);assert(all(string(D.split)=="test"));
N=numel(test);ids=D.object_id;truth=D.theta;
% Explicitly remove all labels before the literature inference interfaces.
fields=intersect(fieldnames(D),{'theta','tau_label','truth'});observed=rmfield(D,fields);
methods=struct('name',{},'seeds',{},'raw',{},'valid',{});
pred=prc_pe_predict(pe,observed,(1:N).');
methods(end+1)=entry('lao_pe_transplant',0,reshape(pred.theta_raw,N,3,1),pred.valid);
P=prc_lao_predict(model,observed,(1:N).','uniform');
methods(end+1)=entry('lao_t_transplant',model.seeds,P.theta_raw,P.valid);
A=prc_lao_predict(model,observed,(1:N).','attention');
methods(end+1)=entry('lao_ta_transplant',model.seeds,A.theta_raw,A.valid);
% These are pre-existing frozen 600-object models. No refitting on new data.
old=load(fullfile(spec.source_dir,'training_results.mat'),'results');R=old.results;
assert(isequal(R.spec.scale,spec.scale)&&strcmp(R.spec.probe_id,'probe_02'), ...
    'prc:FrozenContract','Frozen feature scale or probe does not match this evaluator.');
b=find(R.spec.train_sizes==spec.train_budget,1);assert(~isempty(b));
feature_usable=false(N,1);teacher_accepted=false(N,1);physical_success=false(N,1);
base=nan(N,3);Xq=nan(N,128);Xp=nan(N,40);Xr=nan(N,13);
input_path=cell(N,1);sha256=cell(N,1);
for i=1:N
    input_path{i}=fullfile(spec.holdout_dir,'trials',sprintf('trial_%06d.mat',ids(i)));
    sha256{i}=prc_file_hash(input_path{i});record=load(input_path{i},'record');record=record.record;
    if isstruct(record.truth)&&isfield(record.truth,'physical_success'),physical_success(i)=record.truth.physical_success;end
    f=pgar_model_features(cfg,record.obs,spec.scale,'probe_02');
    feature_usable(i)=f.usable;teacher_accepted(i)=f.teacher_accepted;
    if f.usable,base(i,:)=f.base;Xq(i,:)=f.q;Xp(i,:)=f.power;Xr(i,:)=f.residual;end
    if mod(i,25)==0||i==N
        prc_write_json(fullfile(run_dir,'progress_evaluation.json'),struct('stage','frozen_model_features','done',i,'total',N));
    end
end
writetable(table(input_path,sha256),fullfile(run_dir,'holdout_manifest.csv'));
inputs={Xq,[Xq Xp],Xp,Xr};names={'encoder_only','encoder_plus_power','power_only','physics_residual_nn'};
for m=1:4
    raw=nan(N,3,numel(R.spec.network_seeds));valid=repmat(feature_usable,1,numel(R.spec.network_seeds));
    X=inputs{m};good=feature_usable;
    for s=1:numel(R.spec.network_seeds)
        learner=R.students{b,m,s};offset=zeros(sum(good),3);if m==4,offset=base(good,:);end
        raw(good,:,s)=predict(learner.model,X(good,learner.columns)).*spec.scale+offset;
    end
    if m==4,valid=valid&teacher_accepted;end
    methods(end+1)=entry(names{m},R.spec.network_seeds,raw,valid); %#ok<AGROW>
end
methods(end+1)=entry('physics_inverse',0,reshape(base,N,3,1),feature_usable&teacher_accepted);
oldtrain=R.objects(string(R.objects.split)=="train",:);prior=mean([oldtrain.mass_kg oldtrain.cx_m oldtrain.cz_m],1);
methods(end+1)=entry('training_mean',0,reshape(repmat(prior,N,1),N,3,1),true(N,1));
rows=struct([]);summary=struct([]);ensembles=struct('name',{},'raw',{},'clipped',{});
for m=1:numel(methods)
    M=methods(m);raw=M.raw;bounded=clip(raw,cfg.ident.bounds);
    ns=size(raw,3);raw_ensemble=mean(raw,3);bounded_ensemble=mean(bounded,3);
    seed_hits=reshape(any(abs(bounded-raw)>1e-12,2)&all(isfinite(raw),2),N,ns);
    ensembles(end+1)=struct('name',M.name,'raw',raw_ensemble,'clipped',bounded_ensemble); %#ok<AGROW>
    for s=1:ns+1
        if s<=ns
            seed=M.seeds(s);p=raw(:,:,s);pc=bounded(:,:,s);valid=M.valid(:,min(s,size(M.valid,2)));
            kind='single';
        else
            if ns==1,continue,end
            seed=0;p=raw_ensemble;pc=bounded_ensemble;valid=all(M.valid,2);kind='ensemble';
        end
        if ns==1,kind='deterministic';end
        for post=1:2
            if post==1,prediction=p;processing='raw';else,prediction=pc;processing='common_clip';end
            finite=all(isfinite(prediction),2);raw_positive=all(isfinite(p),2)&p(:,1)>0;
            if s<=ns,hit=seed_hits(:,s);else,hit=any(seed_hits,2);end
            for i=1:N
                r=struct('method',M.name,'seed',seed,'model_kind',kind,'postprocessing',processing, ...
                    'object_id',ids(i),'true_mass_kg',truth(i,1),'true_cx_m',truth(i,2),'true_cz_m',truth(i,3), ...
                    'pred_mass_kg',prediction(i,1),'pred_cx_m',prediction(i,2),'pred_cz_m',prediction(i,3), ...
                    'finite_prediction',finite(i),'model_valid',logical(valid(i)), ...
                    'accepted',finite(i)&&valid(i)&&physical_success(i)&&raw_positive(i), ...
                    'raw_positive_mass',raw_positive(i),'bounds_hit',hit(i),'physical_success',physical_success(i));
                rows=append(rows,r);
            end
            err=abs(prediction-truth)*1000;good=finite;
            meanerr=mean(err(good,:),1);rmse=sqrt(mean(err(good,:).^2,1));maxerr=max(err(good,:),[],1);
            mape=100*mean(abs(prediction(good,1)-truth(good,1))./truth(good,1));
            com_distance=mean(vecnorm((prediction(good,2:3)-truth(good,2:3))*1000,2,2));
            if ~any(good),meanerr=nan(1,3);rmse=meanerr;maxerr=meanerr;end
            v=good&valid&physical_success&raw_positive;acceptederr=mean(err(v,:),1);if ~any(v),acceptederr=nan(1,3);end
            row=struct('method',M.name,'seed',seed,'model_kind',kind,'postprocessing',processing, ...
                'planned_test_n',N,'finite_n',sum(finite),'model_valid_n',sum(valid), ...
                'accepted_n',sum(v),'prediction_coverage',mean(finite),'accepted_coverage',mean(v), ...
                'raw_positive_mass_n',sum(raw_positive),'bounds_hit_n',sum(hit), ...
                'mass_mae_g',meanerr(1),'cx_mae_mm',meanerr(2),'cz_mae_mm',meanerr(3), ...
                'mass_mape_percent',mape,'mass_mae_span_percent',100*meanerr(1)/(1000*spec.scale(1)), ...
                'planar_com_mean_distance_mm',com_distance, ...
                'mass_rmse_g',rmse(1),'cx_rmse_mm',rmse(2),'cz_rmse_mm',rmse(3), ...
                'mass_max_g',maxerr(1),'cx_max_mm',maxerr(2),'cz_max_mm',maxerr(3), ...
                'accepted_mass_mae_g',acceptederr(1),'accepted_cx_mae_mm',acceptederr(2),'accepted_cz_mae_mm',acceptederr(3));
            summary=append(summary,row);
        end
    end
end
S=struct2table(summary);predictions=struct2table(rows);
writetable(S,fullfile(run_dir,'summary.csv'));writetable(predictions,fullfile(run_dir,'predictions.csv'));
CI=bootstrap(ensembles,truth,spec);writetable(CI,fullfile(run_dir,'paired_bootstrap.csv'));
status=table(ids,physical_success,logical(D.usable),feature_usable,teacher_accepted, ...
    'VariableNames',{'object_id','physical_success','literature_features_usable','pgar_features_usable','teacher_accepted'});
writetable(status,fullfile(run_dir,'test_status.csv'));
pgar_model_atomic_save(fullfile(run_dir,'comparison_results.mat'), ...
    struct('spec',spec,'summary',S,'predictions',predictions,'paired_bootstrap',CI,'methods',methods,'ensembles',ensembles, ...
    'lao_uniform',P,'lao_attention',A,'pe_predictions',pred));
write_report(run_dir,spec,S,N);
draw_figure(run_dir,S);
info=struct('planned_test_objects',N,'data_physical_failures',sum(~physical_success), ...
    'summary_path',fullfile(run_dir,'summary.csv'),'report_path',fullfile(run_dir,'REPORT.txt'), ...
    'method_count',numel(methods),'fresh_holdout',~spec.development_fixture,'development_fixture',spec.development_fixture);
prc_write_json(fullfile(run_dir,'progress_evaluation.json'),struct('stage','complete','details',info));
end
function M=entry(name,seeds,raw,valid)
M=struct('name',name,'seeds',seeds,'raw',raw,'valid',logical(valid));
end
function A=append(A,row)
if isempty(A),A=row;else,A(end+1)=row;end
end
function p=clip(p,bounds)
invalid=~isfinite(p);
for j=1:3,p(:,j,:)=max(bounds(j,1),min(bounds(j,2),p(:,j,:)));end
p(invalid)=NaN;
end
function CI=bootstrap(E,T,spec)
ref=find(strcmp({E.name},'physics_residual_nn'));assert(isscalar(ref));
pairs=[setdiff((1:numel(E)).',ref),repmat(ref,numel(E)-1,1)];
extra={'lao_t_transplant','lao_ta_transplant';'encoder_only','encoder_plus_power';'power_only','encoder_plus_power'};
for k=1:size(extra,1),pairs(end+1,:)=[find(strcmp({E.name},extra{k,1})),find(strcmp({E.name},extra{k,2}))];end
rng(spec.bootstrap_seed,'twister');rows=struct([]);parameters={'mass','cx','cz'};
for pair=1:size(pairs,1)
    i=pairs(pair,1);ref=pairs(pair,2);
    for processing={'raw','clipped'}
        field=processing{1};a=E(i).(field);b=E(ref).(field);good=all(isfinite(a),2)&all(isfinite(b),2);
        delta=(abs(a(good,:)-T(good,:))-abs(b(good,:)-T(good,:)))*1000;n=sum(good);
        if n>1,draw=randi(n,n,spec.bootstrap_n);else,draw=[];end
        for j=1:3
            lo=NaN;hi=NaN;av=NaN;
            if n>1,x=delta(:,j);boot=mean(x(draw),1);q=prctile(boot,[2.5 97.5]);lo=q(1);hi=q(2);av=mean(x);end
            row=struct('baseline',E(i).name,'reference',E(ref).name,'postprocessing',field, ...
                'parameter',parameters{j},'mean_error_reduction',av,'lower95',lo,'upper95',hi, ...
                'paired_n',n,'planned_n',size(T,1),'bootstrap_n',spec.bootstrap_n, ...
                'scope','Paired finite test objects; conditional on frozen models; no multiplicity correction.');
            rows=append(rows,row);
        end
    end
end
CI=struct2table(rows);
end
function write_report(root,spec,S,N)
fid=fopen(fullfile(root,'REPORT.txt'),'w','n','UTF-8');c=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'Literature-method transplant comparison\n%s\n',spec.scope);
if spec.development_fixture
    fprintf(fid,'DEVELOPMENT FIXTURE ONLY: %d reused test records. No scientific precision claim.\n',N);
else
    fprintf(fid,'Fresh independent test objects: %d. Old test observations are not used in this run.\n',N);
end
fprintf(fid,'Same original 600 train / 150 validation objects. Existing PGAR weights remain frozen.\n');
fprintf(fid,'PE, torque network and attention-weighted torque network follow Lao et al. arXiv:2104.09858v2.\n');
fprintf(fid,'Adaptations: PID vs PD; vertical-yaw vs horizontal first axis; 8 vs 64 postures; planar vs 3D COM; known grasp frame vs camera/tag transform.\n');
fprintf(fid,'Attention loss uses predefined parameter spans because source training loss units are not specified.\n');
fprintf(fid,'No measured/simulated joint torque enters literature model inputs. Training torque labels are calculated from known training payloads and nominal gravity.\n');
fprintf(fid,'Raw means before additional output clipping; it does not remove constraints intrinsic to a method. The frozen physics inverse itself uses bounded optimization, and the residual model uses that bounded initial estimate.\n');
fprintf(fid,'Raw and uniform wide-bounds clipping are reported separately; clipping precedes equal seed averaging. Literature-method constrained WLS is diagnostic only.\n');
fprintf(fid,'Ensemble bounds_hit_n counts objects for which ANY seed was clipped, including cancellation in the ensemble mean.\n');
fprintf(fid,'All finite errors, validity/coverage and clipping frequency must be read together. MAE is not a per-object guarantee.\n');
fprintf(fid,'Training-condition/controller differences can weaken encoder discrepancies. Results do not rank the original hardware systems.\n');
fprintf(fid,'Frozen PGAR signal models share the original feature pipeline, which checks encoder, power and teacher computability even for the encoder-only learner. Coverage therefore describes this pipeline, not sensor-fault resilience.\n');
fprintf(fid,'Acceptance in this comparison requires finite output, method validity, physical simulation success and positive native mass. This adds an audit gate to frozen PGAR deployment; method-specific validity rules still differ. Finite candidates from physical failures are retained as diagnostics.\n');
fprintf(fid,'Fixed nominal simulation only: no wear, hardware transfer or 3D claim. Bootstrap conditions on these frozen models.\n\n');
disp_rows=S(string(S.model_kind)~="single",:);
for i=1:height(disp_rows)
    r=disp_rows(i,:);fprintf(fid,'%s | %s | MAE %.6f g / %.6f mm / %.6f mm | finite %d/%d, accepted %d, bounds hit %d\n', ...
        string(r.method),string(r.postprocessing),r.mass_mae_g,r.cx_mae_mm,r.cz_mae_mm,r.finite_n,N,r.accepted_n,r.bounds_hit_n);
end
end
function draw_figure(root,S)
chosen=string(S.model_kind)~="single"&string(S.postprocessing)=="common_clip"&string(S.method)~="training_mean";
Q=S(chosen,:);labels=replace(string(Q.method),'_',' ');
fig=figure('Visible','off','Color','w','Position',[100 100 1500 620]);c=onCleanup(@()close(fig)); %#ok<NASGU>
tiledlayout(1,3,'TileSpacing','compact');fields={'mass_mae_g','cx_mae_mm','cz_mae_mm'};units={'Mass MAE (g)','COM x MAE (mm)','COM z MAE (mm)'};
for j=1:3
    nexttile;barh(Q.(fields{j}));yticks(1:height(Q));yticklabels(labels);set(gca,'YDir','reverse','TickLabelInterpreter','none');
    xlabel(units{j});grid on;title('Same new test objects');
end
sgtitle('Fixed nominal simulation; literature methods transplanted to 8-pose PID arm; common bounds');
exportgraphics(fig,fullfile(root,'comparison.png'),'Resolution',160);
end

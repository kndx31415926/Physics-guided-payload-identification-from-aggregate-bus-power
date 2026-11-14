function out=pra_frozen_predict(predictor,obs,eta)
%PRA_FROZEN_PREDICT Observation-only inference from immutable comparisons.
% P=pra_frozen_predict('load',cfg,spec) loads models once; spec.source_dir and
% spec.lao_dir name completed runs. out=pra_frozen_predict(P,obs[,eta]) uses
% only observations. Optional eta replaces static electrical coefficients
% for physics features; all neural weights remain frozen. No truth/ID input.
if (ischar(predictor)||isstring(predictor))&&strcmp(string(predictor),"load")
    cfg=obs;spec=eta;
    saved=load(fullfile(spec.source_dir,'training_results.mat'),'results');R=saved.results;
    literature=load(fullfile(spec.lao_dir,'models.mat'),'model','pe');
    budget=600;if isfield(spec,'train_budget'),budget=spec.train_budget;end
    b=find(R.spec.train_sizes==budget,1);assert(~isempty(b),'pra:Budget','Frozen budget is unavailable.');
    assert(strcmp(R.spec.probe_id,'probe_02')&&numel(R.spec.scale)==3, ...
        'pra:FrozenContract','Expected eight-pose nominal model.');
    out=struct('schema','pra_frozen_predictor_v1','cfg',cfg,'scale',R.spec.scale, ...
        'probe_id',R.spec.probe_id,'network_seeds',R.spec.network_seeds, ...
        'students',{R.students(b,:,:)},'lao',literature.model,'pe',literature.pe, ...
        'source_dir',spec.source_dir,'lao_dir',spec.lao_dir);
    return
end
assert(isstruct(predictor)&&strcmp(predictor.schema,'pra_frozen_predictor_v1'), ...
    'pra:Predictor','Expected a frozen predictor.');
cfg=predictor.cfg;
if nargin>=3&&~isempty(eta)
    assert(isstruct(eta)&&isfield(eta,'coefficients')&&numel(eta.coefficients)==13&& ...
        all(isfinite(eta.coefficients))&&all(eta.coefficients>=0), ...
        'pra:Eta','Expected finite nonnegative electrical coefficients.');
    cfg.legacy.power.coefficients=double(eta.coefficients(:).');
end
B=cfg.ident.bounds;F=pgar_model_features(cfg,obs,predictor.scale,predictor.probe_id);
O=prc_observation(obs,cfg);
D=struct('state',reshape(O.state,1,8,4,4),'g0',nan(1,8,4), ...
    'Y',nan(1,8,4,3),'usable',O.usable,'object_id',1);
if all(isfinite(O.state(:,:,1)),'all')
    [g0,Y]=bpil_static_design(cfg,O.state(:,:,1));D.g0=reshape(g0,1,8,4);D.Y=reshape(Y,1,8,4,3);
end
M=struct('name',{},'seeds',{},'theta_raw',{},'theta_clipped',{}, ...
    'finite',{},'valid',{},'accepted',{},'bound_hit',{},'raw_positive_mass',{}, ...
    'ensemble_raw',{},'ensemble_clipped',{},'ensemble_valid',{},'ensemble_accepted',{},'ensemble_bound_hit',{});
if O.usable
    P=prc_pe_predict(predictor.pe,D,1);pe_raw=reshape(P.theta_raw,1,3);pe_valid=P.valid;
    T=prc_lao_predict(predictor.lao,D,1,'uniform');A=prc_lao_predict(predictor.lao,D,1,'attention');
    t_raw=reshape(permute(T.theta_raw,[3 2 1]),[],3);a_raw=reshape(permute(A.theta_raw,[3 2 1]),[],3);
    t_valid=T.valid(:);a_valid=A.valid(:);
else
    pe_raw=nan(1,3);pe_valid=false;
    ns=numel(predictor.lao.seeds);t_raw=nan(ns,3);a_raw=t_raw;t_valid=false(ns,1);a_valid=t_valid;
end
M(end+1)=entry('lao_pe_transplant',0,pe_raw,pe_valid,B);
M(end+1)=entry('lao_t_transplant',predictor.lao.seeds,t_raw,t_valid,B);
M(end+1)=entry('lao_ta_transplant',predictor.lao.seeds,a_raw,a_valid,B);
names={'encoder_only','encoder_plus_power','power_only','physics_residual_nn'};
inputs={F.q,[F.q F.power],F.power,F.residual};ns=numel(predictor.network_seeds);
for k=1:4
    raw=nan(ns,3);valid=repmat(logical(F.usable),ns,1);
    if F.usable
        for s=1:ns
            learner=predictor.students{1,k,s};offset=zeros(1,3);if k==4,offset=F.base;end
            raw(s,:)=predict(learner.model,inputs{k}(:,learner.columns)).*predictor.scale+offset;
        end
    end
    if k==4,valid=valid&F.teacher_accepted;end
    M(end+1)=entry(names{k},predictor.network_seeds,raw,valid,B); %#ok<AGROW>
end
M(end+1)=entry('physics_inverse',0,F.base,F.usable&&F.teacher_accepted,B);
out=struct('schema','pra_frozen_prediction_v1','methods',M,'features',F, ...
    'literature_usable',O.usable,'literature_reasons',{O.reasons}, ...
    'eta',struct('coefficients',cfg.legacy.power.coefficients), ...
    'scope','Frozen weights; estimator acceptance only. Physical simulation status belongs to the external evaluator.');
end

function M=entry(name,seeds,raw,valid,B)
bounded=raw;invalid=~isfinite(raw);
bounded=min(max(bounded,B(:,1).'),B(:,2).');bounded(invalid)=NaN;
finite=all(isfinite(raw),2);positive=finite&raw(:,1)>0;valid=logical(valid(:));
hit=finite&any(abs(bounded-raw)>1e-12,2);
average=mean(raw,1);average_clip=mean(bounded,1);average_valid=all(valid);
M=struct('name',name,'seeds',seeds(:).','theta_raw',raw,'theta_clipped',bounded, ...
    'finite',finite,'valid',valid,'accepted',finite&valid&positive, ...
    'bound_hit',hit,'raw_positive_mass',positive,'ensemble_raw',average, ...
    'ensemble_clipped',average_clip,'ensemble_valid',average_valid, ...
    'ensemble_accepted',average_valid&&all(isfinite(average))&&average(1)>0, ...
    'ensemble_bound_hit',any(hit));
end

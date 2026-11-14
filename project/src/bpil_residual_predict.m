function out=bpil_residual_predict(results,obs)
%BPIL_RESIDUAL_PREDICT Frozen three-seed residual ensemble from observations.
% out=bpil_residual_predict(saved.results,obs) uses only cfg, scale and
% students{5,1:3} from the saved model bundle. It never reads payload labels,
% simulation truth, test predictions, or object identifiers.
% Requires the eight ordered probe_02 plateau measurements used in training.
% accepted means the observation/teacher checks passed, not certified accuracy.
% On rejection, theta and seed_predictions stay NaN; teacher is diagnostic only.
out=struct('theta',nan(1,3),'seed_predictions',nan(3,3), ...
    'seed_ids',nan(1,3),'teacher',[],'accepted',false,'reasons',{{}}, ...
    'reason','','error_message','','features',nan(1,13), ...
    'scope','Fixed nominal probe_02; planar mass/cx/cz; no hardware accuracy guarantee.');
try
    assert(isstruct(results)&&isscalar(results)&&all(isfield(results,{'cfg','scale','students'})), ...
        'bpil:ResidualBundle','Expected the saved results struct.');
    cfg=results.cfg;scale=double(results.scale(:).');B=double(cfg.ident.bounds);
    assert(numel(scale)==3&&all(isfinite(scale))&&all(scale>0)&& ...
        isequal(size(B),[3 2])&&all(isfinite(B),'all')&&all(B(:,2)>B(:,1)), ...
        'bpil:ResidualBundle','Invalid model scales or bounds.');
    assert(iscell(results.students)&&size(results.students,1)>=5&&size(results.students,2)==3, ...
        'bpil:ResidualBundle','Expected three residual-network seeds in row five.');
    assert(isscalar(cfg.ident.power_sigma_W)&&isfinite(cfg.ident.power_sigma_W)&&cfg.ident.power_sigma_W>0, ...
        'bpil:ResidualBundle','Invalid power residual scale.');
    for s=1:3
        learner=results.students{5,s};
        assert(isstruct(learner)&&all(isfield(learner,{'model','columns','selection'}))&& ...
            islogical(learner.columns)&&numel(learner.columns)==13&&any(learner.columns), ...
            'bpil:ResidualBundle','Invalid residual-network feature columns.');
        assert(strcmp(learner.selection.method,'physics_residual_nn'), ...
            'bpil:ResidualBundle','Row five is not the residual-network method.');
        out.seed_ids(s)=learner.selection.seed;
    end
catch err
    out=reject(out,{'invalid_model_bundle'},err.message);return
end
required={'plateau_q','plateau_P','plateau_sd_P','stationary','probe_id'};
if ~isstruct(obs)||~isscalar(obs)||~all(isfield(obs,required))
    out=reject(out,{'missing_plateau_observations'},'');return
end
if ~((ischar(obs.probe_id)||(isstring(obs.probe_id)&&isscalar(obs.probe_id)))&&strcmp(obs.probe_id,'probe_02'))
    out=reject(out,{'unsupported_probe'},'Expected the trained eight-pose probe_02 order.');return
end
q=obs.plateau_q;p=obs.plateau_P;sd=obs.plateau_sd_P;stationary=obs.stationary;
if ~(isnumeric(q)&&isreal(q)&&isequal(size(q),[8 4])&&all(isfinite(q),'all')&& ...
        isnumeric(p)&&isreal(p)&&isvector(p)&&numel(p)==8&&all(isfinite(p),'all')&& ...
        isnumeric(sd)&&isreal(sd)&&(isscalar(sd)||(isvector(sd)&&numel(sd)==8))&& ...
        all(isfinite(sd),'all')&&all(sd>=0,'all'))
    out=reject(out,{'invalid_plateau_measurements'},'Expected finite q(8,4), P(8), and nonnegative measured power SD.');return
end
if ~((isnumeric(stationary)||islogical(stationary))&&isreal(stationary)&& ...
        isvector(stationary)&&numel(stationary)==8&&all(isfinite(stationary),'all')&&all(stationary==1,'all'))
    out=reject(out,{'plateaus_not_all_stationary'},'');return
end
% Only this measurement whitelist is passed to the inverse teacher.
measured=struct('plateau_q',double(q),'plateau_P',double(p(:)), ...
    'plateau_sd_P',double(sd(:)),'stationary',logical(stationary(:)));
eta=struct('coefficients',cfg.legacy.power.coefficients);
try
    teacher=bpil_teacher(cfg,measured,eta,[]);out.teacher=teacher;
catch err
    out=reject(out,{'teacher_failed'},err.message);return
end
if ~teacher.accepted
    reasons={'teacher_rejected'};
    if isfield(teacher,'diagnostics')&&isfield(teacher.diagnostics,'reasons')
        reasons=[reasons,reshape(teacher.diagnostics.reasons,1,[])];
    end
    out=reject(out,reasons,'');return
end
try
    base=teacher.theta;
    predicted=bpil_predict_power(cfg,measured.plateau_q,base,eta);
    Xr=[base./scale,(measured.plateau_P-predicted).'/cfg.ident.power_sigma_W, ...
        teacher.rmse_W,teacher.validation_rmse_W];
    assert(isequal(size(Xr),[1 13])&&all(isfinite(Xr)), ...
        'bpil:ResidualFeatures','Invalid 13-dimensional residual features.');
    estimates=nan(3,3);
    for s=1:3
        learner=results.students{5,s};
        estimate=predict(learner.model,Xr(:,learner.columns)).*scale+base;
        assert(isequal(size(estimate),[1 3])&&all(isfinite(estimate)), ...
            'bpil:ResidualPrediction','Invalid network prediction.');
        % Match run_servo_signal_study exactly: clip each seed, then average.
        estimates(s,:)=min(max(estimate,B(:,1).'),B(:,2).');
    end
catch err
    out=reject(out,{'residual_prediction_failed'},err.message);return
end
out.features=Xr;out.seed_predictions=estimates;out.theta=mean(estimates,1);
out.accepted=true;out.reason='accepted';
end

function out=reject(out,reasons,message)
out.accepted=false;out.theta=nan(1,3);out.seed_predictions=nan(3,3);
out.reasons=reasons;out.reason=strjoin(reasons,'; ');out.error_message=message;
end

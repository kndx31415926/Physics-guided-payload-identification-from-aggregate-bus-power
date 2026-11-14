function row=pbd_row_diagnostics(record,cfg,pnnSpec,bundle,probe)
% Simulator truth is used ONLY for explanatory diagnostics, never prediction.
k=record.key;F=record.features;obs=record.obs;truth=record.truth;
physical=isempty(record.error)&&isstruct(truth)&&isfield(truth,'physical_success')&&truth.physical_success;
row=struct('trial_id',k.trial_id,'object_id',k.object_id,'cell_id',k.cell_id,'family',string(k.family), ...
    'severity',k.severity,'physical_success',physical,'feature_usable',F.usable,'accepted',physical&&F.accepted, ...
    'energy_pass',false,'stationary',false,'power_distortion_rms_W',NaN,'power_distortion_relative',NaN, ...
    'observed_power_residual_rms_W',NaN,'sampled_observed_power_residual_rms_W',NaN, ...
    'teacher_mass_error_g',NaN,'teacher_com_error_mm',NaN,'teacher_fit_rmse_W',NaN,'teacher_check_rmse_W',NaN, ...
    'condition_number',NaN,'singular_min_scaled',NaN,'feature_zmax13',NaN,'feature_zrms13',NaN, ...
    'max_temperature_C',NaN,'mean_bridge_loss_W',NaN,'mean_copper_loss_W',NaN, ...
    'plateau_speed_rms_max',NaN,'wall_s',record.wall_s);
if all(isfinite(F.base))
    row.teacher_mass_error_g=1000*abs(F.base(1)-k.theta(1));
    row.teacher_com_error_mm=1000*norm(F.base(2:3)-k.theta(2:3));
end
if F.usable
    row.teacher_fit_rmse_W=F.X13(12);row.teacher_check_rmse_W=F.X13(13);
    row.condition_number=10^F.Xaug(52)-1;row.singular_min_scaled=10^F.Xaug(51)-1;
    entry=bundle.methods(strcmp({bundle.methods.name},bundle.primary_method));m=entry.model.members{1};
    assert(numel(m.mu)==13&&numel(m.sigma)==13);z=(F.X13-m.mu)./m.sigma;
    row.feature_zmax13=max(abs(z));row.feature_zrms13=sqrt(mean(z.^2));
end
if isempty(obs)||isempty(truth),return;end
row.stationary=all(obs.stationary);row.energy_pass=truth.energy.pass;
temperature=truth.temperature_C(isfinite(truth.temperature_C));
speed=truth.plateau_speed_rms_rad_s(isfinite(truth.plateau_speed_rms_rad_s));
if ~isempty(temperature),row.max_temperature_C=max(temperature);end
if ~isempty(speed),row.plateau_speed_rms_max=max(speed);end
eta=struct('coefficients',cfg.legacy.power.coefficients);window=min(.3,cfg.sim.hold_s/2);
gap=nan(8,1);nominal=gap;observedGap=gap;allTail=false(size(truth.t));
for j=1:size(probe.poses,1)
    finish=cfg.sim.initial_hold_s+j*(cfg.sim.move_s+cfg.sim.hold_s);
    ix=truth.t>=finish-window-1e-10&truth.t<=finish+1e-10;allTail=allTail|ix;
    if ~any(ix),continue;end
    predicted=bpil_predict_power(cfg,truth.q(ix,:),k.theta,eta);
    nominal(j)=mean(predicted);gap(j)=mean(truth.P(ix)-predicted);
    predictedObserved=bpil_predict_power(cfg,obs.q(ix,:),k.theta,eta);
    observedGap(j)=mean(obs.P(ix)-predictedObserved);
end
if all(isfinite(gap))
    row.power_distortion_rms_W=sqrt(mean(gap.^2));
    row.power_distortion_relative=row.power_distortion_rms_W/max(sqrt(mean(nominal.^2)),eps);
    row.sampled_observed_power_residual_rms_W=sqrt(mean(observedGap.^2));
end
if all(isfinite(obs.plateau_q),'all')&&all(isfinite(obs.plateau_P))
    row.observed_power_residual_rms_W=sqrt(mean((obs.plateau_P-bpil_predict_power(cfg,obs.plateau_q,k.theta,eta)).^2));
end
if any(allTail),row.mean_bridge_loss_W=mean(truth.power_parts_W(allTail,3));row.mean_copper_loss_W=mean(truth.power_parts_W(allTail,4));end
end

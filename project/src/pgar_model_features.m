function f=pgar_model_features(cfg,obs,scale,probe_id)
%PGAR_MODEL_FEATURES Observation-only encoder, power and physical features.
% No labels, object IDs, simulated torques, or truth fields are read. The
% 128/40/13 features intentionally match run_servo_signal_study. A rejected
% teacher may have finite diagnostic features; accepted is reported separately.
if nargin<4,probe_id='probe_02';end
f=struct('schema','pgar_features_v1','usable',false,'teacher_accepted',false, ...
    'q',nan(1,128),'power',nan(1,40),'residual',nan(1,13), ...
    'base',nan(1,3),'teacher',[],'reasons',{{}},'error_message','');
try
    fields={'t','q','P','q_command','plateau_q','plateau_P','plateau_sd_P','stationary','probe_id'};
    assert(isstruct(obs)&&isscalar(obs)&&all(isfield(obs,fields)), ...
        'pgar:Observation','Required observation fields are missing.');
    assert(strcmp(string(obs.probe_id),string(probe_id)),'pgar:Probe','Wrong probe/order.');
    assert(numel(scale)==3&&all(isfinite(scale))&&all(scale>0),'pgar:Scale','Invalid scales.');
    t=double(obs.t(:));p=double(obs.P(:));q=double(obs.q);command=double(obs.q_command);
    assert(numel(t)>1&&isequal(size(q),[numel(t) 4])&&isequal(size(command),size(q))&& ...
        numel(p)==numel(t)&&all(diff(t)>0)&&all(isfinite([t p q command]),'all'), ...
        'pgar:Observation','Invalid synchronized observation arrays.');
    assert(isequal(size(obs.plateau_q),[8 4])&&numel(obs.plateau_P)==8&& ...
        numel(obs.stationary)==8&&all(obs.stationary(:)==1)&& ...
        all(isfinite(obs.plateau_q),'all')&&all(isfinite(obs.plateau_P(:))), ...
        'pgar:Observation','Expected eight finite stationary plateaus.');
    Fq=zeros(8,16);Fp=zeros(8,5);cycle=cfg.sim.move_s+cfg.sim.hold_s;
    for j=1:8
        finish=cfg.sim.initial_hold_s+j*cycle;start=finish-cycle;
        ix=t>start&t<=finish+1e-9;pl=t>=finish-.3&t<=finish+1e-9;
        assert(any(ix)&&sum(pl)>=2,'pgar:Observation','Missing segment or tail samples.');
        err=q(ix,:)-command(ix,:);tail=q(pl,:)-command(pl,:);
        Fq(j,:)=[mean(tail,1),sqrt(mean(err.^2,1)),mean(err,1),max(abs(err),[],1)];
        pv=p(ix);Fp(j,:)=[mean(p(pl)),std(p(pl)),mean(pv),std(pv),max(pv)];
    end
    measured=struct('plateau_q',double(obs.plateau_q),'plateau_P',double(obs.plateau_P(:)), ...
        'plateau_sd_P',double(obs.plateau_sd_P(:)),'stationary',logical(obs.stationary(:)));
    eta=struct('coefficients',cfg.legacy.power.coefficients);
    teacher=bpil_teacher(cfg,measured,eta,[]);base=double(teacher.theta(:).');
    predicted=bpil_predict_power(cfg,measured.plateau_q,base,eta);
    f.q=Fq(:).'/0.01;f.power=Fp(:).'/20;
    f.residual=[base./scale,(measured.plateau_P-predicted).'/cfg.ident.power_sigma_W, ...
        teacher.rmse_W,teacher.validation_rmse_W];
    f.base=base;f.teacher=teacher;f.teacher_accepted=logical(teacher.accepted);
    assert(all(isfinite([f.q f.power f.residual f.base])),'pgar:Features','Nonfinite features.');
    f.usable=true;
    if ~teacher.accepted,f.reasons=[{'teacher_rejected'},reshape(teacher.diagnostics.reasons,1,[])];end
catch err
    f.usable=false;f.reasons={err.identifier};f.error_message=err.message;
end
end

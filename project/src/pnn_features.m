function f=pnn_features(cfg,obs,spec)
%PNN_FEATURES Deployable observations only; fixed nominal calibration.
% Xaug = X13, scaled per-pose Jacobian, observed SD, regularized GN step,
% log singular values, and log condition. No IDs, conditions, or truth.
eta=struct('coefficients',cfg.legacy.power.coefficients);scale=double(spec.scale(:).');
f=struct('schema','pnn_features_v1','X13',nan(1,13),'Xaug',nan(1,52), ...
    'base',nan(1,3),'physics8',nan(1,3),'usable',false,'accepted',false, ...
    'physics8accepted',false,'physics8usable',false,'error',[],'physics8error',[]);
try
    F=pgar_model_features(cfg,obs,scale,spec.probe_id);
    assert(F.usable,'pnn:Features','Original physical features are unusable.');
    f.X13=F.residual;f.base=F.base;f.accepted=F.teacher_accepted;
    [pred,detail]=bpil_predict_power(cfg,double(obs.plateau_q),f.base,eta);
    sd=double(obs.plateau_sd_P(:));sigma=max(sd,cfg.ident.power_sigma_W);
    J=detail.jacobian.*scale./sigma;residual=(double(obs.plateau_P(:))-pred)./sigma;
    singular=svd(J,0);lambda=spec.gn_lambda;
    assert(isscalar(lambda)&&isfinite(lambda)&&lambda>0,'pnn:GNRegularization','Positive GN damping required.');
    step=(J.'*J+lambda*eye(3))\(J.'*residual);
    condition=singular(1)/max(singular(3),eps(max(1,singular(1))));
    f.Xaug=[f.X13,reshape(J.',1,24),sd.'/cfg.ident.power_sigma_W,step.',log10(1+singular.'),log10(1+condition)];
    assert(numel(f.Xaug)==52&&all(isfinite(f.Xaug)),'pnn:Features','Nonfinite enhanced features.');
    f.usable=true;
catch err,f.error=struct('identifier',err.identifier,'message',err.message);end
try
    P=pnn_physics8(cfg,obs,eta);f.physics8=P.theta;f.physics8accepted=P.accepted;
    f.physics8usable=all(isfinite(P.theta));f.physics8diagnostics=P;
catch err,f.physics8error=struct('identifier',err.identifier,'message',err.message);end
end

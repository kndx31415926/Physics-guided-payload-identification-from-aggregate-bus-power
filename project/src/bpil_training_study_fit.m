function model=bpil_training_study_fit(cfg,s,method,X,T,physical,seed)
rng(seed,'twister');B=cfg.ident.bounds;model=struct('method',method,'bounds',B,'seed',seed,'train_n',size(X,1),'backend','fitrnet');
switch method
    case 'direct'
        target=T;scale=cfg.parameter_scale;layers=s.direct_layers;iterations=s.iterations;input=X;
    case 'first_moments'
        target=[T(:,1),T(:,1).*T(:,2),T(:,1).*T(:,3)];
        scale=[B(1,2),B(1,2)*max(abs(B(2,:))),B(1,2)*max(abs(B(3,:)))];
        layers=s.direct_layers;iterations=s.iterations;input=X;
    case 'physics_residual'
        target=T-physical;scale=max(std(target,0,1),1e-5);
        layers=s.residual_layers;iterations=s.residual_iterations;
        input=[X,physical./cfg.parameter_scale];
    otherwise,error('bpil:Method','Unknown method');
end
model.scale=scale;model.physical_scale=cfg.parameter_scale;model.layers=layers;model.iterations=iterations;
model.regressor=fitrnet(input,target./scale,'LayerSizes',layers,'Activations','tanh', ...
    'Standardize',true,'Lambda',s.lambda,'IterationLimit',iterations,'Verbose',0);
end

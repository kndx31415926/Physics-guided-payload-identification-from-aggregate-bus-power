function D=bpil_training_study_data(cfg,probe,eta,n,seed,split)
% Fixed nominal electrical model; NO pretraining nuisance variation.
% Every row is one distinct object/complete eight-pose measurement episode.
rng(seed,'twister');q0=probe.poses;np=size(q0,1);
[g,Y]=bpil_static_design(cfg,q0);lo=cfg.ident.bounds(:,1).';span=diff(cfg.ident.bounds,1,2).';
theta=lo+rand(n,3).*span;theta(:,3)=.8*theta(:,3);
Q=zeros(np,4,n);P=zeros(n,np);X=zeros(n,np*4+4);
for k=1:n
    h=theta(k,1)*[1 theta(k,2:3)];tau=g;
    for j=1:3,tau=tau+Y(:,:,j)*h(j);end
    p=eta.coefficients(1)+sum(tau.^2.*eta.coefficients(2:5),2);
    q=q0+cfg.sensor.position_std_rad*randn(np,4);
    o=struct('plateau_q',q,'plateau_P',p+cfg.sensor.power_std_W/sqrt(cfg.sensor.plateau_samples)*randn(np,1));
    Q(:,:,k)=q;P(k,:)=o.plateau_P.';X(k,:)=bpil_features(o,eta);
end
object_id=cellstr(compose('%s_%06d',split,(1:n).'));
D=struct('theta',theta,'X',X,'Q',Q,'P',P,'object_id',{object_id}, ...
    'seed',seed,'split',split,'probe_id',probe.id,'nominal_q',q0, ...
    'source','fixed_equilibrium_supervised_simulation', ...
    'signal_scope','Encoder variations are iid sensor noise independent of payload; no servo position error information.');
end

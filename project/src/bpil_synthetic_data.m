function D=bpil_synthetic_data(cfg,probes,eta,n,seed)
% Offline supervised equilibrium bootstrap, distinct from servo experiments.
rng(seed,'twister');np=numel(probes);N=size(probes(1).poses,1);
G=cell(1,np);Y=G;
for j=1:np,[G{j},Y{j}]=bpil_static_design(cfg,probes(j).poses);end
X=[];T=zeros(n,3);ids=zeros(n,1);
for k=1:n
    j=mod(k-1,np)+1;
    th=cfg.ident.bounds(:,1).'+rand(1,3).*diff(cfg.ident.bounds,1,2).';
    % Independent Cartesian parameter draws, including deliberately varying COM.
    th(3)=.8*th(3);mphi=[th(1),th(1)*th(2),th(1)*th(3)];
    tau=G{j};for h=1:3,tau=tau+Y{j}(:,:,h)*mphi(h);end
    e=eta;
    % Modest pretraining variability, with actual plant drift tested separately.
    e.coefficients(3:5)=eta.coefficients(3:5).*(.90+.20*rand(1,3));
    e.coefficients(1)=eta.coefficients(1)+.10*randn;
    p=e.coefficients(1)+sum(tau.^2.*e.coefficients(2:5),2);
    o=struct('plateau_q',probes(j).poses+cfg.sensor.position_std_rad*randn(N,4), ...
        'plateau_P',p+cfg.sensor.power_std_W/sqrt(cfg.sensor.plateau_samples)*randn(N,1), ...
        'plateau_sd_P',cfg.sensor.power_std_W*ones(N,1),'stationary',true(N,1), ...
        'probe_id',probes(j).id);
    x=bpil_features(o,e);if isempty(X),X=zeros(n,numel(x));end
    X(k,:)=x;T(k,:)=th;ids(k)=j;
end
D=struct('X',X,'theta',T,'probe_id',ids,'seed',seed, ...
    'source','offline_supervised_equilibrium_simulation');
end

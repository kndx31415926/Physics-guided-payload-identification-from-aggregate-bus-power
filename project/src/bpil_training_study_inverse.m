function out=bpil_training_study_inverse(cfg,D,eta,s)
% Fixed two-start bounded physical inverse, fit using all eight measured poses.
% No access to D.theta, object IDs, labels, or learner outputs for optimization.
% No train/holdout split within an episode: this is an all-observation baseline,
% not the separate gated six-pose teacher used by run_feasibility.
started=tic;N=size(D.P,1);np=size(D.Q,1);B=cfg.ident.bounds;lo=B(:,1).';span=diff(B,1,2).';
q=reshape(permute(D.Q,[1 3 2]),np*N,4);
fprintf('Physical inverse %s: preparing %d measured poses.\n',D.split,size(q,1));
[G,Yall]=bpil_static_design(cfg,q);c=eta.coefficients;
theta=zeros(N,3);rmse=zeros(N,1);flags=zeros(N,1);bound_count=zeros(N,1);
opt=optimoptions('lsqnonlin','Display','off','SpecifyObjectiveGradient',true, ...
    'MaxIterations',s.inverse_max_iterations,'FunctionTolerance',1e-9, ...
    'StepTolerance',1e-9,'OptimalityTolerance',1e-8);
for k=1:N
    rows=(k-1)*np+(1:np);g=G(rows,:);Y=Yall(rows,:,:);p=D.P(k,:).';
    best=Inf;bestflag=-Inf;bestz=.5*ones(1,3);
    for j=1:size(s.inverse_starts,1)
        [z,cost,~,flag]=lsqnonlin(@objective,s.inverse_starts(j,:),zeros(1,3),ones(1,3),opt);
        if isfinite(cost)&&all(isfinite(z))&&cost<best,best=cost;bestz=z;bestflag=flag;end
    end
    theta(k,:)=lo+bestz.*span;flags(k)=bestflag;rmse(k)=sqrt(best/np)*cfg.ident.power_sigma_W;
    bound_count(k)=sum(bestz<1e-7|bestz>1-1e-7);
    if mod(k,1000)==0,fprintf('Inverse %s %d/%d, %.1fs.\n',D.split,k,N,toc(started));end
end
out=struct('theta',theta,'converged',flags>0,'exitflag',flags,'fit_rmse_W',rmse, ...
    'bound_count',bound_count,'elapsed_s',toc(started),'initialization','Two fixed normalized starts, no truth.', ...
    'scope','All measured poses; fixed search budget; no global optimality certificate.');
    function [r,J]=objective(z)
        t=lo+z.*span;h=[t(1),t(1)*t(2),t(1)*t(3)];tau=g;
        for a=1:3,tau=tau+Y(:,:,a)*h(a);end
        pred=c(1)+sum(tau.^2.*c(2:5),2);dh=[1 0 0;t(2) t(1) 0;t(3) 0 t(1)];J=zeros(np,3);
        for a=1:3
            dtau=zeros(np,4);for b=1:3,dtau=dtau+Y(:,:,b)*dh(b,a);end
            J(:,a)=2*sum(tau.*c(2:5).*dtau,2)*span(a)/cfg.ident.power_sigma_W;
        end
        r=(pred-p)/cfg.ident.power_sigma_W;
    end
end

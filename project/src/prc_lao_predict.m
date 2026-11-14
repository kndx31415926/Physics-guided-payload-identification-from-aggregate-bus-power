function pred=prc_lao_predict(model,D,idx,mode)
%PRC_LAO_PREDICT Observation/design-only T or T-A inference.
% Never accesses D.theta, D.tau_label, or truth. Per-seed raw estimates use
% unregularized weighted SVD. Training's tiny ridge is NOT used here.
% theta_raw/phi_raw:Nx3xS; tau/weights:Nx8x4xS; diagnostics:NxS.
% theta_clipped clips each seed to declared bounds; theta is their equal mean.
% Clipping is not constrained WLS and does not imply reliable identification.
if nargin<4,mode='attention';end
assert(ismember(string(mode),["uniform","attention"]),'prc:LaoMode','Unknown prediction mode.');
assert(strcmp(model.schema,'prc_lao_adaptation_v1'),'prc:LaoModel','Invalid model schema.');
idx=idx(:);N=numel(idx);S=numel(model.learners);B=model.spec.bounds;
assert(all(ismember({'state','g0','Y','usable'},fieldnames(D))), ...
    'prc:LaoData','Inference needs state/g0/Y/usable only.');
pred=struct('theta_raw',nan(N,3,S),'phi_raw',nan(N,3,S), ...
    'theta_clipped',nan(N,3,S),'theta',nan(N,3),'theta_raw_mean',nan(N,3), ...
    'tau',nan(N,8,4,S),'weights',nan(N,8,4,S),'rank',zeros(N,S), ...
    'condition',inf(N,S),'valid',false(N,S),'available',false(N,S), ...
    'mode',char(mode),'seeds',model.seeds,'ridge',0,'training_ridge',model.spec.ridge);
if isfield(D,'object_id'),pred.object_id=D.object_id(idx);else,pred.object_id=idx;end
state=double(D.state(idx,:,:,:));usable=logical(D.usable(idx));
finite=all(reshape(isfinite(state),N,[]),2)& ...
    all(reshape(isfinite(D.g0(idx,:,:)),N,[]),2)& ...
    all(reshape(isfinite(D.Y(idx,:,:,:)),N,[]),2);
directions=state(:,:,:,3:4);
direction_valid=all(reshape(directions==0|directions==1,N,[]),2)& ...
    all(reshape(sum(directions,4)<=1,N,[]),2);
chosen=find(usable&finite&direction_valid);if isempty(chosen),return,end
X=dlarray(prc_lao_inputs(state(chosen,:,:,:),model.normalization));
for s=1:S
    learner=model.learners{s};
    tau=double(extractdata(prc_lao_forward(learner.torque,X,'torque')))*model.normalization.torque_scale;
    if strcmp(mode,'attention')
        assert(~isempty(learner.attention),'prc:LaoAttention','Attention stage is missing.');
        weights=double(extractdata(prc_lao_forward(learner.attention,X,'attention')));
    else
        weights=ones(size(tau))/4;
    end
    tau=permute(reshape(tau,4,8,numel(chosen)),[3 2 1]);
    weights=permute(reshape(weights,4,8,numel(chosen)),[3 2 1]);
    for k=1:numel(chosen)
        n=chosen(k);i=idx(n);t=reshape(tau(k,:,:),8,4);w=reshape(weights(k,:,:),8,4);
        pred.tau(n,:,:,s)=t;pred.weights(n,:,:,s)=w;
        if ~all(isfinite(t),'all')||~all(isfinite(w),'all')||any(w<0,'all'),continue,end
        A=reshape(double(D.Y(i,:,:,:)),32,3);r=t-reshape(double(D.g0(i,:,:)),8,4);
        sw=sqrt(w(:));C=A.*sw;d=r(:).*sw;[U,Vsing,V]=svd(C,0);sigma=diag(Vsing);
        tolerance=max(size(C))*eps(max([1;sigma]));rankC=sum(sigma>tolerance);
        pred.rank(n,s)=rankC;
        if rankC<3,continue,end
        pred.condition(n,s)=sigma(1)/sigma(3);
        phi=(V*((U.'*d)./sigma)).';theta=[phi(1),nan,nan];
        if abs(phi(1))>model.spec.mass_division_floor,theta(2:3)=phi(2:3)/phi(1);end
        pred.phi_raw(n,:,s)=phi;pred.theta_raw(n,:,s)=theta;
        pred.available(n,s)=all(isfinite(theta));
        pred.valid(n,s)=pred.available(n,s)&&phi(1)>model.spec.mass_division_floor&& ...
            pred.condition(n,s)<=model.spec.max_condition;
        clipped=min(max(theta,B(:,1).'),B(:,2).');
        % MATLAB min/max may omit NaN; bounds must never fill missing values.
        clipped(~isfinite(theta))=NaN;pred.theta_clipped(n,:,s)=clipped;
    end
end
pred.theta=mean(pred.theta_clipped,3);pred.theta_raw_mean=mean(pred.theta_raw,3);
pred.phi=mean(pred.phi_raw,3);
pred.scope='Lao architecture adapted to fixed-frame 4R/PID/eight poses and planar m,cx,cz; no sensor-torque labels';
end

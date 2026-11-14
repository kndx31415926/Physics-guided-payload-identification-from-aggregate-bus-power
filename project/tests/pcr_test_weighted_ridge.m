function report=pcr_test_weighted_ridge()
%PCR_TEST_WEIGHTED_RIDGE Objective, preprocessing and offline parity contracts.
root=fileparts(fileparts(mfilename('fullpath')));addpath(fullfile(root,'src'));
before=rng;X=reshape(sin(1:240),40,6)+reshape(cos(1:40),40,1)*(1:6)/5;
Y=[2+X(:,1)-.3*X(:,3),-1+.6*X(:,2),X(:,4)-.7*X(:,5)];lambda=.001;
original=psf_ridge('fit',X,Y,lambda);
[uniform,u]=pcr_weighted_ridge(X,Y,ones(40,1),original);
pred=psf_ridge('predict',original,X);upred=psf_ridge('predict',uniform,X);
assert(max(abs(pred-upred),[],'all')<1e-11,'pcr:Test','Uniform weights do not reproduce PSF.');
assert(isequaln(original.mu,uniform.mu)&&isequaln(original.sigma,uniform.sigma)&& ...
    original.lambda==uniform.lambda,'pcr:Test','Frozen preprocessing changed.');
w=ones(40,1);w(31:40)=30;
[weighted,a]=pcr_weighted_ridge(X,Y,w,original);
[scaled,b]=pcr_weighted_ridge(X,Y,17*w,original);
assert(max(abs(weighted.beta-scaled.beta),[],'all')<1e-11&& ...
    max(abs(weighted.intercept-scaled.intercept))<1e-11, ...
    'pcr:Test','Global weight scaling changed the normalized objective solution.');
assert(a.relative_normal_equation_residual<1e-12&&a.weighted_intercept_gradient_norm<1e-12, ...
    'pcr:Test','Weighted ridge does not solve its stated normal equations.');
% Independently solve the weighted augmented design with unpenalized intercept.
Z=(X-original.mu)./original.sigma;D=[ones(40,1) Z];P=diag([0 ones(1,6)]);
direct=(D.'*(D.*w)/sum(w)+lambda*P)\(D.'*(Y.*w)/sum(w));
assert(max(abs(direct-[weighted.intercept;weighted.beta]),[],'all')<1e-10, ...
    'pcr:Test','Centered and augmented weighted ridge solutions disagree.');
[shift,~]=pcr_weighted_ridge(X,Y+7,w,original);
assert(max(abs(shift.beta-weighted.beta),[],'all')<1e-10&& ...
    max(abs(shift.intercept-weighted.intercept-7))<1e-10, ...
    'pcr:Test','The intercept was penalized or target centering is wrong.');
% Integer weights have the same objective as replicated rows in FIXED coordinates.
indices=repelem((1:40).',w);[repeated,~]=pcr_weighted_ridge(X(indices,:),Y(indices,:),ones(sum(w),1),original);
assert(max(abs(repeated.beta-weighted.beta),[],'all')<1e-10&& ...
    max(abs(repeated.intercept-weighted.intercept))<1e-10,'pcr:Test','Weight replication mismatch.');
changed=X;changed(40,:)=changed(40,:)+100;
[fixed,~]=pcr_weighted_ridge(changed,Y,w,original);
assert(isequal(fixed.mu,original.mu)&&isequal(fixed.sigma,original.sigma),'pcr:Test','Online observations changed fixed scaling.');
bad=false;try,pcr_weighted_ridge(X,Y,zeros(40,1),original);catch e,bad=strcmp(e.identifier,'pcr:Ridge');end
assert(bad,'pcr:Test','Zero total fitting weight was accepted.');
assert(isequaln(before,rng),'pcr:Test','Deterministic ridge touched RNG.');
report=struct('passed',true,'groups',9,'uniform_prediction_max_abs_error',max(abs(pred-upred),[],'all'), ...
    'uniform_fit',u,'weighted_fit',a,'scaled_fit',b);
fprintf('PCR weighted ridge contracts passed: 9 groups.\n');
end

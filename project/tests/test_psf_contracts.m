function info=test_psf_contracts()
% Meaningful input-isolation, ridge, rejection and matched-reference checks.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root);cfg=startup_bpil();
S=load(fullfile(root,'results','prc_holdout_20261029_v1','trials','trial_000003.mat'),'record');obs=S.record.obs;
f=psf_features(obs);assert(f.usable&&numel(f.x)==40&&numel(f.x48)==48);
assert(isequal(reshape(f.x48,6,8).',[obs.plateau_q obs.plateau_P(:) obs.plateau_sd_P(:)]));
tainted=obs;tainted.truth=rand(2);tainted.object_id=999;tainted.theta=[999 888 777];
tainted.q=nan(size(obs.q));tainted.P=nan(size(obs.P));tainted.q_command=rand(size(obs.q_command));
g=psf_features(tainted);assert(isequaln(f,g),'Transient/forbidden labels changed steady features.');
changed=obs;changed.plateau_sd_P=obs.plateau_sd_P+.1;h=psf_features(changed);
assert(isequal(f.x,h.x)&&~isequal(f.x48,h.x48),'Noise summaries missing from full-input control.');
bad=obs;bad.stationary(2)=false;assert(~psf_features(bad).usable);
bad=obs;bad.plateau_P(4)=NaN;assert(~psf_features(bad).usable);
before=rng;X=reshape(sin(1:100),20,5);Y=[X(:,1)+2,3*X(:,2)-5,X(:,3)-X(:,4)];
model=psf_ridge('fit',X,Y,.001);p=psf_ridge('predict',model,X);
assert(isequaln(before,rng)&&mean((p-Y).^2,'all')<.001,'Ridge failed or leaked RNG.');
shift=psf_ridge('fit',X+100,Y+7,.001);assert(max(abs(psf_ridge('predict',shift,X+100)-p-7),[],'all')<1e-10,'Intercept/centering mismatch.');
assert(all(isfinite(psf_ridge('predict',psf_ridge('fit',[X ones(20,1)],Y,.1),[X ones(20,1)])),'all'));
eta=cfg.legacy.power.coefficients;assert(numel(eta)==13);
info=struct('pass',true,'checks',8,'scope','Steady input isolation, sd feature inclusion, rejection, ridge determinism and affine intercept.');
fprintf('PSF CONTRACT TEST PASS: 8 checks.\n');
end

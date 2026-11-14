function evidence=prc_lao_regression_smoke(outdir)
%PRC_LAO_REGRESSION_SMOKE Real TRAIN/VALIDATION-only integration regression.
% Never opens any trial/test directory. The source is the failed run's cached
% 600 train +150 validation objects, preserved read-only.
if nargin<1,outdir='C:/new/results/prc_lao_regression_smoke_v1';end
startup_bpil();maxNumCompThreads(1);
saved=load('C:/new/results/prc_pipeline_smoke_v1/training_data.mat','D');D=saved.D;
assert(~any(string(D.split)=="test"),'Regression fixture must contain no test rows.');
tr=find(string(D.split)=="train"&D.usable);tr=tr(1:12);
va=find(string(D.split)=="validation"&D.usable);va=va(1:4);
assert(any(sum(D.state([tr;va],:,:,3:4),4)==0,'all'),'Real unknown directions were not covered.');
spec=struct('network_seeds',830101,'torque_epochs',2,'attention_epochs',1, ...
    'torque_batch',256,'attention_batch',32,'bounds',D.bounds);
if ~exist(outdir,'dir'),mkdir(outdir);end
diary(fullfile(outdir,'smoke.log'));cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
[model,info]=prc_lao_train(D,tr,va,spec,fullfile(outdir,'training'));
assert(info.complete&&all(info.last_gradient_norms>0,'all'));
assert(isfolder(fullfile(outdir,'training','training_source')));
assert(~isfolder(fullfile(outdir,'training','source_snapshot')));
without=rmfield(D,{'theta','tau_label','split'});
p=prc_lao_predict(model,without,va,'attention');
assert(all(isfinite(p.theta_raw),'all'));
% Unknown input channels survive normalization with no invented direction.
X=prc_lao_inputs(D.state(va,:,:,:),model.normalization);
raw=reshape(permute(double(D.state(va,:,:,:)),[4 3 2 1]),4,4,[]);
assert(isequal(X(3:4,:,:),raw(3:4,:,:)));
bad=D;bad.state(tr(1),2,1,3:4)=1;rejected=false;
try
    prc_lao_train(bad,tr,va,spec,fullfile(outdir,'invalid_direction'));
catch err
    rejected=strcmp(err.identifier,'prc:LaoDirection');
end
assert(rejected,'[1,1] must be rejected by training.');
bad=without;bad.state(va(1),2,1,3:4)=1;
badpred=prc_lao_predict(model,bad,va(1),'uniform');
assert(~badpred.available&&all(isnan(badpred.theta)),'[1,1] inference should be unavailable.');
% Manufacture a zero-residual inference fixture to exercise undefined COM.
zero=model;zero.learners{1}.torque.h3w=dlarray(zeros(size(zero.learners{1}.torque.h3w)));
zero.learners{1}.torque.h3b=dlarray(zeros(4,1));
zeroD=struct('state',D.state(va(1),:,:,:),'g0',zeros(1,8,4), ...
    'Y',D.Y(va(1),:,:,:),'usable',true,'object_id',-1);
nanpred=prc_lao_predict(zero,zeroD,1,'uniform');
assert(nanpred.theta_raw(1,1)==0&&all(isnan(nanpred.theta_raw(1,2:3)))&& ...
    all(isnan(nanpred.theta_clipped(1,2:3)))&&all(isnan(nanpred.theta(1,2:3)))&& ...
    ~nanpred.available&&~nanpred.valid,'Clipping must not turn undefined COM into bounds.');
[resumed,resumeinfo]=prc_lao_train(D,tr,va,spec,fullfile(outdir,'training'));
q=prc_lao_predict(resumed,without,va,'attention');assert(isequaln(p.theta_raw,q.theta_raw));
evidence=struct('complete',true,'scope','Real TRAIN/VALIDATION regression only; no test records read', ...
    'train_objects',numel(tr),'validation_objects',numel(va), ...
    'unknown_direction_count',sum(sum(D.state([tr;va],:,:,3:4),4)==0,'all'), ...
    'invalid_direction_rejected',rejected,'undefined_com_preserved',true, ...
    'separate_training_source',true,'resume_exact',true,'elapsed_s',info.elapsed_s, ...
    'resume_s',resumeinfo.elapsed_s,'gradient_norms',info.last_gradient_norms);
prc_lao_atomic_save(fullfile(outdir,'REGRESSION_EVIDENCE.mat'),struct('evidence',evidence));
disp(evidence);fprintf('Real train/validation Lao regression PASSED.\n');
end


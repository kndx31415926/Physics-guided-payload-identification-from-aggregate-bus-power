function report=pnn_test_data(mode)
%PNN_TEST_DATA Contracts plus optional one-episode full-servo smoke.
if nargin<1,mode='quick';end
maxNumCompThreads(1); %#ok<MAXNCT>
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
folder=fullfile(root,'tmp',['pnn_data_test_' char(javaMethod('randomUUID','java.util.UUID'))]);mkdir(folder);
cfg=bpil_config(root);spec=struct('run_id','pnn_test_fixture','counts',[8 4 2], ...
    'split_seeds',[2467101 2467102 2467103],'sensor_seed_base',24680000, ...
    'communication_seed_base',24700000,'nuisance_seed_base',24720000,'object_id_base',9000000, ...
    'range_lower',[.08 .05 -.018],'range_span',[.14 .14 .036],'probe_index',2,'probe_id','probe_02', ...
    'workers',1,'scale',[.14 .14 .036],'gn_lambda',.001);
if strcmp(mode,'parallel'),spec.workers=6;spec.counts=[8 8 2];end
plan=pnn_plan(cfg,spec);again=pnn_plan(cfg,spec);
assert(isequaln(plan,again)&&height(plan.objects)==sum(spec.counts)&& ...
    height(plan.manifest)==sum(spec.counts(1:2))+4*spec.counts(3),'pnn:Test','Plan reproducibility/count failure.');
for split=["train","validation"],n=sum(plan.manifest.split==split);for c=1:4,assert(sum(plan.manifest.split==split&plan.manifest.condition_index==c)==n/4);end,end
for id=plan.objects.object_id(plan.objects.split=="test").',assert(sum(plan.manifest.object_id==id)==4);end
save(fullfile(folder,'data_plan.mat'),'-struct','plan','-v7.3');pnn_load_plan(folder,cfg,spec);
bad=spec;bad.scale(1)=bad.scale(1)+.01;must_fail(@()pnn_load_plan(folder,cfg,bad),'pnn:PlanMismatch');
badfolder=fullfile(folder,'changed_plan');mkdir(badfolder);changed=plan;changed.manifest.sensor_seed(1)=changed.manifest.sensor_seed(1)+1;
save(fullfile(badfolder,'data_plan.mat'),'-struct','changed','-v7.3');must_fail(@()pnn_load_plan(badfolder,cfg,spec),'pnn:PlanHash');
must_fail(@()pnn_test_gate(folder,plan),'pnn:TestLocked');
% Sealed commits, interrupted renames, rejection of mutation/unsealed files.
payload=struct('sentinel',[1 2 3]);a=fullfile(folder,'a.mat');pnn_checkpoint('write',a,payload);
[S,seal]=pnn_checkpoint('read',a);assert(isequaln(S,payload));must_fail(@()pnn_checkpoint('write',a,payload),'pnn:CheckpointExists');
b=fullfile(folder,'b.mat');pnn_checkpoint('write',b,payload);movefile([b '.sha256.json'],[b '.seal_pending.json']);
[S,~]=pnn_checkpoint('read',b);assert(isequaln(S,payload)&&isfile([b '.sha256.json']));
c=fullfile(folder,'c.mat');[~,cs]=pnn_checkpoint('write',c,payload);movefile(c,cs.temporary);movefile([c '.sha256.json'],[c '.seal_pending.json']);
[S,~]=pnn_checkpoint('read',c);assert(isequaln(S,payload)&&isfile(c));
unsealed=fullfile(folder,'unsealed.mat');save(unsealed,'payload');must_fail(@()pnn_checkpoint('read',unsealed),'pnn:CheckpointUnsealed');
fid=fopen(a,'a');fwrite(fid,uint8(0));fclose(fid);must_fail(@()pnn_checkpoint('read',a),'pnn:CheckpointChanged');
% Exact static measurements identify all parameters in the full-eight fit.
theta=[.153 .121 .004];obs=static_fixture(cfg,plan.probe,theta);F=pnn_features(cfg,obs,spec);
assert(F.usable&&F.physics8usable&&norm(F.physics8-theta)<1e-5&&numel(F.Xaug)==52, ...
    'pnn:Test','Exact physical fit or feature schema failed.');
tainted=obs;tainted.theta_true=[99 88 77];tainted.object_id=-1;tainted.condition='forbidden';tainted.truth=struct('torque',1e9);
assert(isequaln(F,pnn_features(cfg,tainted,spec)),'pnn:Test','Truth/nuisance fields changed observable features.');
% Invalid physical episodes are saved once and reused without rerunning.
expected=pnn_expected_record(plan,1);broken=cfg;broken.sim.dt=.002;
failurefile=fullfile(folder,'failure.mat');status=pnn_trial(failurefile,broken,plan.probe,plan.conditions(1),expected);
[~,before]=pnn_checkpoint('read',failurefile);status2=pnn_trial(failurefile,cfg,plan.probe,plan.conditions(1),expected);
[~,after]=pnn_checkpoint('read',failurefile);
assert(status.exception&&isequaln(status,status2)&&strcmp(before.sha256,after.sha256),'pnn:Test','A failed committed record was retried or altered.');
% Assemble a complete train-only synthetic cache through the public API.
mkdir(fullfile(folder,'trials'));
for i=find(plan.manifest.split=="train").'
    record=pnn_expected_record(plan,i);record.obs=static_fixture(cfg,plan.probe,record.theta_true);
    record.truth=struct('physical_success',true);record.error=[];record.complete=true;record.completed_utc='fixture';
    pnn_checkpoint('write',fullfile(folder,'trials',sprintf('trial_%06d.mat',i)),struct('record',record));
end
if strcmp(mode,'parallel')
    assert(isempty(gcp('nocreate')),'pnn:TestPool','Parallel smoke requires no existing pool.');
    pool=parpool(parcluster('Processes'),6);pool_cleanup=onCleanup(@()delete(pool)); %#ok<NASGU>
end
D=pnn_cache_dataset(folder,cfg,spec,'train');D2=pnn_cache_dataset(folder,cfg,spec,'train');
assert(isequaln(D,D2)&&size(D.Xaug,1)==8&&all(D.usable)&&all(D.split=="train")&&numel(D.feature_names)==52, ...
    'pnn:Test','Cache resume/group/feature mismatch.');
assert(isequaln(D.Xaug(:,1:13),D.X13),'pnn:Test','Augmented input does not retain the exact original thirteen features.');
must_fail(@()pnn_cache_dataset(folder,cfg,spec,'test'),'pnn:TestLocked');
info=pnn_generate_data(folder,cfg,spec,'train');assert(info.generated_this_call==0&&info.skipped_existing==8,'pnn:Test','Generation resume did not preserve all fixtures.');
info2=pnn_generate_data(folder,cfg,spec,'train');assert(info2.generated_this_call==0);
fullservo=[];
if strcmp(mode,'fullservo')
    id=find(plan.manifest.split=="validation",1);expected=pnn_expected_record(plan,id);
    file=fullfile(folder,'trials',sprintf('trial_%06d.mat',id));t=tic;
    fullservo=pnn_trial(file,cfg,plan.probe,plan.conditions(id),expected);fullservo.elapsed_s=toc(t);
    assert(~fullservo.exception,'pnn:Test','Full-servo smoke raised an exception.');
elseif strcmp(mode,'parallel')
    t=tic;info=pnn_generate_data(folder,cfg,spec,'validation');fullservo=info;fullservo.elapsed_s=toc(t);
    assert(info.generated_this_call==8&&info.failed==0,'pnn:Test','Parallel full-servo generation failed.');
    V=pnn_cache_dataset(folder,cfg,spec,'validation');V2=pnn_cache_dataset(folder,cfg,spec,'validation');
    assert(isequaln(V,V2)&&all(V.usable)&&isequaln(V.Xaug(:,1:13),V.X13),'pnn:Test','Parallel feature/cache resume failed.');
    before=V.record_sha256;info=pnn_generate_data(folder,cfg,spec,'validation');
    assert(info.generated_this_call==0&&info.skipped_existing==8&&isequaln(before,V2.record_sha256), ...
        'pnn:Test','Parallel resume changed already committed data.');
elseif ~strcmp(mode,'quick'),error('pnn:TestMode','Unknown test mode.');end
% A positive model lock is tied to both the bundle bytes and the plan.
bundle=fullfile(folder,'test_bundle.mat');pnn_checkpoint('write',bundle,struct('bundle',struct('fixture',true)));
lock=struct('bundle_path',bundle,'bundle_sha256',prc_file_hash(bundle),'plan_signature',plan.plan_signature,'selection_uses_test',false);
prc_write_json(fullfile(folder,'MODEL_LOCK.json'),lock);pnn_test_gate(folder,plan);
lock.bundle_sha256=repmat('0',1,64);prc_write_json(fullfile(folder,'MODEL_LOCK.json'),lock);
must_fail(@()pnn_test_gate(folder,plan),'pnn:TestLockMismatch');
report=struct('passed',true,'groups',15,'folder',folder,'feature_count',52, ...
    'plan_signature',plan.plan_signature,'fullservo',fullservo,'original_seal_example',seal.sha256);
prc_write_json(fullfile(folder,'test_report.json'),report);fprintf('PNN data contracts PASS: 15 groups; %s\n',folder);
end
function obs=static_fixture(cfg,probe,theta)
t=(.01:.01:cfg.sim.initial_hold_s+8*(cfg.sim.move_s+cfg.sim.hold_s)).';q=zeros(numel(t),4);P=zeros(numel(t),1);
eta=struct('coefficients',cfg.legacy.power.coefficients);power=bpil_predict_power(cfg,probe.poses,theta,eta);
for i=1:numel(t)
    pose=max(1,min(8,floor((t(i)-cfg.sim.initial_hold_s-1e-9)/(cfg.sim.move_s+cfg.sim.hold_s))+1));
    q(i,:)=probe.poses(pose,:);P(i)=power(pose);
end
obs=struct('t',t,'q',q,'P',P,'q_command',q,'plateau_q',probe.poses,'plateau_P',power, ...
    'plateau_sd_P',.03*ones(8,1),'stationary',true(8,1),'probe_id',probe.id);
end
function must_fail(f,id)
failed=false;try,f();catch err,failed=strcmp(err.identifier,id);if ~failed,rethrow(err);end,end
assert(failed,'pnn:Test','Expected failure %s was not raised.',id);
end

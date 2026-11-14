function report=test_pcu_contract(iterations)
if nargin<1,iterations=1;end
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
for k=[1 2 4]
    actual=find(arrayfun(@(b)pcu_schedule(b,k),1:4));assert(isequal(actual,1:k:4),'pcu:Test','Schedule differs.');
end
assert(isequal(arrayfun(@(k)sum(arrayfun(@(b)pcu_schedule(b,k),1:3)),[1 2 4]),[3 2 1]),'pcu:Test','Effective updates differ.');
for name={'stationary','electrical','mechanical','combined'}
    assert(isequaln(pcu_drift(0,name{1}),pra_drift(0,name{1}))&&isequaln(pcu_drift(1,name{1}),pra_drift(1,name{1})),'pcu:Test','Endpoints changed.');
end
d=pcu_drift(.5,'electrical');assert(numel(unique(d.holding_scale(2:4)))==3,'pcu:Test','Unequal intermediate axis progress required.');
source=fullfile(root,'results','pra_continual_20261030_v1');C=load(fullfile(source,'configuration.mat'));spec=C.spec;
spec.online_seeds=[970101 970102 970103];spec.online_iterations=iterations;spec.pcu_keep_history=true;spec.pcu_use_offline=true;
state=prb_online_init(C.cfg,spec);P=load(fullfile(source,'data_plan.mat'),'manifest');M=P.manifest;
B=M(string(M.scenario)=="stationary"&M.stream_index==1&M.block==1,:);
[anchor,train,valid]=inputs(source,B);
[old,eo]=prb_online_update(state,anchor,train,valid,'parity_block1');
[new,en]=pcu_online_update(state,anchor,train,valid,'parity_block1');
% fitrnet stores wall-clock training metadata; compare deployed function and
% calibration/counters, rather than byte equality of timed model objects.
for name=fieldnames(old.systems).'
    a=old.systems.(name{1});b=new.systems.(name{1});
    assert(isequaln(a.eta,b.eta)&&a.deployed_updates==b.deployed_updates&& ...
        a.eta_updates==b.eta_updates&&a.network_updates==b.network_updates,'pcu:Test','Main PCU deployment decisions differ from PRB.');
end
for name={'gated_calibration','gated_full'}
    assert(isequaln(eo.systems.(name{1}).candidates,en.systems.(name{1}).candidates),'pcu:Test','Main candidate/gate computation differs from PRB.');
end
[again,repeated]=pcu_online_update(new,anchor,train,valid,'parity_block1');assert(repeated.already_processed&&isequaln(again,new),'pcu:Test','Not idempotent.');
bad=train;bad(1).role='eval';caught=false;
try,pcu_online_update(state,anchor,bad,valid,'bad_role');catch err,caught=strcmp(err.identifier,'prb:ReferenceRole');end
assert(caught,'pcu:Test','Unknown role entered update.');
Q=B(string(B.role)=="eval",:);D=load(fullfile(source,'trials',sprintf('trial_%06d.mat',Q.trial_id(1))),'record');
p=pcu_predict(state,D.record.obs);o=D.record.obs;o.theta_true=[99 99 99];o.truth=struct('impossible',99);
assert(isequaln(pcu_predict(old,D.record.obs),pcu_predict(new,D.record.obs)),'pcu:Test','Post-update main four predictions differ from PRB.');
assert(isequaln(p,pcu_predict(state,o)),'pcu:Test','Unknown labels influence inference.');
p=pcu_predict(state,[]);assert(all(~[p.methods.available])&&all(~[p.methods.accepted]),'pcu:Test','Malformed observation silently accepted.');
B2=M(string(M.scenario)=="stationary"&M.stream_index==1&M.block==2,:);[a2,t2,v2]=inputs(source,B2);
new.spec.pcu_keep_history=false;[nh,eh]=pcu_online_update(new,a2,t2,v2,'history_block2');
assert(numel(nh.replay)==4&&eh.systems.gated_full.training.network_only.training_n==604,'pcu:Test','History ablation changed offline/current composition.');
state.spec.pcu_use_offline=false;[~,ef]=pcu_online_update(state,anchor,train,valid,'offline_block1');
assert(ef.systems.gated_full.training.network_only.training_n==4&&ef.systems.gated_full.training.network_only.offline_training_n==0,'pcu:Test','Offline ablation composition wrong.');
report=struct('passed',true,'groups',11,'iterations',iterations,'scope','Read-only old development fixtures; engineering parity and ablation checks, not confirmation outcomes.');
fprintf('PCU contracts passed (11 groups).\n');
end
function [a,tr,va]=inputs(source,B)
A=B(string(B.role)=="anchor",:);D=load(fullfile(source,'trials',sprintf('trial_%06d.mat',A.trial_id)),'record');a=D.record.obs;a.is_anchor=true;a.known_mass_kg=0;
tr=refs(source,B,"reference_train");va=refs(source,B,"reference_validation");
end
function R=refs(source,B,role)
Q=B(string(B.role)==role,:);R=struct([]);
for i=1:height(Q)
    f=fullfile(source,'trials',sprintf('trial_%06d.mat',Q.trial_id(i)));D=load(f,'record');r=D.record;
    one=struct('obs',r.obs,'known_theta',r.known_theta,'is_reference',true,'role',char(role),'record_key',f,'record_hash',prc_file_hash(f));
    if isempty(R),R=one;else,R(end+1)=one;end
end
end

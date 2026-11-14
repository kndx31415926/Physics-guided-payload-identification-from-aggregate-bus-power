function report=test_prb_core()
% Meaningful safety checks using read-only existing development records.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root,fullfile(root,'src'),fullfile(root,'vendor','bdcl_v29'));
source=fullfile(root,'results','pra_continual_20261030_v1');C=load(fullfile(source,'configuration.mat'));
spec=C.spec;spec.online_iterations=1;spec.gate_min_absolute_improvement=1e6;
state=prb_online_init(C.cfg,spec);P=load(fullfile(source,'data_plan.mat'),'manifest');M=P.manifest;
B=M(string(M.scenario)=="stationary"&M.stream_index==1&M.block==1,:);
Q=B(string(B.role)=="eval",:);record=load_record(source,Q.trial_id(1));
p=prb_online_predict(state,record.obs);old=pra_online_init(C.cfg,spec);
baseline=pra_online_predict(old,record.obs,old.eta0,'frozen');
assert(isequaln(p.methods(1).raw,baseline.raw)&&isequaln(p.methods(1).clipped,baseline.clipped), ...
    'prb:Test','Frozen predictions must match the original pipeline.');
extra=record.obs;extra.theta_true=[99 99 99];extra.truth=struct('payload',-12345);extra.object_id=-17;
q=prb_online_predict(state,extra);assert(isequaln(p,q),'prb:Test','Unknown truth fields influenced inference.');
Q=B(string(B.role)=="anchor",:);anchor=load_record(source,Q.trial_id);anchor=anchor.obs;
anchor.is_anchor=true;anchor.known_mass_kg=0;
train=references(source,B,"reference_train");valid=references(source,B,"reference_validation");
before=state;[updated,event]=prb_online_update(state,anchor,train,valid,'prb_core_stationary_block1');
for name={'gated_calibration','gated_full'}
    n=name{1};assert(~event.systems.(n).deployed&&event.systems.(n).rollback_preserved&& ...
        isequaln(before.systems.(n),updated.systems.(n)),'prb:Test','Joint rejection changed deployed eta or networks.');
end
assert(numel(updated.replay)==4&&all(strcmp({updated.replay.role},'reference_train')), ...
    'prb:Test','Only known training references may enter replay.');
[again,repeated]=prb_online_update(updated,anchor,train,valid,'prb_core_stationary_block1');
assert(repeated.already_processed&&isequaln(again,updated),'prb:Test','Duplicate block was not idempotent.');
for change=1:5
    bad=train;
    switch change
        case 1,bad(1).known_theta(1)=bad(1).known_theta(1)+.0001;
        case 2,bad(1).record_key=[bad(1).record_key '_changed'];
        case 3,bad(1).record_hash=repmat('a',1,64);
        case 4,bad(1).role='eval';
        case 5,bad(1).obs.P(1)=bad(1).obs.P(1)+.01;
    end
    failed=false;
    try,prb_online_update(updated,anchor,bad,valid,'prb_core_stationary_block1');catch err,failed=strcmp(err.identifier,'prb:BlockIdentity');end
    assert(failed,'prb:Test','Repeated key silently ignored changed reference identity.');
end
badanchor=anchor;badanchor.plateau_P(1)=badanchor.plateau_P(1)+.01;failed=false;
try,prb_online_update(updated,badanchor,train,valid,'prb_core_stationary_block1');catch err,failed=strcmp(err.identifier,'prb:BlockIdentity');end
assert(failed,'prb:Test','Repeated key silently ignored changed anchor.');
failed=false;try,prb_online_update(updated,anchor,train,valid,'different_key_same_records');catch err,failed=strcmp(err.identifier,'prb:ReferenceLeakage');end
assert(failed,'prb:Test','Duplicate measurements escaped provenance checks.');
bad=train;bad(1).known_theta=valid(1).known_theta;failed=false;
try,prb_online_update(before,anchor,bad,valid,'same_payload_both_roles');catch err,failed=strcmp(err.identifier,'prb:ReferenceLeakage');end
assert(failed,'prb:Test','Same known payload configuration crossed roles within a block.');
bad=fresh_identity(train,'next_train');other=fresh_identity(valid,'next_validation');
bad(1).known_theta=valid(1).known_theta;other(1).known_theta=[.13 .11 -.006];other(2).known_theta=[.19 .15 .008];failed=false;
try,prb_online_update(updated,anchor,bad,other,'cross_history_payload_role');catch err,failed=strcmp(err.identifier,'prb:ReferenceLeakage');end
assert(failed,'prb:Test','Known payload configuration crossed roles over time.');
bad=train;bad(1).role='eval';failed=false;
try,prb_online_update(before,anchor,bad,valid,'bad_role');catch err,failed=strcmp(err.identifier,'prb:ReferenceRole');end
assert(failed,'prb:Test','Unknown-role data entered training.');
gate_spec=state.spec;gate_spec.gate_min_absolute_improvement=1e-6;
score=struct('loss',.1,'component_mae',[.002 .003 .004],'worst_loss',.2,'usable',true,'teacher_accepted_count',2);
good=score;good.loss=.08;good.component_mae=score.component_mae*.9;good.worst_loss=.19;
gate=prb_gate_candidate(score,good,.001,.001,gate_spec);assert(gate.pass,'prb:Test','A valid whole-system candidate was rejected.');
worse=good;worse.component_mae(1)=.003;gate=prb_gate_candidate(score,worse,.001,.001,gate_spec);
assert(~gate.pass&&~gate.component_pass,'prb:Test','Component deterioration escaped the gate.');
worse=good;worse.worst_loss=.3;gate=prb_gate_candidate(score,worse,.001,.001,gate_spec);
assert(~gate.pass&&~gate.worst_reference_pass,'prb:Test','Worst-reference deterioration escaped the gate.');
assert(event.systems.gated_full.training.network_only.success,'prb:Test','The training path did not complete.');
report=struct('passed',true,'groups',14,'forced_rejection',event, ...
    'scope','Short implementation verification only; one iteration is not a research model.');
fprintf('PRB core tests passed: 14 groups.\n');
end
function R=fresh_identity(R,prefix)
for i=1:numel(R)
    R(i).record_key=sprintf('%s_%d',prefix,i);md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');
    md.update(unicode2native(R(i).record_key,'UTF-8'));
    R(i).record_hash=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
end
function r=load_record(source,id)
A=load(fullfile(source,'trials',sprintf('trial_%06d.mat',id)),'record');r=A.record;
end
function refs=references(source,B,role)
Q=B(string(B.role)==role,:);refs=struct([]);
for i=1:height(Q)
    r=load_record(source,Q.trial_id(i));file=fullfile(source,'trials',sprintf('trial_%06d.mat',r.trial_id));
    one=struct('obs',r.obs,'known_theta',r.known_theta,'is_reference',true,'role',char(role), ...
        'record_key',sprintf('development/trial_%06d',r.trial_id),'record_hash',prc_file_hash(file));
    if isempty(refs),refs=one;else,refs(end+1)=one;end
end
end

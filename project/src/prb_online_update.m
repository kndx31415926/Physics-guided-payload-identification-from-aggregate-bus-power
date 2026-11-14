function [state,report]=prb_online_update(state,anchor_obs,train_refs,validation_refs,block_key)
%PRB_ONLINE_UPDATE Atomically deploy or retain the complete (eta, weights).
% Validation references only select complete candidate ensembles. They never
% enter fitrnet targets, weights, replay, or early stopping. A rejected update
% leaves both deployed calibration and deployed networks exactly unchanged.
key=char(string(block_key));assert(~isempty(key)&&isrow(key),'prb:Block','Scalar nonempty block key required.');
train_refs=normalize_refs(train_refs);validation_refs=normalize_refs(validation_refs);
prior=find(strcmp(state.processed_keys,key),1);
if ~isempty(prior)
    report=state.history{prior};
    try,input_identity=update_identity(anchor_obs,train_refs,validation_refs);
    catch,error('prb:BlockIdentity','Repeated block input is malformed or differs from its recorded identity.');end
    assert(isfield(report,'input_identity')&&isequaln(report.input_identity,input_identity), ...
        'prb:BlockIdentity','A repeated block key must have identical reference labels, roles, provenance, observations and anchor inputs.');
    report.already_processed=true;return
end
validate_refs(train_refs,'reference_train',state.spec.expected_train_references,state.bounds);
validate_refs(validation_refs,'reference_validation',state.spec.expected_validation_references,state.bounds);
assert(isstruct(anchor_obs)&&isscalar(anchor_obs)&&isfield(anchor_obs,'is_anchor')&& ...
    isequal(anchor_obs.is_anchor,true)&&isfield(anchor_obs,'known_mass_kg')&& ...
    isequal(anchor_obs.known_mass_kg,0),'prb:AnchorRole','An explicitly known empty anchor is required.');
trkeys={train_refs.record_key};vakeys={validation_refs.record_key};
trhash={train_refs.record_hash};vahash={validation_refs.record_hash};
trtheta=reshape([train_refs.known_theta],3,[]).';vatheta=reshape([validation_refs.known_theta],3,[]).';
assert(isempty(intersect(trkeys,vakeys))&&isempty(intersect(trhash,vahash)), ...
    'prb:ReferenceLeakage','Training and validation records overlap.');
assert(~theta_overlap(trtheta,vatheta),'prb:ReferenceLeakage', ...
    'Training and validation must use distinct known mass/COM configurations.');
for j=1:numel(state.history)
    h=state.history{j};
    assert(isempty(intersect(trkeys,[h.training_record_keys h.validation_record_keys]))&& ...
        isempty(intersect(vakeys,[h.training_record_keys h.validation_record_keys]))&& ...
        isempty(intersect(trhash,[h.training_record_hashes h.validation_record_hashes]))&& ...
        isempty(intersect(vahash,[h.training_record_hashes h.validation_record_hashes])), ...
        'prb:ReferenceLeakage','A measurement cannot be reused in another block or cross reference roles.');
    assert(~theta_overlap(trtheta,h.validation_known_theta)&&~theta_overlap(vatheta,h.training_known_theta), ...
        'prb:ReferenceLeakage','A known mass/COM configuration cannot cross training and validation roles over time.');
end
input_identity=update_identity(anchor_obs,train_refs,validation_refs);
timer=tic;state.block_count=state.block_count+1;block=state.block_count;
before=numel(state.replay);state.replay=add_replay(state.replay,train_refs,state.spec.replay_capacity);
report=struct('schema','prb_joint_update_development_v1','block_key',key,'block_index',block, ...
    'already_processed',false,'training_record_keys',{trkeys},'validation_record_keys',{vakeys}, ...
    'training_record_hashes',{trhash},'validation_record_hashes',{vahash}, ...
    'training_known_theta',trtheta,'validation_known_theta',vatheta,'input_identity',input_identity, ...
    'replay_count_before',before,'replay_count_after',numel(state.replay), ...
    'systems',struct(),'unknown_truth_used',false,'elapsed_s',NaN, ...
    'phase','references_only_after_unknown_predictions', ...
    'gate_score','raw_ensemble_mean_squared_error_normalized_by_parameter_ranges', ...
    'nominal_gate_scope','weights on original eta0 nominal validation features; no drifting observation recalibration test', ...
    'replay_scope','original 600 eta0 nominal training features plus raw online reference observations re-extracted per candidate eta');
for n={'empty_only','gated_calibration','gated_full'}
    name=n{1};old=state.systems.(name);[proposal,calibration]=calibrate(state.cfg,anchor_obs,old.eta);
    different=calibration.accepted&&~isequaln(proposal.coefficients,old.eta.coefficients);
    sr=system_report(name,calibration);sr.eta_before=old.eta.coefficients;
    selected=old;
    if strcmp(name,'empty_only')
        if different
            selected.eta=proposal;sr.selected_candidate='calibration_only';sr.reason='accepted_by_empty_anchor_gate';
        else,sr.reason='empty_anchor_rejected_or_unchanged';end
    else
        oldvalid=extract_refs(state,validation_refs,old.eta);
        oldscore=reference_score(state,old.models,oldvalid);oldnominal=nominal_score(state,old.models);
        sr.old_reference_loss=oldscore.loss;sr.old_reference_score=oldscore;
        sr.old_nominal_loss=oldnominal;
        candidate_systems={};candidate_reports=struct([]);
        if different
            current=old;current.eta=proposal;newvalid=extract_refs(state,validation_refs,proposal);
            score=reference_score(state,current.models,newvalid);
            [candidate_reports,candidate_systems]=add_candidate(candidate_reports,candidate_systems, ...
                current,'calibration_only',score,oldscore,oldnominal,state);
        else,newvalid=[];end
        if strcmp(name,'gated_full')
            % Pair candidate seeds across calibrations. Each is a complete
            % three-seed ensemble; no validation-driven seed mixing occurs.
            [models,training]=train_candidate(state,old.models,old.eta,train_refs,block,key);
            sr.training.network_only=training;
            if training.success
                current=old;current.models=models;score=reference_score(state,models,oldvalid);
                [candidate_reports,candidate_systems]=add_candidate(candidate_reports,candidate_systems, ...
                    current,'network_only',score,oldscore,nominal_score(state,models),state);
            end
            if different
                [models,training]=train_candidate(state,old.models,proposal,train_refs,block,key);
                sr.training.joint=training;
                if training.success
                    current=old;current.eta=proposal;current.models=models;score=reference_score(state,models,newvalid);
                    [candidate_reports,candidate_systems]=add_candidate(candidate_reports,candidate_systems, ...
                        current,'joint',score,oldscore,nominal_score(state,models),state);
                end
            end
        end
        sr.candidates=candidate_reports;best=0;bestloss=Inf;
        for c=1:numel(candidate_reports)
            if candidate_reports(c).gate.pass&&candidate_reports(c).score.loss<bestloss
                best=c;bestloss=candidate_reports(c).score.loss;
            end
        end
        if best>0
            selected=candidate_systems{best};sr.selected_candidate=candidate_reports(best).name;
            sr.new_reference_loss=bestloss;sr.new_reference_score=candidate_reports(best).score;
            sr.new_nominal_loss=candidate_reports(best).nominal_loss;sr.reason='whole_system_candidate_accepted';
        else
            sr.new_reference_loss=oldscore.loss;sr.new_reference_score=oldscore;
            sr.new_nominal_loss=oldnominal;sr.reason='all_candidates_rejected_or_unavailable';
        end
    end
    sr.eta_changed=~isequaln(selected.eta.coefficients,old.eta.coefficients);
    sr.network_changed=~isequaln(selected.models,old.models);sr.deployed=sr.eta_changed||sr.network_changed;
    if sr.deployed
        selected.deployed_updates=old.deployed_updates+1;
        selected.eta_updates=old.eta_updates+double(sr.eta_changed);
        selected.network_updates=old.network_updates+double(sr.network_changed);
    else
        % Full struct restoration also preserves calibration metadata and all
        % update counters. Replay is training memory, not deployed inference.
        selected=old;
        assert(isequaln(selected.eta,old.eta)&&isequaln(selected.models,old.models), ...
            'prb:Rollback','Rejected system must retain eta and all networks.');
    end
    sr.eta_after=selected.eta.coefficients;sr.rollback_preserved=~sr.deployed&&isequaln(selected,old);
    report.systems.(name)=sr;state.systems.(name)=selected;
end
report.elapsed_s=toc(timer);state.processed_keys{end+1}=key;state.history{end+1}=report;
end

function [reports,systems]=add_candidate(reports,systems,system,name,score,oldscore,nominal,state)
gate=prb_gate_candidate(oldscore,score,nominal,state.initial_nominal_raw_loss,state.spec);
one=struct('name',name,'score',score,'nominal_loss',nominal,'gate',gate, ...
    'eta_coefficients',system.eta.coefficients);
if isempty(reports),reports=one;else,reports(end+1)=one;end
systems{end+1}=system;
end

function [models,report]=train_candidate(state,oldmodels,eta,current_refs,block,key)
models=oldmodels;timer=tic;
report=struct('success',false,'training_n',0,'replay_n',0,'replay_unusable_n',0, ...
    'seed_reports',struct([]),'elapsed_s',NaN,'reason','', ...
    'candidate_eta',eta.coefficients,'validation_reference_targets_used',false);
now=extract_refs(state,current_refs,eta);
if ~all(now.usable),report.reason='current_training_reference_unusable';report.elapsed_s=toc(timer);return,end
R=extract_refs(state,state.replay,eta);keep=R.usable;B=state.bootstrap;
X=[B.X;R.X(keep,:)];base=[B.base;R.base(keep,:)];theta=[B.theta;R.theta(keep,:)];
weights=[ones(size(B.X,1),1);state.spec.reference_weight*ones(sum(keep),1)];
target=(theta-base)./state.scale;report.training_n=size(X,1);
report.replay_n=sum(keep);report.replay_unusable_n=sum(~keep);
nominal_target=(state.validation.theta-state.validation.base)./state.scale;
for s=1:numel(oldmodels)
    seed=state.spec.online_seeds(s)+100*block;learner=oldmodels{s};st=tic;
    one=struct('seed_index',s,'training_seed',seed,'trained',false,'elapsed_s',NaN, ...
        'error_identifier','','error_message','');
    try
        rs=rng;restore=onCleanup(@()rng(rs));rng(seed,'twister');
        candidate=learner;candidate.model=fitrnet(X(:,learner.columns),target, ...
            'LayerSizes',learner.model.ModelParameters.LayerSizes,'Activations','tanh', ...
            'Standardize',true,'Lambda',learner.selection.lambda,'IterationLimit',state.spec.online_iterations, ...
            'Weights',weights,'Verbose',0,'ValidationData',{state.validation.X(:,learner.columns),nominal_target}, ...
            'ValidationPatience',state.spec.online_validation_patience);
        clear restore
        candidate.online=struct('block_key',key,'training_seed',seed, ...
            'label_source','explicit_known_training_references_only','candidate_eta',eta.coefficients);
        models{s}=candidate;one.trained=true;
    catch err
        one.error_identifier=err.identifier;one.error_message=err.message;
    end
    one.elapsed_s=toc(st);if isempty(report.seed_reports),report.seed_reports=one;else,report.seed_reports(end+1)=one;end
end
report.success=all([report.seed_reports.trained]);report.reason='all_three_seeds_trained';
if ~report.success,models=oldmodels;report.reason='one_or_more_training_failures_entire_candidate_discarded';end
report.elapsed_s=toc(timer);
end

function D=extract_refs(state,refs,eta)
N=numel(refs);D=struct('X',nan(N,13),'base',nan(N,3),'theta',nan(N,3), ...
    'usable',false(N,1),'teacher_accepted',false(N,1));
for i=1:N
    f=pra_online_features(state,refs(i).obs,eta);D.theta(i,:)=refs(i).known_theta(:).';
    D.teacher_accepted(i)=f.teacher_accepted;D.usable(i)=f.usable;
    if state.spec.reference_requires_teacher,D.usable(i)=D.usable(i)&&f.teacher_accepted;end
    if D.usable(i),D.X(i,:)=f.residual;D.base(i,:)=f.base;end
end
end

function S=reference_score(state,models,D)
S=struct('loss',Inf,'component_mae',inf(1,3),'worst_loss',Inf,'per_reference_loss',inf(size(D.theta,1),1), ...
    'usable',all(D.usable),'teacher_accepted_count',sum(D.teacher_accepted), ...
    'raw_prediction',nan(size(D.theta)),'clipped_prediction',nan(size(D.theta)), ...
    'bounds_hit_count',0);
if ~S.usable,return,end
[raw,clipped]=pra_online_model_prediction(models,D.X,D.base,state.scale,state.bounds);
p=mean(raw,3);S.raw_prediction=p;S.clipped_prediction=mean(clipped,3);
S.bounds_hit_count=sum(any(abs(raw-clipped)>1e-12,[2 3]));
S.per_reference_loss=mean(((p-D.theta)./state.scale).^2,2);
S.loss=mean(S.per_reference_loss);S.worst_loss=max(S.per_reference_loss);
S.component_mae=mean(abs(p-D.theta),1);S.usable=S.usable&&all(isfinite(p),'all');
end

function value=nominal_score(state,models)
[raw,~]=pra_online_model_prediction(models,state.validation.X,state.validation.base,state.scale,state.bounds);
value=mean(((mean(raw,3)-state.validation.theta)./state.scale).^2,'all');
end

function [eta,report]=calibrate(cfg,obs,oldeta)
eta=oldeta;report=struct('accepted',false,'reasons',{{'unusable_anchor'}});
if all(isfield(obs,{'plateau_q','plateau_P','plateau_sd_P','stationary'}))
    [eta,report]=bpil_calibrate_anchor(cfg,obs,oldeta);
end
end

function R=add_replay(R,refs,capacity)
if isempty(R),R=refs(:).';else,R=[R refs(:).'];end
R=R(max(1,numel(R)-capacity+1):end);
end

function S=system_report(name,calibration)
S=struct('name',name,'deployed',false,'eta_changed',false,'network_changed',false, ...
    'selected_candidate','keep','reason','','calibration',calibration,'candidates',struct([]), ...
    'training',struct(),'old_reference_loss',NaN,'new_reference_loss',NaN, ...
    'old_reference_score',struct(),'new_reference_score',struct(), ...
    'old_nominal_loss',NaN,'new_nominal_loss',NaN,'eta_before',[],'eta_after',[], ...
    'rollback_preserved',false);
end

function R=normalize_refs(R)
if ~isstruct(R),return,end
for k=1:numel(R)
    for f={'record_key','record_hash'}
        n=f{1};if isfield(R,n)&&isstring(R(k).(n))&&isscalar(R(k).(n)),R(k).(n)=char(R(k).(n));end
    end
    if isfield(R,'known_theta'),R(k).known_theta=double(R(k).known_theta(:).');end
end
end

function identity=update_identity(anchor,train,valid)
% Store exact values used for anchor fitting. For references, hash all
% supplied observation fields as well as retaining explicit supervision and
% provenance, so the API remains idempotent even outside the file runner.
names={'is_anchor','known_mass_kg','plateau_q','plateau_P','plateau_sd_P','stationary'};
A=struct();
for i=1:numel(names)
    f=names{i};A.(f)=struct('present',isfield(anchor,f),'value',[]);
    if A.(f).present,A.(f).value=anchor.(f);end
end
identity=struct('schema','prb_update_input_identity_v1','anchor_inputs',A, ...
    'training',reference_identity(train),'validation',reference_identity(valid));
end

function identity=reference_identity(refs)
identity=struct([]);
for i=1:numel(refs)
    r=refs(i);md=javaMethod('getInstance','java.security.MessageDigest','SHA-256');
    md.update(unicode2native(jsonencode(r.obs),'UTF-8'));
    digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
    one=struct('role',char(string(r.role)),'is_reference',r.is_reference, ...
        'known_theta',double(r.known_theta(:).'),'record_key',char(string(r.record_key)), ...
        'record_hash',lower(char(string(r.record_hash))),'observation_sha256',digest);
    if isempty(identity),identity=one;else,identity(end+1)=one;end
end
end

function present=theta_overlap(A,B)
present=false;
for i=1:size(A,1)
    if any(all(abs(B-A(i,:))<=1e-12,2)),present=true;return,end
end
end

function validate_refs(R,role,n,B)
assert(isstruct(R)&&numel(R)==n,'prb:References','Expected %d references for %s.',n,role);
required={'obs','known_theta','is_reference','role','record_key','record_hash'};
assert(all(isfield(R,required)),'prb:References','Missing explicit reference provenance fields.');
for i=1:numel(R)
    assert(isequal(R(i).is_reference,true)&&strcmp(string(R(i).role),role), ...
        'prb:ReferenceRole','Only explicitly labeled %s records are allowed.',role);
    t=double(R(i).known_theta(:).');assert(numel(t)==3&&all(isfinite(t))&& ...
        all(t>=B(:,1).')&&all(t<=B(:,2).'),'prb:ReferenceLabel','Known reference label invalid/outside bounds.');
    assert(ischar(R(i).record_key)&&isrow(R(i).record_key)&&~isempty(R(i).record_key)&& ...
        ischar(R(i).record_hash)&&isrow(R(i).record_hash)&& ...
        ~isempty(regexp(R(i).record_hash,'^[0-9a-fA-F]{64}$','once')), ...
        'prb:ReferenceProvenance','Reference key and SHA256 required.');
end
assert(numel(unique({R.record_key}))==n&&numel(unique({R.record_hash}))==n, ...
    'prb:ReferenceLeakage','Reference records must be distinct within a split.');
end

function [state,report]=pra_online_update(state,train_refs,validation_refs,eta,block_key)
% Supervised update from explicit independent known references only.
% Unknown payload pseudo-labels are never accepted by this interface.
key=char(string(block_key));assert(~isempty(key)&&isrow(key),'pra:Block','Nonempty scalar block key required.');
old=find(strcmp(state.processed_keys,key),1);
if ~isempty(old),report=state.history{old};report.already_processed=true;return,end
train_refs=normalize_refs(train_refs);validation_refs=normalize_refs(validation_refs);
validate_refs(train_refs,'reference_train',state.spec.expected_train_references,state.bounds);
validate_refs(validation_refs,'reference_validation',state.spec.expected_validation_references,state.bounds);
trkeys={train_refs.record_key};vakeys={validation_refs.record_key};
assert(isempty(intersect(trkeys,vakeys)),'pra:ReferenceLeakage','Training and validation references overlap.');
assert(isempty(intersect({train_refs.record_hash},{validation_refs.record_hash})), ...
    'pra:ReferenceLeakage','Training and validation record hashes overlap.');
% No reference record can move between splits later in the stream.
for j=1:numel(state.history)
    h=state.history{j};assert(isempty(intersect(trkeys,h.validation_record_keys))&& ...
        isempty(intersect(vakeys,h.training_record_keys))&& ...
        isempty(intersect({train_refs.record_hash},h.validation_record_hashes))&& ...
        isempty(intersect({validation_refs.record_hash},h.training_record_hashes)), ...
        'pra:ReferenceLeakage','Reference records cannot cross training/validation roles.');
end
state.block_count=state.block_count+1;block=state.block_count;timer=tic;
report=struct('schema','pra_known_reference_update_v1','block_key',key,'block_index',block, ...
    'already_processed',false,'training_record_keys',{trkeys},'validation_record_keys',{vakeys}, ...
    'training_record_hashes',{{train_refs.record_hash}},'validation_record_hashes',{{validation_refs.record_hash}}, ...
    'reference_requires_teacher',state.spec.reference_requires_teacher,'variants',struct(), ...
    'elapsed_s',NaN,'unknown_truth_used',false);
names={'network_only','full','no_replay'};
for k=1:3
    name=names{k};cal=eta;if k==1,cal=state.eta0;end
    train=extract_refs(state,train_refs,cal);valid=extract_refs(state,validation_refs,cal);
    variant=state.variants.(name);old_models=variant.models;
    old_deployed_counts=variant.deployed_seed_updates;
    variant.attempted_updates=variant.attempted_updates+1;
    vr=struct('name',name,'train_reference_usable',train.usable,'validation_reference_usable',valid.usable, ...
        'train_teacher_accepted',train.teacher_accepted,'validation_teacher_accepted',valid.teacher_accepted, ...
        'trained',false,'deployed',false,'reason','','replay_count_before',size(variant.replay.X,1), ...
        'replay_count_after',size(variant.replay.X,1),'seed_reports',struct([]),'elapsed_s',0, ...
        'old_ensemble_nominal_loss',NaN,'new_ensemble_nominal_loss',NaN, ...
        'old_ensemble_reference_loss',NaN,'new_ensemble_reference_loss',NaN, ...
        'ensemble_gate_pass',false);
    vt=tic;
    if ~all(train.usable)||~all(valid.usable)
        vr.reason='reference_observation_or_feature_rejected';vr.elapsed_s=toc(vt);
        report.variants.(name)=vr;state.variants.(name)=variant;continue
    end
    if k<3
        variant.replay=add_replay(variant.replay,train,train_refs,cal,key,state.spec.replay_capacity);
        R=variant.replay;B=state.bootstrap;X=[B.X;R.X];base=[B.base;R.base];theta=[B.theta;R.theta];
        weights=[ones(size(B.X,1),1);state.spec.reference_weight*ones(size(R.X,1),1)];
    else
        X=train.X;base=train.base;theta=train.theta;weights=ones(size(X,1),1);
    end
    target=(theta-base)./state.scale;vr.trained=true;vr.replay_count_after=size(variant.replay.X,1);
    for s=1:3
        seed=state.spec.online_seeds(s)+10000*k+100*block;
        sr=struct('seed_index',s,'training_seed',seed,'trained',false,'deployed',false, ...
            'reason','','old_nominal_loss',NaN,'new_nominal_loss',NaN, ...
            'initial_nominal_loss',variant.initial_nominal_loss(s),'old_reference_loss',NaN, ...
            'new_reference_loss',NaN,'nominal_gate_pass',false,'reference_gate_pass',false, ...
            'training_n',size(X,1),'elapsed_s',0,'error_identifier','','error_message','');
        st=tic;learner=variant.models{s};
        try
            [~,pn]=pra_online_model_prediction({learner},state.validation.X,state.validation.base,state.scale,state.bounds);
            [~,pv]=pra_online_model_prediction({learner},valid.X,valid.base,state.scale,state.bounds);
            sr.old_nominal_loss=loss(pn,state.validation.theta,state.scale);
            sr.old_reference_loss=loss(pv,valid.theta,state.scale);
            layers=learner.model.ModelParameters.LayerSizes;lambda=learner.selection.lambda;
            rs=rng;restore=onCleanup(@()rng(rs));rng(seed,'twister');
            nominal_target=(state.validation.theta-state.validation.base)./state.scale;
            candidate=learner;candidate.model=fitrnet(X(:,learner.columns),target, ...
                'LayerSizes',layers,'Activations','tanh','Standardize',true,'Lambda',lambda, ...
                'IterationLimit',state.spec.online_iterations,'Weights',weights,'Verbose',0, ...
                'ValidationData',{state.validation.X(:,learner.columns),nominal_target}, ...
                'ValidationPatience',state.spec.online_validation_patience);
            clear restore
            sr.trained=true;
            [~,pn]=pra_online_model_prediction({candidate},state.validation.X,state.validation.base,state.scale,state.bounds);
            [~,pv]=pra_online_model_prediction({candidate},valid.X,valid.base,state.scale,state.bounds);
            sr.new_nominal_loss=loss(pn,state.validation.theta,state.scale);
            sr.new_reference_loss=loss(pv,valid.theta,state.scale);
            sr.nominal_gate_pass=isfinite(sr.new_nominal_loss)&& ...
                sr.new_nominal_loss<=state.spec.nominal_gate_ratio*sr.initial_nominal_loss;
            sr.reference_gate_pass=isfinite(sr.new_reference_loss)&& ...
                sr.new_reference_loss<=sr.old_reference_loss+1e-12;
            if sr.nominal_gate_pass&&sr.reference_gate_pass
                candidate.online=struct('block_key',key,'training_seed',seed,'variant',name, ...
                    'label_source','explicit_known_reference','reference_gate_loss',sr.new_reference_loss);
                variant.models{s}=candidate;variant.deployed_seed_updates(s)=variant.deployed_seed_updates(s)+1;
                sr.deployed=true;sr.reason='accepted';
            elseif ~sr.nominal_gate_pass,sr.reason='nominal_validation_gate_rejected';
            else,sr.reason='current_reference_gate_rejected';end
        catch err
            sr.reason='training_failed';sr.error_identifier=err.identifier;sr.error_message=err.message;
        end
        sr.elapsed_s=toc(st);if isempty(vr.seed_reports),vr.seed_reports=sr;else,vr.seed_reports(end+1)=sr;end
    end
    [~,oldn]=pra_online_model_prediction(old_models,state.validation.X,state.validation.base,state.scale,state.bounds);
    [~,oldv]=pra_online_model_prediction(old_models,valid.X,valid.base,state.scale,state.bounds);
    [~,newn]=pra_online_model_prediction(variant.models,state.validation.X,state.validation.base,state.scale,state.bounds);
    [~,newv]=pra_online_model_prediction(variant.models,valid.X,valid.base,state.scale,state.bounds);
    vr.old_ensemble_nominal_loss=loss(mean(oldn,3),state.validation.theta,state.scale);
    vr.new_ensemble_nominal_loss=loss(mean(newn,3),state.validation.theta,state.scale);
    vr.old_ensemble_reference_loss=loss(mean(oldv,3),valid.theta,state.scale);
    vr.new_ensemble_reference_loss=loss(mean(newv,3),valid.theta,state.scale);
    vr.ensemble_gate_pass=vr.new_ensemble_nominal_loss<= ...
        state.spec.nominal_gate_ratio*variant.initial_nominal_ensemble_loss&& ...
        vr.new_ensemble_reference_loss<=vr.old_ensemble_reference_loss+1e-12;
    if ~vr.ensemble_gate_pass
        variant.models=old_models;variant.deployed_seed_updates=old_deployed_counts;
        for s=1:3
            if vr.seed_reports(s).deployed
                vr.seed_reports(s).deployed=false;vr.seed_reports(s).reason='ensemble_gate_rejected';
            end
        end
    end
    vr.deployed=any([vr.seed_reports.deployed]);vr.reason='all_candidates_rejected';
    if vr.deployed,vr.reason='one_or_more_seed_candidates_deployed';end
    vr.elapsed_s=toc(vt);report.variants.(name)=vr;state.variants.(name)=variant;
end
report.elapsed_s=toc(timer);state.processed_keys{end+1}=key;state.history{end+1}=report;
end

function R=normalize_refs(R)
if ~isstruct(R),return,end
for k=1:numel(R)
    for name={'record_key','record_hash'}
        f=name{1};if isfield(R,f)&&isstring(R(k).(f))&&isscalar(R(k).(f)),R(k).(f)=char(R(k).(f));end
    end
end
end

function validate_refs(R,role,n,B)
assert(isstruct(R)&&numel(R)==n,'pra:References','Expected %d references for %s.',n,role);
required={'obs','known_theta','is_reference','role','record_key','record_hash'};
assert(all(isfield(R,required)),'pra:References','Missing explicit reference provenance fields.');
for i=1:numel(R)
    assert(isequal(R(i).is_reference,true)&&strcmp(string(R(i).role),role), ...
        'pra:ReferenceRole','Only explicitly labeled %s records are allowed.',role);
    t=double(R(i).known_theta(:).');assert(numel(t)==3&&all(isfinite(t))&& ...
        all(t>=B(:,1).')&&all(t<=B(:,2).'),'pra:ReferenceLabel','Known reference label invalid/outside bounds.');
    assert(ischar(R(i).record_key)&&isrow(R(i).record_key)&&~isempty(R(i).record_key)&& ...
        ischar(R(i).record_hash)&&isrow(R(i).record_hash)&&~isempty(R(i).record_hash), ...
        'pra:ReferenceProvenance','Reference key/hash must be nonempty character rows.');
    assert(~isempty(regexp(R(i).record_hash,'^[0-9a-fA-F]{64}$','once')), ...
        'pra:ReferenceProvenance','Reference record_hash must be a SHA256 hex digest.');
end
assert(numel(unique({R.record_key}))==n&&numel(unique({R.record_hash}))==n, ...
    'pra:ReferenceLeakage','Each reference record must be distinct within a split.');
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

function R=add_replay(R,D,refs,eta,block,capacity)
for i=1:numel(refs)
    assert(~any(strcmp(R.record_key,refs(i).record_key)), ...
        'pra:ReferenceReplay','A reference measurement cannot be inserted twice.');
    R.X(end+1,:)=D.X(i,:);R.base(end+1,:)=D.base(i,:);R.theta(end+1,:)=D.theta(i,:);
    R.record_key{end+1,1}=refs(i).record_key;R.record_hash{end+1,1}=refs(i).record_hash;
    R.calibration{end+1,1}=eta;R.block_key{end+1,1}=block;
end
keep=max(1,size(R.X,1)-capacity+1):size(R.X,1);
for f={'X','base','theta','record_key','record_hash','calibration','block_key'},R.(f{1})=R.(f{1})(keep,:);end
end
function v=loss(p,t,s),v=mean(((reshape(p,[],3)-t)./s).^2,'all');end

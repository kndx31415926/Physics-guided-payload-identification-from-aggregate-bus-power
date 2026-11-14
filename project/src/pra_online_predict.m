function out=pra_online_predict(state,obs,eta,mode)
% Unknown-object prediction: labels and simulator truth are never accessed.
if nargin<4,mode='all';end
names={'frozen','calibrated_frozen','network_only','full','no_replay', ...
    'physics_frozen','physics_current'};
assert(any(strcmp(mode,[names {'all'}])),'pra:Mode','Unknown online prediction mode.');
f0=pra_online_features(state,obs,state.eta0);
if isequaln(state.eta0.coefficients,eta.coefficients),fc=f0;
else,fc=pra_online_features(state,obs,eta);end
methods=repmat(empty(),1,7);
for k=1:7
    name=names{k};f=fc;if any(k==[1 3 6]),f=f0;end
    M=empty();M.name=name;M.teacher=f.teacher;M.reasons=f.reasons;
    if f.usable
        if k>=6,raw=reshape(f.base,1,3,1);clipped=raw;
        else
            models=state.frozen_models;
            if k==3,models=state.variants.network_only.models;end
            if k==4,models=state.variants.full.models;end
            if k==5,models=state.variants.no_replay.models;end
            [raw,clipped]=pra_online_model_prediction(models,f.residual,f.base,state.scale,state.bounds);
        end
        M.seed_raw=reshape(permute(raw,[3 2 1]),[],3);
        M.seed_clipped=reshape(permute(clipped,[3 2 1]),[],3);
        M.raw=mean(M.seed_raw,1);M.clipped=mean(M.seed_clipped,1);M.candidate_theta=M.clipped;
        M.available=all(isfinite(M.raw))&&all(isfinite(M.clipped));
        M.bounds_hit=any(abs(M.seed_raw-M.seed_clipped)>1e-12,'all');
        M.accepted=M.available&&f.teacher_accepted;
        if M.accepted,M.theta=M.clipped;end
    end
    methods(k)=M;
end
if strcmp(mode,'all')
    out=struct('methods',methods,'feature_nominal',f0,'feature_current',fc);
else,out=methods(strcmp(names,mode));end
end
function M=empty()
M=struct('name','','raw',nan(1,3),'clipped',nan(1,3),'candidate_theta',nan(1,3), ...
    'theta',nan(1,3),'accepted',false,'available',false,'bounds_hit',false, ...
    'seed_raw',nan(0,3),'seed_clipped',nan(0,3),'teacher',[],'reasons',{{}});
end

function out=prb_online_predict(state,obs,mode)
%PRB_ONLINE_PREDICT Uses deployable observations only; never reads truth.
if nargin<3,mode='all';end
names={'frozen','empty_only','gated_calibration','gated_full'};
assert(any(strcmp(mode,[names {'all'}])),'prb:Mode','Unknown prediction mode.');
methods=repmat(empty(),1,numel(names));features=cell(1,numel(names));
for k=1:numel(names)
    name=names{k};system=state.systems.(name);match=0;
    for j=1:k-1
        if isequaln(system.eta.coefficients,state.systems.(names{j}).eta.coefficients),match=j;break,end
    end
    if match>0,f=features{match};else,f=pra_online_features(state,obs,system.eta);end
    features{k}=f;M=empty();M.name=name;M.teacher=f.teacher;M.reasons=f.reasons;
    if f.usable
        [raw,clipped]=pra_online_model_prediction(system.models,f.residual,f.base,state.scale,state.bounds);
        M.seed_raw=reshape(permute(raw,[3 2 1]),[],3);M.seed_clipped=reshape(permute(clipped,[3 2 1]),[],3);
        M.raw=mean(M.seed_raw,1);M.clipped=mean(M.seed_clipped,1);M.candidate_theta=M.clipped;
        M.available=all(isfinite(M.raw))&&all(isfinite(M.clipped));
        M.bounds_hit=any(abs(M.seed_raw-M.seed_clipped)>1e-12,'all');
        M.accepted=M.available&&f.teacher_accepted;if M.accepted,M.theta=M.clipped;end
    end
    methods(k)=M;
end
if strcmp(mode,'all'),out=struct('methods',methods);else,out=methods(strcmp(names,mode));end
end
function M=empty()
M=struct('name','','raw',nan(1,3),'clipped',nan(1,3),'candidate_theta',nan(1,3), ...
    'theta',nan(1,3),'accepted',false,'available',false,'bounds_hit',false, ...
    'seed_raw',nan(0,3),'seed_clipped',nan(0,3),'teacher',[],'reasons',{{}});
end

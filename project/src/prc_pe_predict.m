function pred=prc_pe_predict(model,D,indices)
%PRC_PE_PREDICT Encoder-only PE torque followed by common unregularized WLS.
% Reads state/g0/Y/usable/object_id only, never theta or torque supervision.
if nargin<3,indices=(1:size(D.state,1)).';end
indices=indices(:);state=D.state(indices,:,:,:);
assert(size(state,2)==8&&size(state,3)==4&&size(state,4)==4,'prc:StateShape','Expected N-by-8-by-4-by-4 state.');
assert(isequal(size(model.coefficients),[4 3])&&all(isfinite(model.coefficients),'all'), ...
    'prc:PEModel','Invalid PE model coefficients.');
N=size(state,1);tau=nan(N,8,4);
for j=1:4
    beta=model.coefficients(j,:);
    tau(:,:,j)=beta(1)*state(:,:,j,2)-beta(2)*(state(:,:,j,3)-state(:,:,j,4))+beta(3);
end
pred=struct('method',model.method,'object_id',D.object_id(indices),'tau',tau, ...
    'weights',.25*ones(N,8,4),'theta_raw',nan(N,3),'phi_raw',nan(N,3), ...
    'theta_constrained',nan(N,3),'valid',false(N,1),'accepted',false(N,1), ...
    'rank',zeros(N,1),'condition',inf(N,1),'reasons',strings(N,1));
for i=1:N
    row=indices(i);
    out=prc_wls(reshape(tau(i,:,:),8,4),reshape(D.g0(row,:,:),8,4), ...
        reshape(D.Y(row,:,:,:),8,4,3),.25*ones(8,4),model.bounds);
    pred.theta_raw(i,:)=out.raw_theta;pred.phi_raw(i,:)=out.raw_phi;
    pred.theta_constrained(i,:)=out.bounded_theta;pred.rank(i)=out.rank;pred.condition(i)=out.condition;
    pred.valid(i)=logical(D.usable(row))&&out.raw_valid;pred.accepted(i)=logical(D.usable(row))&&out.accepted;
    pred.reasons(i)=strjoin(out.reasons,'; ');
end
end

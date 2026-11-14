function model=prc_pe_fit(D,train_rows,spec)
%PRC_PE_FIT Per-axis position-error linear baseline transferred from Lao.
% tau_j = P_j*(command_j-q_j) - sign(approach_j)*friction_j + bias_j.
% Only training objects with valid encoder features and analytic known-load
% static-torque labels enter the ordinary least-squares fit; no test tuning.
if nargin<2,train_rows=find(D.split=="train");end
if nargin<3,spec=struct();end
train_rows=train_rows(:);
assert(all(train_rows>=1&train_rows<=size(D.state,1))&&numel(unique(train_rows))==numel(train_rows), ...
    'prc:TrainingRows','Invalid or duplicate training rows.');
assert(all(D.split(train_rows)=="train"),'prc:LabelLeakage','PE fit accepts training objects only.');
rows=train_rows(logical(D.usable(train_rows)));
model=struct('method','lao_PE_8pose_planar_transfer','coefficients',nan(4,3), ...
    'training_object_id',D.object_id(rows),'fit_rank',zeros(1,4),'condition',inf(1,4), ...
    'training_torque_rmse_Nm',nan(1,4),'sample_count',zeros(1,4), ...
    'coefficient_names',{{'P','friction','bias'}}, ...
    'spec_provenance',spec,'bounds',D.bounds, ...
    'scope','OLS on analytic known-training-load static torque; not a reproduction of the original 64-pose 3D experiment.');
assert(~isempty(rows),'prc:TrainingRows','No usable training objects.');
for j=1:4
    e=reshape(D.state(rows,:,j,2),[],1);
    direction=reshape(D.state(rows,:,j,3)-D.state(rows,:,j,4),[],1);
    target=reshape(D.tau_label(rows,:,j),[],1);A=[e,-direction,ones(size(e))];
    keep=all(isfinite(A),2)&isfinite(target);A=A(keep,:);target=target(keep);
    assert(size(A,1)>=3,'prc:TrainingRows','Insufficient finite torque supervision.');
    singular=svd(A,0);r=sum(singular>max(size(A))*eps(max([1;singular])));
    model.fit_rank(j)=r;if r==3,model.condition(j)=singular(1)/singular(3);end
    beta=lsqminnorm(A,target);model.coefficients(j,:)=beta.';
    model.sample_count(j)=size(A,1);model.training_torque_rmse_Nm(j)=sqrt(mean((A*beta-target).^2));
end
end

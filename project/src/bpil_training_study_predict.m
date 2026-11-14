function theta=bpil_training_study_predict(model,X,physical)
input=X;if strcmp(model.method,'physics_residual'),input=[X,physical./model.physical_scale];end
target=predict(model.regressor,input).*model.scale;
switch model.method
    case 'direct',theta=target;
    case 'first_moments'
        m=max(model.bounds(1,1),min(model.bounds(1,2),target(:,1)));
        theta=[m,target(:,2)./m,target(:,3)./m];
    case 'physics_residual',theta=physical+target;
    otherwise,error('bpil:Method','Unknown method');
end
theta=max(model.bounds(:,1).',min(model.bounds(:,2).',theta));
end

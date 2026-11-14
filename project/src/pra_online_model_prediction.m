function [raw,clipped]=pra_online_model_prediction(models,X,base,scale,bounds)
% Each seed is clipped before the equally weighted ensemble, as offline.
N=size(X,1);S=numel(models);raw=nan(N,3,S);clipped=raw;
for s=1:S
    learner=models{s};p=predict(learner.model,X(:,learner.columns)).*scale+base;
    raw(:,:,s)=p;v=min(max(p,bounds(:,1).'),bounds(:,2).');v(~isfinite(p))=NaN;
    clipped(:,:,s)=v;
end
end

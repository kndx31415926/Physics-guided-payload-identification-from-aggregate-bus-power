function [raw,clipped]=pcr_model_prediction(models,X,base,scale,bounds)
%PCR_MODEL_PREDICTION One deterministic ridge; schema matches PCU outputs.
assert(iscell(models)&&numel(models)==1&&strcmp(models{1}.kind,'ridge'), ...
    'pcr:Model','Exactly one genuine deterministic ridge learner is required.');
learner=models{1};p=psf_ridge('predict',learner.model,X(:,learner.columns)).*scale+base;
raw=reshape(p,size(X,1),3,1);clipped=min(max(raw,bounds(:,1).'),bounds(:,2).');
clipped(~isfinite(raw))=NaN;
end

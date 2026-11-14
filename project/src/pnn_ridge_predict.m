function Y=pnn_ridge_predict(model,X)
%PNN_RIDGE_PREDICT Apply only frozen training-set preprocessing.
assert(strcmp(model.schema,'pnn_ridge_v1')&&size(X,2)==model.transform.input_count, ...
    'pnn:Ridge','Wrong model or input dimension.');
F=X;t=model.transform;
if strcmp(t.mode,'interaction')
    Z=(X-t.mu)./t.sigma;F=[Z Z(:,t.pairs(:,1)).*Z(:,t.pairs(:,2))];
end
Y=((F-model.mu)./model.sigma)*model.beta+model.intercept;
end

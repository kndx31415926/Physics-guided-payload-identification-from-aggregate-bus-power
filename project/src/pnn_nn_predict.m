function Y=pnn_nn_predict(model,X)
%PNN_NN_PREDICT Physical-unit correction; no truth is accepted or consulted.
assert(strcmp(model.schema,'pnn_nn_v1'),'pnn:Model','Wrong NN schema.');
assert(size(X,2)==numel(model.mu),'pnn:Input','Input dimension mismatch.');
Y=nan(size(X,1),3);good=all(isfinite(X),2);
if any(good)
    Z=single((X(good,:)-model.mu)./model.sigma);
    output=extractdata(predict(model.net,dlarray(Z.','CB'))).';
    Y(good,:)=double(output).*model.amplitude;
end
end

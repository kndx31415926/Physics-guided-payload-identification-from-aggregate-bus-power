function [prediction,detail]=pnn_predict(bundle,D,method)
%PNN_PREDICT Deploy frozen method using observables only; theta is not read.
if isnumeric(method),entry=bundle.methods(method);else
    ix=find(strcmp({bundle.methods.name},char(method)));assert(isscalar(ix),'pnn:Method','Unknown method.');
    entry=bundle.methods(ix);
end
N=size(D.base,1);prediction=nan(N,3);model=entry.model;
usable=logical(D.usable(:));accepted=logical(D.accepted(:));
switch entry.kind
    case 'physics6'
        prediction=D.base;usable=all(isfinite(prediction),2);
    case 'physics8'
        prediction=D.physics8;accepted=logical(D.physics8accepted(:));usable=all(isfinite(prediction),2);
        if isfield(D,'physics8usable'),usable=usable&logical(D.physics8usable(:));end
    otherwise
        if strcmp(entry.input,'X13'),X=D.X13;else,X=D.Xaug;end
        good=usable&all(isfinite(X),2)&all(isfinite(D.base),2);
        if any(good)
            switch entry.kind
                case 'ridge'
                    prediction(good,:)=D.base(good,:)+pnn_ridge_predict(model,X(good,:));
                case 'oldNN'
                    P=zeros(sum(good),3,numel(model.members));
                    for s=1:numel(model.members)
                        P(:,:,s)=double(predict(model.members{s},X(good,:))).*model.scale;
                    end
                    prediction(good,:)=D.base(good,:)+mean(P,3);
                case 'NN'
                    P=zeros(sum(good),3,numel(model.members));
                    for s=1:numel(model.members),P(:,:,s)=pnn_nn_predict(model.members{s},X(good,:));end
                    correction=model.alpha*mean(P,3);
                    if ~isempty(model.skip),correction=correction+pnn_ridge_predict(model.skip,X(good,:));end
                    prediction(good,:)=D.base(good,:)+correction;
                otherwise,error('pnn:Method','Unknown model kind.');
            end
        end
end
if ismember(entry.kind,{'physics6','physics8'})
    if isfield(D,'physical_success'),usable=usable&logical(D.physical_success(:));end
    prediction(~usable,:)=NaN;
end
finite=all(isfinite(prediction),2);accepted=accepted&usable&finite;
detail=struct('method',entry.name,'finite',finite,'usable',usable,'accepted',accepted, ...
    'rejected',~accepted,'failed',~finite,'clipped',false(N,1));
end

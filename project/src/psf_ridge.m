function out=psf_ridge(action,varargin)
%PSF_RIDGE Standardized ridge; centered unpenalized intercept, multioutput.
% Objective mean(sum((Y - prediction).^2,2)) + lambda*sum(B.^2,'all').
switch action
    case 'fit'
        X=varargin{1};Y=varargin{2};lambda=varargin{3};
        assert(size(X,1)==size(Y,1)&&size(X,1)>=2&&all(isfinite([X Y]),'all')&& ...
            isscalar(lambda)&&isfinite(lambda)&&lambda>0,'psf:Ridge','Invalid training data/penalty.');
        mu=mean(X,1);sigma=std(X,0,1);sigma(sigma<1e-10)=1;
        Z=(X-mu)./sigma;ym=mean(Y,1);
        B=(Z.'*Z+size(X,1)*lambda*eye(size(X,2)))\(Z.'*(Y-ym));
        out=struct('schema','psf_ridge_v1','mu',mu,'sigma',sigma,'intercept',ym,'beta',B,'lambda',lambda);
    case 'predict'
        model=varargin{1};X=varargin{2};assert(strcmp(model.schema,'psf_ridge_v1'),'psf:Ridge','Wrong model.');
        out=((X-model.mu)./model.sigma)*model.beta+model.intercept;
    otherwise,error('psf:Ridge','Unknown action.');
end
end

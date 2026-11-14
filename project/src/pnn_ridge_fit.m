function model=pnn_ridge_fit(X,Y,lambda,mode)
%PNN_RIDGE_FIT Independently standardized, centered physical-residual ridge.
% Objective mean(sum((Y-Z*B-b).^2,2))+lambda*sum(B.^2,'all').
% interaction: all original standardized columns plus 91 quadratic terms
% from the first thirteen columns. With 52 augmented inputs this is 143.
if nargin<4,mode='linear';end
assert(size(X,1)==size(Y,1)&&size(Y,2)==3&&size(X,1)>=4&& ...
    all(isfinite([X Y]),'all')&&lambda>0,'pnn:Ridge','Invalid ridge input.');
transform=struct('mode',char(mode),'input_count',size(X,2),'mu',[],'sigma',[],'pairs',[]);
F=X;
if strcmp(mode,'interaction')
    assert(size(X,2)>=13,'pnn:Ridge','Interaction input needs first thirteen features.');
    transform.mu=mean(X,1);transform.sigma=std(X,0,1);transform.sigma(transform.sigma<1e-10)=1;
    F=(X-transform.mu)./transform.sigma;pairs=zeros(91,2);n=0;
    for i=1:13,for j=i:13,n=n+1;pairs(n,:)=[i j];end,end
    transform.pairs=pairs;F=[F F(:,pairs(:,1)).*F(:,pairs(:,2))];
else
    assert(strcmp(mode,'linear'),'pnn:Ridge','Unknown feature transform.');
end
mu=mean(F,1);sigma=std(F,0,1);sigma(sigma<1e-10)=1;
Z=(F-mu)./sigma;intercept=mean(Y,1);
beta=(Z.'*Z+size(Z,1)*lambda*eye(size(Z,2)))\(Z.'*(Y-intercept));
model=struct('schema','pnn_ridge_v1','transform',transform,'mu',mu,'sigma',sigma, ...
    'intercept',intercept,'beta',beta,'lambda',lambda,'feature_count',size(F,2));
end

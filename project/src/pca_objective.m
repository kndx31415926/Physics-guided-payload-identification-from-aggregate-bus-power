function [f,g,H,parts]=pca_objective(x,U,Y,amplitude,lossScales,smoothEpsilon,lambda)
%PCA_OBJECTIVE Exact double-precision affine smooth physical loss, 42 variables.
% A(:) stores three outputs consecutively for each of 13 inputs and the bias.
% All arguments are train-only quantities. Bias is deliberately unpenalized.
A=reshape(double(x),3,size(U,2));q=double(amplitude(:)./lossScales(:));
E=(double(U)*A.').*q.'-double(Y)./double(lossScales(:).');
rm=hypot(E(:,1),smoothEpsilon);rc=sqrt(E(:,2).^2+E(:,3).^2+smoothEpsilon^2);
n=size(U,1);data=mean((rm+rc-2*smoothEpsilon)/2);
penalty=lambda/2*sum(A(:,1:end-1).^2,'all');f=data+penalty;
if nargout>=2
    C=.5*[E(:,1)./rm E(:,2)./rc E(:,3)./rc];
    G=(C.*q.').'*U/n;G(:,1:end-1)=G(:,1:end-1)+lambda*A(:,1:end-1);g=G(:);
end
if nargout>=3
    d11=.5*q(1)^2*smoothEpsilon^2./rm.^3;
    d22=.5*q(2)^2*(E(:,3).^2+smoothEpsilon^2)./rc.^3;
    d33=.5*q(3)^2*(E(:,2).^2+smoothEpsilon^2)./rc.^3;
    d23=-.5*q(2)*q(3)*E(:,2).*E(:,3)./rc.^3;
    p=size(U,2);H=zeros(3*p);i1=1:3:3*p;i2=2:3:3*p;i3=3:3:3*p;
    H(i1,i1)=U.'*(U.*d11)/n;H(i2,i2)=U.'*(U.*d22)/n;
    H(i3,i3)=U.'*(U.*d33)/n;H(i2,i3)=U.'*(U.*d23)/n;H(i3,i2)=H(i2,i3).';
    reg=[repmat(lambda,1,3*(p-1)),0,0,0];H=H+diag(reg);H=(H+H.')/2;
end
if nargout>=4,parts=struct('data_loss',data,'weight_L2_penalty',penalty);end
end

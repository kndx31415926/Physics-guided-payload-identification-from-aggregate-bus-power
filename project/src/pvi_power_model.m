function [power,Jbeta,Jtheta,H,tau]=pvi_power_model(g0,Y,theta,coeff)
%PVI_POWER_MODEL Independent static evaluator and analytic sensitivities.
% H contains derivatives with respect to [aux,h2,h3,h4]. Velocity-dependent
% coefficients and yaw holding loss are invisible under this static model.
theta=double(theta(:));coeff=double(coeff(:));
assert(numel(theta)==3&&numel(coeff)==13,'pvi:Shape','Invalid parameter dimensions.');
beta=[theta(1);theta(1)*theta(2);theta(1)*theta(3)];
tau=g0;
for j=1:3,tau=tau+Y(:,:,j)*beta(j);end
power=coeff(1)+sum(tau.^2.*coeff(2:5).',2);
Jbeta=zeros(size(g0,1),3);
for j=1:3,Jbeta(:,j)=2*sum(tau.*Y(:,:,j).*coeff(2:5).',2);end
T=[1 0 0;theta(2) theta(1) 0;theta(3) 0 theta(1)];
Jtheta=Jbeta*T;
H=[ones(size(g0,1),1),tau(:,2:4).^2];
end

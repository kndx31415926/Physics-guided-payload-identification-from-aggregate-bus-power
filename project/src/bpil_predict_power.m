function [power_W,detail] = bpil_predict_power(cfg,q,theta,eta)
%BPIL_PREDICT_POWER Static, aggregate-port prediction, not a torque sensor.
% theta=[mass_kg,COM_x_m,COM_z_m]; COM_y is outside the identified model.
% The second output includes an analytic sensitivity to the three parameters.
validateattributes(q,{'numeric'},{'2d','ncols',4,'finite','real'});
validateattributes(theta,{'numeric'},{'vector','numel',3,'finite','real'});
theta=double(theta(:).');
assert(theta(1)>=0,'bpil:Mass','Mass must be nonnegative.');
assert(isstruct(eta)&&isfield(eta,'coefficients'),'bpil:PowerModel','Missing coefficients.');
c=double(eta.coefficients(:).');
assert(numel(c)==13&&all(isfinite(c))&&all(c>=0),'bpil:PowerModel', ...
    'Expected 13 finite nonnegative port-power coefficients.');
[g0,Y]=bpil_static_design(cfg,double(q));
assert(isequal(size(g0),size(q))&&size(Y,1)==size(q,1)&& ...
    size(Y,2)==4&&size(Y,3)==3,'bpil:StaticDesign','Invalid static design dimensions.');
h=[theta(1),theta(1)*theta(2),theta(1)*theta(3)];
tau=g0;
for k=1:3,tau=tau+Y(:,:,k)*h(k);end
holding=c(2:5);
power_W=c(1)+sum(tau.^2.*holding,2);
if nargout>1
    dh=[1 0 0;theta(2) theta(1) 0;theta(3) 0 theta(1)];
    J=zeros(size(q,1),3);
    for k=1:3
        dtau=zeros(size(tau));
        for j=1:3,dtau=dtau+Y(:,:,j)*dh(j,k);end
        J(:,k)=2*sum(tau.*holding.*dtau,2);
    end
    detail=struct('jacobian',J,'torque_model_Nm',tau,'first_moments',h, ...
        'scope','Static model prediction; modeled torque is never a measured estimator feature.');
end
end

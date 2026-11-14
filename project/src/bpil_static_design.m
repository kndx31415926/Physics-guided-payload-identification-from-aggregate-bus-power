function [g0,Y] = bpil_static_design(cfg,q)
%BPIL_STATIC_DESIGN tau = g0 + Y*[m; m*cx; m*cz], cy invisible to gravity.
% Native rigidBodyTree gravityTorque defines the empty-arm term. Payload
% columns follow the same +Z yaw and three +Y pitch frame convention.
assert(size(q,2)==4&&all(isfinite(q(:))),'bpil:StaticShape','q must be N-by-4.');
payload=struct('mass',0,'com',[.128 0 0]);
[model,C]=bpil_make_plant(cfg,payload);p=C.geometry.robot_params;
assert(norm(p.gravity-[0 0 -9.81])<1e-9,'bpil:Gravity','Analytic design assumes vertical -9.81 m/s^2 gravity.');
N=size(q,1);g0=zeros(N,4);Y=zeros(N,4,3);
for n=1:N
    g0(n,:)=gravityTorque(model.robot,q(n,:));
    a=cumsum(q(n,2:4));phi=a(3);
    for k=1:3
        Y(n,k+1,1)=-9.81*sum(p.L(k:3).*cos(a(k:3)));
        Y(n,k+1,2)=-9.81*cos(phi);
        Y(n,k+1,3)=-9.81*sin(phi);
    end
end
end

function [model,C] = bpil_make_plant(cfg,payload)
%BPIL_MAKE_PLANT Payload dynamics with geometry independent of its COM.
% The enclosing rigid box is fixed at [length/2,0,0] in the tool frame.
% A smaller dense box centred at the requested COM supplies physically valid
% COM inertia. This is a nominal nonuniform payload, not a material model.
C=cfg.legacy;
if ~isfield(payload,'dimensions_m')
    if isfield(cfg,'payload')&&isfield(cfg.payload,'dimensions_m'),payload.dimensions_m=cfg.payload.dimensions_m;
    else,payload.dimensions_m=[.256 .06 .08];end
end
d=double(payload.dimensions_m(:).'); c=double(payload.com(:).');
assert(numel(c)==3&&numel(d)==3&&all(d>0)&&payload.mass>=0,'bpil:Payload','Invalid payload.');
center=[d(1)/2 0 0]; margin=d/2-abs(c-center);
assert(all(margin>0),'bpil:COMOutsideBox','COM must lie strictly inside the fixed enclosing box.');
half=min(d/4,.8*margin); m=double(payload.mass);
if isfield(payload,'inertia')
    inertia=payload.inertia;
else
    inertia=m/3*[half(2)^2+half(3)^2,half(1)^2+half(3)^2,half(1)^2+half(2)^2,0,0,0];
end
P=struct('mass',m,'com',c,'inertia',inertia,'about','com', ...
    'dimensions_m',d,'shape','box','attachment','rigid_wrist', ...
    'inertia_model','provided_com_tensor');
model=bdclp_make_model(C,struct('payload',P));
G=P;G.com=center;
geometry_model=bdclp_make_model(C,struct('payload',G));
model.audit=geometry_model.audit;
model.metadata.bpil_geometry_center_m=center;
model.metadata.bpil_com_independent_of_geometry=true;
model.metadata.bpil_inertia_scope='dense uniform sub-box inside fixed enclosing rigid box; supplied COM tensor if present';
model.metadata.bpil_payload=P;
if isfield(cfg,'drift'),D=cfg.drift;else,D=struct();end
holding=getdef(D,'holding_scale',ones(1,4));
aux=getdef(D,'aux_offset_W',0); friction=getdef(D,'friction_scale',1); gain=getdef(D,'gain_scale',1);
assert(numel(holding)==4&&all(isfinite(holding))&&all(holding>0)&&isscalar(aux)&&isfinite(aux), ...
    'bpil:Drift','Invalid electrical drift.');
assert(any(numel(friction)==[1 4])&&any(numel(gain)==[1 4])&& ...
    all(isfinite(friction(:)))&&all(isfinite(gain(:)))&&all(friction(:)>0)&&all(gain(:)>0), ...
    'bpil:Drift','Friction and gain scales must be positive finite scalars or four-vectors.');
friction=reshape(friction,1,[]);gain=reshape(gain,1,[]);
C.power.coefficients(2:5)=C.power.coefficients(2:5).*reshape(holding,1,4);
C.power.coefficients(1)=C.power.coefficients(1)+aux;
assert(C.power.coefficients(1)>=0,'bpil:Drift','Auxiliary draw must remain nonnegative.');
C.servo.viscous_Nm_s_per_rad=C.servo.viscous_Nm_s_per_rad.*friction;
C.servo.coulomb_Nm=C.servo.coulomb_Nm.*friction;
C.servo.kp_Nm_per_rad=C.servo.kp_Nm_per_rad.*gain;
C.servo.ki_Nm_per_rad_s=C.servo.ki_Nm_per_rad_s.*gain;
C.servo.kd_Nm_s_per_rad=C.servo.kd_Nm_s_per_rad.*gain;
end
function x=getdef(S,k,v)
if isfield(S,k),x=S.(k);else,x=v;end
end

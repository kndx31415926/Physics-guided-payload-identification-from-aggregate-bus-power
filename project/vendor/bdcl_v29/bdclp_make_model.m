function model=bdclp_make_model(C,task)
%BDCLP_MAKE_MODEL Nominal reduced 4R RoArm model; no controller or BUS layer.
% Source inertias are about COM. Robotics rigidBody.Inertia is about the BODY
% ORIGIN (unlike Simscape Solid), so the parallel-axis shift is necessary.
% MathWorks Support Team, 2023-11-01, answer 2042131; URL is in G below.
assert(isstruct(C)&&isfield(C,'geometry'),'bdclp:GeometryConfig','C.geometry is required.');
G=C.geometry; p=G.robot_params;
assert(isstruct(task)&&isfield(task,'payload'),'bdclp:Payload','task.payload is required.');
pay=validate_payload_local(task.payload);
validate_geometry_local(G);
assert(exist('rigidBodyTree','class')==8 || exist('rigidBodyTree','file')==2, ...
    'bdclp:RoboticsToolboxRequired','The full RoArm model requires Robotics System Toolbox; synthetic fixtures are separate.');
robot=rigidBodyTree('DataFormat','row','MaxNumBodies',6);
robot.Gravity=double(p.gravity(:).');
robot=add_body_local(robot,'base_fixed',robot.BaseName,'fixed',[0 0 1],eye(4), ...
    [],p.fixed_base_mass,p.fixed_base_com_xyz,p.fixed_base_I6_com);
robot=add_body_local(robot,'link_baseYaw','base_fixed','revolute',[0 0 1], ...
    translation_local(p.base_joint_xyz),p.jposlim(1,:),p.base_mass,p.base_com_xyz,p.base_I6_com);
names={'link_shoulder','link_elbow','link_wrist'};
parents={'link_baseYaw','link_shoulder','link_elbow'};
for j=1:3
    xyz=[0 0 0]; if j>1, xyz(1)=p.L(j-1); end
    robot=add_body_local(robot,names{j},parents{j},'revolute',[0 1 0], ...
        translation_local(xyz),p.jposlim(j+1,:),p.mass(j),p.com_xyz(j,:),p.I6_com(j,:));
end
robot=add_body_local(robot,'tool','link_wrist','fixed',[0 0 1], ...
    translation_local([p.L(3) 0 0]),[],pay.mass,pay.com,pay.inertia);
model=struct(); model.n=4;
model.qmin=double(p.jposlim(:,1).'); model.qmax=double(p.jposlim(:,2).');
model.mass=@(q)mass_local(robot,q);
model.bias=@(q,dq)bias_local(robot,q,dq);
model.fk=@(q)fk_local(q,p);
model.jacobian=@(q)jacobian_local(q,p);
model.transform=@(q)tool_transform_local(q,p);
model.audit=@(q,dq)audit_local(q,dq,p,pay,G);
model.robot=robot;
model.signature_data=struct('schema','bdclp_nominal_reduced_roarm_model_v1', ...
    'geometry',G,'payload',pay,'inertia_about','body_origin', ...
    'inertia_reference',G.inertia_reference,'fixture',false);
model.metadata=struct('scope','nominal reduced stock 4R URDF with runtime payload', ...
    'hardware_calibrated',false,'stock_mass_kg',p.nominal_model_mass_kg, ...
    'payload_mass_kg',pay.mass,'total_mass_kg',p.nominal_model_mass_kg+pay.mass, ...
    'payload_dimensions_m',pay.dimensions_m,'payload_attachment',pay.attachment, ...
    'payload_geometry_source','task.payload','joint_domain_scope',G.joint_domain_scope, ...
    'mass_status',p.mass_scope_note,'kinematic_length_m',sum(p.L), ...
    'payload_extends_robot_kinematics',false,'inertia_convention',G.inertia_convention, ...
    'audit_scope','joint position/speed, work plane, nonadjacent capsule/payload clearance; detection only');
end

function robot=add_body_local(robot,name,parent,type,axis,T,limits,m,com,I6)
b=rigidBody(name); j=rigidBodyJoint(['joint_' name],type);
if strcmp(type,'revolute'), j.JointAxis=axis; j.PositionLimits=limits; end
setFixedTransform(j,T); b.Joint=j;
com=double(com(:).'); I=inertia_matrix_local(I6);
assert(isscalar(m)&&isfinite(m)&&m>=0&&numel(com)==3&&all(isfinite(com)), ...
    'bdclp:InertialData','Mass and COM must be finite and mass nonnegative.');
validate_inertia_local(I,m);
Io=I+double(m)*(dot(com,com)*eye(3)-com(:)*com(:).');
b.Mass=double(m); b.CenterOfMass=com;
b.Inertia=[Io(1,1) Io(2,2) Io(3,3) Io(2,3) Io(1,3) Io(1,2)];
addBody(robot,b,parent);
end

function pay=validate_payload_local(P)
assert(isstruct(P)&&isscalar(P)&&all(isfield(P, ...
    {'mass','com','inertia','dimensions_m','shape','attachment','inertia_model'})), ...
    'bdclp:Payload','Payload requires mass, COM, COM inertia, dimensions and rigid attachment metadata.');
assert(strcmp(P.shape,'box')&&strcmp(P.attachment,'rigid_wrist'), ...
    'bdclp:Payload','This model requires a box-shaped rigid wrist payload, not a grasp process.');
assert(isnumeric(P.dimensions_m)&&isreal(P.dimensions_m)&& ...
    isequal(size(P.dimensions_m),[1 3])&&all(isfinite(P.dimensions_m))&&all(P.dimensions_m>0), ...
    'bdclp:Payload','Payload dimensions must be a positive finite 1x3 row.');
assert(isnumeric(P.mass)&&isreal(P.mass)&&isscalar(P.mass)&&isfinite(P.mass)&&P.mass>=0, ...
    'bdclp:Payload','Payload mass must be nonnegative.');
assert(isnumeric(P.com)&&isreal(P.com)&&isnumeric(P.inertia)&&isreal(P.inertia), ...
    'bdclp:Payload','Payload COM and inertia must be real numeric arrays.');
pay=struct('mass',double(P.mass),'com',double(P.com(:).'), ...
    'inertia',double(P.inertia(:).'),'about','com', ...
    'dimensions_m',double(P.dimensions_m),'shape',P.shape, ...
    'attachment',P.attachment,'inertia_model',P.inertia_model);
assert(numel(pay.com)==3&&all(isfinite(pay.com))&&numel(pay.inertia)==6, ...
    'bdclp:Payload','Expected three COM coordinates and six COM inertia components.');
assert(~isfield(P,'about')||strcmp(char(P.about),'com'), ...
    'bdclp:PayloadInertiaConvention','Payload inertia must explicitly use the COM convention.');
validate_inertia_local(inertia_matrix_local(pay.inertia),pay.mass);
if strcmp(pay.inertia_model,'uniform_box_nominal')
    d=pay.dimensions_m;
    expected=pay.mass/12*[d(2)^2+d(3)^2,d(1)^2+d(3)^2,d(1)^2+d(2)^2,0,0,0];
    assert(norm(pay.inertia-expected,inf)<=1e-12+1e-10*norm(expected,inf), ...
        'bdclp:PayloadInertiaMismatch','Uniform-box dimensions and inertia disagree.');
else
    assert(strcmp(pay.inertia_model,'provided_com_tensor'), ...
        'bdclp:Payload','Unknown payload inertia model.');
end
end

function validate_geometry_local(G)
assert(isequal(size(G.robot_params.jposlim),[4 2])&& ...
    isreal(G.robot_params.jposlim)&&all(isfinite(G.robot_params.jposlim(:)))&& ...
    all(G.robot_params.jposlim(:,1)<G.robot_params.jposlim(:,2)), ...
    'bdclp:GeometryConfig','Expected four ordered joint limits.');
assert(numel(G.robot_params.L)==3&&isreal(G.robot_params.L)&& ...
    all(isfinite(G.robot_params.L))&&all(G.robot_params.L>0), ...
    'bdclp:GeometryConfig','Expected three finite positive link lengths.');
assert(isscalar(G.audit_tolerance)&&isreal(G.audit_tolerance)&& ...
    isfinite(G.audit_tolerance)&&G.audit_tolerance>=0, ...
    'bdclp:GeometryConfig','Audit tolerance must be finite and nonnegative.');
assert(numel(G.velocity_max_rad_s)==4&&all(isfinite(G.velocity_max_rad_s))&& ...
    all(G.velocity_max_rad_s>0),'bdclp:GeometryConfig','Invalid velocity limits.');
assert(isequal(size(G.capsule_start_m),[5 3])&&isequal(size(G.capsule_end_m),[5 3])&& ...
    numel(G.capsule_radius_m)==5&&all(G.capsule_radius_m>=0), ...
    'bdclp:GeometryConfig','Expected the five declared stock-body capsules.');
assert(all(isfinite([G.capsule_start_m(:);G.capsule_end_m(:);G.capsule_radius_m(:); ...
    G.plane_z_m;G.plane_clearance_m;G.self_clearance_m]))&& ...
    G.plane_clearance_m>=0&&G.self_clearance_m>=0, ...
    'bdclp:GeometryConfig','Geometry and clearances must be finite.');
assert(size(G.collision_pairs,2)==2&&all(G.collision_pairs(:)>=1)&& ...
    all(G.collision_pairs(:)<=5)&&all(G.collision_pairs(:)==fix(G.collision_pairs(:)))&& ...
    all(G.payload_capsule_indices>=1)&&all(G.payload_capsule_indices<=5)&& ...
    all(G.payload_capsule_indices==fix(G.payload_capsule_indices)), ...
    'bdclp:GeometryConfig','Collision indices are invalid.');
end

function I=inertia_matrix_local(v)
v=double(v(:).');
assert(numel(v)==6&&all(isfinite(v)),'bdclp:InertialData','Expected six finite inertia components.');
I=[v(1) v(6) v(5);v(6) v(2) v(4);v(5) v(4) v(3)];
end

function validate_inertia_local(I,m)
d=sort(eig((I+I.')/2)); tol=1e-12+1e-10*max(abs(d));
assert(all(isfinite(d))&&min(d)>=-tol&&d(3)<=d(1)+d(2)+tol, ...
    'bdclp:InertialData','COM inertia is not physically valid; no eigenvalue repair is performed.');
assert(m>0||max(abs(I(:)))<=tol,'bdclp:InertialData','A massless body must have zero inertia.');
end

function M=mass_local(robot,q)
q=state_row_local(q); M=massMatrix(robot,q);
end

function h=bias_local(robot,q,dq)
q=state_row_local(q); dq=state_row_local(dq);
h=double(velocityProduct(robot,q,dq))+double(gravityTorque(robot,q)); h=h(:).';
end

function xyz=fk_local(q,p)
T=tool_transform_local(q,p); xyz=T(1:3,4);
end

function J=jacobian_local(q,p)
q=state_row_local(q); a=cumsum(q(2:4));
r=sum(p.L.*cos(a)); psi=q(1); J=zeros(3,4);
J(:,1)=[-sin(psi)*r;cos(psi)*r;0];
for k=1:3
    dr=-sum(p.L(k:3).*sin(a(k:3))); dz=-sum(p.L(k:3).*cos(a(k:3)));
    J(:,k+1)=[cos(psi)*dr;sin(psi)*dr;dz];
end
end

function T=tool_transform_local(q,p)
[~,T]=frames_local(state_row_local(q),p);
end

function [F,Ttool]=frames_local(q,p)
F=zeros(4,4,5); F(:,:,1)=eye(4);
F(:,:,2)=translation_local(p.base_joint_xyz)*rotation_z_local(q(1));
F(:,:,3)=F(:,:,2)*rotation_y_local(q(2));
F(:,:,4)=F(:,:,3)*translation_local([p.L(1) 0 0])*rotation_y_local(q(3));
F(:,:,5)=F(:,:,4)*translation_local([p.L(2) 0 0])*rotation_y_local(q(4));
Ttool=F(:,:,5)*translation_local([p.L(3) 0 0]);
end

function A=audit_local(q,dq,p,pay,G)
assert(isnumeric(q)&&numel(q)==4&&isnumeric(dq)&&numel(dq)==4, ...
    'bdclp:StateShape','Audit expects four joint positions and velocities.');
q=double(q(:).'); dq=double(dq(:).'); reasons={};
A=struct('pass',false,'reasons',{{}},'min_clearance_m',NaN, ...
    'min_plane_clearance_m',NaN,'min_self_clearance_m',NaN, ...
    'joint_position_pass',false,'joint_speed_pass',false,'geometry_pass',false);
if ~isreal(q)||~isreal(dq)||any(~isfinite([q dq]))
    A.reasons={'nonfinite_state'}; return;
end
tol=G.audit_tolerance;
A.joint_position_pass=all(q>=p.jposlim(:,1).'-tol & q<=p.jposlim(:,2).'+tol);
A.joint_speed_pass=all(abs(dq)<=G.velocity_max_rad_s+tol);
if ~A.joint_position_pass, reasons{end+1}='joint_position'; end
if ~A.joint_speed_pass, reasons{end+1}='joint_speed'; end
[F,T]=frames_local(q,p); a=zeros(5,3); b=a;
for j=1:5
    a(j,:)=(F(1:3,1:3,j)*G.capsule_start_m(j,:).'+F(1:3,4,j)).';
    b(j,:)=(F(1:3,1:3,j)*G.capsule_end_m(j,:).'+F(1:3,4,j)).';
end
plane=min(min(a(:,3),b(:,3))-G.capsule_radius_m(:))-G.plane_z_m-G.plane_clearance_m;
self=inf;
for k=1:size(G.collision_pairs,1)
    i=G.collision_pairs(k,1); j=G.collision_pairs(k,2);
    self=min(self,segment_distance_local(a(i,:),b(i,:),a(j,:),b(j,:))- ...
        G.capsule_radius_m(i)-G.capsule_radius_m(j)-G.self_clearance_m);
end
if pay.mass>0
    [sx,sy,sz]=ndgrid([-1 1],[-1 1],[-1 1]);
    corners=[sx(:) sy(:) sz(:)].*(pay.dimensions_m/2)+pay.com;
    world=corners*T(1:3,1:3).'+T(1:3,4).';
    plane=min(plane,min(world(:,3))-G.plane_z_m-G.plane_clearance_m);
    center=(T(1:3,1:3)*pay.com(:)+T(1:3,4)).';
    radius=norm(pay.dimensions_m)/2;
    for j=G.payload_capsule_indices(:).'
        self=min(self,segment_distance_local(center,center,a(j,:),b(j,:))- ...
            radius-G.capsule_radius_m(j)-G.self_clearance_m);
    end
end
if plane < -tol, reasons{end+1}='work_plane'; end
if self < -tol, reasons{end+1}='self_collision'; end
A.min_plane_clearance_m=plane; A.min_self_clearance_m=self;
A.min_clearance_m=min(plane,self); A.geometry_pass=plane>=-tol&&self>=-tol;
A.reasons=reasons; A.pass=isempty(reasons);
end

function d=segment_distance_local(p1,q1,p2,q2)
% Closest points on two finite segments, including point/parallel cases.
u=q1-p1; v=q2-p2; w=p1-p2; a=dot(u,u); e=dot(v,v); f=dot(v,w);
eps2=1e-24;
if a<=eps2&&e<=eps2, d=norm(w); return; end
if a<=eps2
    s=0; t=min(1,max(0,f/e));
else
    c=dot(u,w);
    if e<=eps2
        t=0; s=min(1,max(0,-c/a));
    else
        b=dot(u,v); den=a*e-b*b;
        if den>eps2, s=min(1,max(0,(b*f-c*e)/den)); else, s=0; end
        t=(b*s+f)/e;
        if t<0, t=0; s=min(1,max(0,-c/a));
        elseif t>1, t=1; s=min(1,max(0,(b-c)/a)); end
    end
end
d=norm(w+s*u-t*v);
end

function q=state_row_local(q)
assert(isnumeric(q)&&isreal(q)&&numel(q)==4&&all(isfinite(q(:))), ...
    'bdclp:StateShape','Expected a finite real four-joint vector.'); q=double(q(:).');
end

function T=translation_local(x)
T=eye(4); T(1:3,4)=double(x(:));
end
function T=rotation_y_local(x)
T=[cos(x) 0 sin(x) 0;0 1 0 0;-sin(x) 0 cos(x) 0;0 0 0 1];
end
function T=rotation_z_local(x)
T=[cos(x) -sin(x) 0 0;sin(x) cos(x) 0 0;0 0 1 0;0 0 0 1];
end
